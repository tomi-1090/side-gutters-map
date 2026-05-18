// ================================================================
// api/fetchGeoJson.js
// GitHub Raw から GeoJSON を取得して返す Vercel Serverless Function
//
// 【なぜこのプロキシが必要か】
//   ブラウザから raw.githubusercontent.com へ直接 fetch すると
//   CORS ポリシーでブロックされる（Access-Control-Allow-Origin が
//   GitHub Raw には設定されていないため）。
//   このサーバーサイド関数を経由することで CORS を回避する。
// ================================================================

const GITHUB_OWNER = 'tomi-1090';
const GITHUB_REPO  = 'side-gutters-map';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin' : '*',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

export default async function handler(req, res) {
  // ── プリフライト ────────────────────────────────────────────────
  if (req.method === 'OPTIONS') {
    return res.status(204).set(CORS_HEADERS).end();
  }

  Object.entries(CORS_HEADERS).forEach(([k, v]) => res.setHeader(k, v));

  if (req.method !== 'GET') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  // ── shareId の取得とバリデーション ────────────────────────────
  const { shareId } = req.query;
  if (!shareId || !/^[\w-]+$/.test(shareId)) {
    return res.status(400).json({ error: 'Invalid or missing shareId' });
  }

  const filePath = `shared/${encodeURIComponent(shareId)}.geojson`;
  // キャッシュバスターをサーバー側でつける（GitHub Raw CDN 対策）
  const rawUrl = `https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/main/${filePath}?t=${Date.now()}`;

  try {
    const githubRes = await fetch(rawUrl, {
      headers: {
        'Cache-Control': 'no-cache',
        'Pragma'       : 'no-cache',
        // GitHub Token があればレート制限を緩和できる（任意）
        ...(process.env.GITHUB_TOKEN
          ? { Authorization: `token ${process.env.GITHUB_TOKEN}` }
          : {}),
      },
    });

    if (!githubRes.ok) {
      return res.status(githubRes.status).json({
        error : 'Failed to fetch from GitHub',
        status: githubRes.status,
      });
    }

    const geojson = await githubRes.json();

    // Vercel Edge / CDN にキャッシュさせない
    res.setHeader('Cache-Control', 'no-store');
    return res.status(200).json(geojson);

  } catch (err) {
    console.error('[fetchGeoJson] Error:', err);
    return res.status(500).json({ error: err.message ?? String(err) });
  }
}