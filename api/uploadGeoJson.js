// api/uploadGeoJson.js
// GeoJSON を GitHub へ保存し Raw URL を返す Vercel Serverless Function
// GitHub Raw は CDN キャッシュ（最大5分）があるため、
// 即時読み込み用に cacheBustedUrl（?t=タイムスタンプ付き）も返す。

const GITHUB_OWNER = 'tomi-1090';
const GITHUB_REPO  = 'side-gutters-map';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin' : '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

const GH_HEADERS = () => ({
  Authorization : `token ${process.env.GITHUB_TOKEN}`,
  'Content-Type': 'application/json',
  'User-Agent'  : 'side-gutters-map-vercel',
});

export default async function handler(req, res) {
  if (req.method === 'OPTIONS') return res.status(204).set(CORS_HEADERS).end();

  Object.entries(CORS_HEADERS).forEach(([k, v]) => res.setHeader(k, v));

  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const { geojson, shareId: rawShareId } = req.body ?? {};
  if (!geojson) return res.status(400).json({ error: 'No geojson provided' });
  if (!process.env.GITHUB_TOKEN) return res.status(500).json({ error: 'GITHUB_TOKEN is not configured' });

  try {
    const shareId = /^[\w-]+$/.test((rawShareId ?? '').trim())
      ? rawShareId.trim()
      : Date.now().toString();

    const filePath = `shared/${encodeURIComponent(shareId)}.geojson`;
    const apiUrl   = `https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/contents/${filePath}`;
    const sha      = await fetchExistingSha(apiUrl);
    const content  = Buffer.from(JSON.stringify(geojson)).toString('base64');

    const githubRes = await fetch(apiUrl, {
      method : 'PUT',
      headers: GH_HEADERS(),
      body   : JSON.stringify({
        message: `update ${shareId} at ${new Date().toISOString()}`,
        content,
        ...(sha ? { sha } : {}),
      }),
    });

    if (!githubRes.ok) {
      const err = await githubRes.json().catch(() => ({}));
      console.error('[uploadGeoJson] GitHub API error:', githubRes.status, err);
      return res.status(502).json({ error: 'GitHub API error', status: githubRes.status, detail: err });
    }

    const rawUrl = `https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/main/${filePath}`;
    return res.status(200).json({
      success: true,
      rawUrl,
      cacheBustedUrl: `${rawUrl}?t=${Date.now()}`,
      shareId,
    });
  } catch (err) {
    console.error('[uploadGeoJson]', err);
    return res.status(500).json({ error: err.message ?? String(err) });
  }
}

async function fetchExistingSha(apiUrl) {
  try {
    const res = await fetch(apiUrl, { headers: GH_HEADERS() });
    if (!res.ok) return undefined;
    return (await res.json()).sha;
  } catch {
    return undefined;
  }
}
