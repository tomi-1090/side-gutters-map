// ================================================================
// api/uploadGeoJson.js
// GeoJSON を GitHub へ保存し Raw URL を返す Vercel Serverless Function
// ================================================================

const GITHUB_OWNER = 'tomi-1090';
const GITHUB_REPO  = 'side-gutters-map';

/** すべてのレスポンスに付ける CORS ヘッダー（スマホ Safari/Chrome 対策） */
const CORS_HEADERS = {
  'Access-Control-Allow-Origin' : '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

export default async function handler(req, res) {
  // ── プリフライトリクエスト (OPTIONS) ──────────────────────────
  if (req.method === 'OPTIONS') {
    return res.status(204).set(CORS_HEADERS).end();
  }

  // ── CORS ヘッダーを全レスポンスに付与 ─────────────────────────
  Object.entries(CORS_HEADERS).forEach(([k, v]) => res.setHeader(k, v));

  // ── メソッドチェック ──────────────────────────────────────────
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  // ── バリデーション ────────────────────────────────────────────
  const { geojson, shareId: rawShareId } = req.body ?? {};
  if (!geojson) {
    return res.status(400).json({ error: 'No geojson provided' });
  }

  try {
    // ── ファイルパス決定 ──────────────────────────────────────────
    // shareId は英数字・ハイフン・アンダースコアのみ許可（パストラバーサル対策）
    const shareId = /^[\w-]+$/.test(rawShareId ?? '')
      ? rawShareId
      : Date.now().toString();

    const filePath = `shared/${shareId}.geojson`;
    const apiUrl   = `https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/contents/${filePath}`;

    // ── 既存ファイルの SHA 取得（更新時に必要） ───────────────────
    const sha = await fetchExistingSha(apiUrl);

    // ── Base64 エンコード ─────────────────────────────────────────
    const content = Buffer.from(JSON.stringify(geojson, null, 2)).toString('base64');

    // ── GitHub Contents API へ PUT ────────────────────────────────
    const putBody = {
      message: `update ${shareId}`,
      content,
      ...(sha ? { sha } : {}),       // 新規作成時は sha 不要
    };

    const githubRes = await fetch(apiUrl, {
      method : 'PUT',
      headers: {
        Authorization : `token ${process.env.GITHUB_TOKEN}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(putBody),
    });

    if (!githubRes.ok) {
      const err = await githubRes.json().catch(() => ({}));
      console.error('[uploadGeoJson] GitHub API error:', err);
      return res.status(502).json({ error: 'GitHub API error', detail: err });
    }

    // ── Raw URL を返す（クエリパラメータなし ＝ スマホでも安全） ──
    const rawUrl =`https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/main/${filePath}`;

    return res.status(200).json({ success: true, rawUrl, shareId });

  } catch (err) {
    console.error('[uploadGeoJson] Unexpected error:', err);
    return res.status(500).json({ error: err.message ?? String(err) });
  }
}

// ================================================================
// ヘルパー: 既存ファイルの SHA を取得（存在しない場合は undefined）
// ================================================================
async function fetchExistingSha(apiUrl) {
  try {
    const res = await fetch(apiUrl, {
      headers: { Authorization: `token ${process.env.GITHUB_TOKEN}` },
    });
    if (!res.ok) return undefined;
    const data = await res.json();
    return data.sha;
  } catch {
    return undefined;
  }
}
