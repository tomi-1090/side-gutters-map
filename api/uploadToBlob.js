// api/uploadToBlob.js
// @vercel/blob を使わず GitHub API 経由で保存する実装。
// uploadGeoJson.js と同じ仕組みのため、追加パッケージ不要。

const GITHUB_OWNER = 'tomi-1090';
const GITHUB_REPO  = 'side-gutters-map';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin' : '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

function setCors(res) {
  Object.entries(CORS_HEADERS).forEach(([k, v]) => res.setHeader(k, v));
}

function ghHeaders() {
  return {
    Authorization : `token ${process.env.GITHUB_TOKEN}`,
    'Content-Type': 'application/json',
    'User-Agent'  : 'side-gutters-map-vercel',
  };
}

async function fetchExistingSha(apiUrl) {
  try {
    const res = await fetch(apiUrl, { headers: ghHeaders() });
    if (!res.ok) return undefined;
    return (await res.json()).sha;
  } catch {
    return undefined;
  }
}

export default async function handler(req, res) {
  setCors(res);

  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'POST')   return res.status(405).json({ error: 'Method not allowed' });

  const { geojson, shareId: rawShareId } = req.body || {};
  if (!geojson) return res.status(400).json({ error: 'No geojson data' });

  if (!process.env.GITHUB_TOKEN) {
    return res.status(500).json({ error: 'GITHUB_TOKEN is not configured' });
  }

  try {
    // shareId の決定（パストラバーサル対策）
    const shareId = typeof rawShareId === 'string' && /^[\w-]+$/.test(rawShareId.trim()) && rawShareId.trim().length > 8
      ? rawShareId.trim()
      : Date.now().toString();

    const filePath = `shared/${encodeURIComponent(shareId)}.geojson`;
    const apiUrl   = `https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/contents/${filePath}`;

    // 既存ファイルの SHA 取得（上書き更新に必要）
    const sha     = await fetchExistingSha(apiUrl);
    const content = Buffer.from(JSON.stringify(geojson)).toString('base64');

    const githubRes = await fetch(apiUrl, {
      method : 'PUT',
      headers: ghHeaders(),
      body   : JSON.stringify({
        message: `update ${shareId} at ${new Date().toISOString()}`,
        content,
        ...(sha ? { sha } : {}),
      }),
    });

    if (!githubRes.ok) {
      const detail = await githubRes.json().catch(() => ({}));
      console.error('[uploadToBlob] GitHub API error:', githubRes.status, detail);
      return res.status(502).json({ error: 'GitHub API error', status: githubRes.status, detail });
    }

    // Raw URL を組み立てて返す（Blob URL の代替）
    const rawUrl   = `https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/main/${filePath}`;
    // クライアントが期待する shareUrl 形式で返す
    const shareUrl = `${req.headers.origin}/?geojson=${encodeURIComponent(rawUrl)}`;

    return res.status(200).json({
      success  : true,
      rawUrl,
      shareUrl,
      shareId,
    });

  } catch (error) {
    console.error('[uploadToBlob]', error?.message ?? error);
    return res.status(500).json({ error: error?.message ?? String(error) });
  }
}