// api/fetchGeoJson.js
// GitHub Raw から GeoJSON を取得して返す Vercel Serverless Function
// ブラウザからの直接 fetch は CORS でブロックされるため、このプロキシ経由で取得する。

const GITHUB_OWNER = 'tomi-1090';
const GITHUB_REPO  = 'side-gutters-map';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin' : '*',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

export default async function handler(req, res) {
  if (req.method === 'OPTIONS') return res.status(204).set(CORS_HEADERS).end();

  Object.entries(CORS_HEADERS).forEach(([k, v]) => res.setHeader(k, v));

  if (req.method !== 'GET') return res.status(405).json({ error: 'Method not allowed' });

  const { shareId } = req.query;
  if (!shareId || !/^[\w-]+$/.test(shareId)) {
    return res.status(400).json({ error: 'Invalid or missing shareId' });
  }

  const rawUrl = `https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/main/shared/${encodeURIComponent(shareId)}.geojson?t=${Date.now()}`;

  try {
    const githubRes = await fetch(rawUrl, {
      headers: {
        'Cache-Control': 'no-cache',
        'Pragma': 'no-cache',
        ...(process.env.GITHUB_TOKEN ? { Authorization: `token ${process.env.GITHUB_TOKEN}` } : {}),
      },
    });

    if (!githubRes.ok) {
      return res.status(githubRes.status).json({ error: 'Failed to fetch from GitHub', status: githubRes.status });
    }

    res.setHeader('Cache-Control', 'no-store');
    return res.status(200).json(await githubRes.json());
  } catch (err) {
    console.error('[fetchGeoJson]', err);
    return res.status(500).json({ error: err.message ?? String(err) });
  }
}
