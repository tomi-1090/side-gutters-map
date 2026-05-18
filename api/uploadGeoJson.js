// ================================================================
// api/uploadGeoJson.js
// GeoJSON を GitHub へ保存し Raw URL を返す Vercel Serverless Function
//
// 【キャッシュ問題への対処】
//   GitHub Raw コンテンツは CDN でキャッシュされる（最大5分）。
//   クライアント側では Cache-Control / Pragma ヘッダーで回避するが、
//   それでも CDN キャッシュが残る場合は ?t=<timestamp> パラメータを
//   使うことで別リクエストとして扱わせる。
//   このAPIはレスポンスに rawUrl（クリーン）と cacheBustedUrl（タイムスタンプ付き）
//   の両方を返す。クライアントは初回読み込みに cacheBustedUrl を使い、
//   共有URLには rawUrl を使うことで QR/短縮URL の安定性を維持できる。
// ================================================================

const GITHUB_OWNER = 'tomi-1090';
const GITHUB_REPO  = 'side-gutters-map';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin' : '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

export default async function handler(req, res) {
  // ── プリフライト ────────────────────────────────────────────────
  if (req.method === 'OPTIONS') {
    return res.status(204).set(CORS_HEADERS).end();
  }

  Object.entries(CORS_HEADERS).forEach(([k, v]) => res.setHeader(k, v));

  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  // ── バリデーション ────────────────────────────────────────────
  const { geojson, shareId: rawShareId } = req.body ?? {};
  if (!geojson) {
    return res.status(400).json({ error: 'No geojson provided' });
  }
  if (!process.env.GITHUB_TOKEN) {
    return res.status(500).json({ error: 'GITHUB_TOKEN is not configured' });
  }

  try {
    // ── shareId の決定（パストラバーサル対策）────────────────────
    const shareId = /^[\w-]+$/.test((rawShareId ?? '').trim())
      ? rawShareId.trim()
      : Date.now().toString();

    const filePath = `shared/${encodeURIComponent(shareId)}.geojson`;
    const apiUrl   = `https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/contents/${filePath}`;

    // ── 既存ファイルの SHA 取得 ───────────────────────────────────
    const sha = await fetchExistingSha(apiUrl);

    // ── コンテンツをコンパクトJSONでエンコード（軽量化）─────────
    const content = Buffer.from(JSON.stringify(geojson)).toString('base64');

    const putBody = {
      message: `update ${shareId} at ${new Date().toISOString()}`,
      content,
      ...(sha ? { sha } : {}),
    };

    const githubRes = await fetch(apiUrl, {
      method : 'PUT',
      headers: {
        Authorization : `token ${process.env.GITHUB_TOKEN}`,
        'Content-Type': 'application/json',
        'User-Agent'  : 'side-gutters-map-vercel',
      },
      body: JSON.stringify(putBody),
    });

    if (!githubRes.ok) {
      const err = await githubRes.json().catch(() => ({}));
      console.error('[uploadGeoJson] GitHub API error:', githubRes.status, err);
      return res.status(502).json({
        error : 'GitHub API error',
        status: githubRes.status,
        detail: err,
      });
    }

    // ── Raw URL ────────────────────────────────────────────────────
    const rawUrl = `https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/main/${filePath}`;

    // キャッシュバスター付きURL（アップロード直後の再読み込み用）
    // GitHub Raw CDN のキャッシュは最大5分なので timestamp で回避
    const cacheBustedUrl = `${rawUrl}?t=${Date.now()}`;

    return res.status(200).json({
      success       : true,
      rawUrl,           // 共有URL生成用（クリーン・安定）
      cacheBustedUrl,   // アップロード直後の即時読み込み用
      shareId,
    });

  } catch (err) {
    console.error('[uploadGeoJson] Unexpected error:', err);
    return res.status(500).json({ error: err.message ?? String(err) });
  }
}

// ================================================================
// ヘルパー: 既存ファイルの SHA 取得
// ================================================================
async function fetchExistingSha(apiUrl) {
  try {
    const res = await fetch(apiUrl, {
      headers: {
        Authorization: `token ${process.env.GITHUB_TOKEN}`,
        'User-Agent'  : 'side-gutters-map-vercel',
      },
    });
    if (!res.ok) return undefined;
    const data = await res.json();
    return data.sha;
  } catch {
    return undefined;
  }
}
