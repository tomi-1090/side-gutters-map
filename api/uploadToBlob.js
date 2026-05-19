// api/uploadToBlob.js
import { put } from '@vercel/blob';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

export default async function handler(req, res) {
  if (req.method === 'OPTIONS') {
    return res.status(204).set(CORS_HEADERS).end();
  }

  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  try {
    const { geojson, shareId: rawShareId } = req.body || {};
    if (!geojson) {
      return res.status(400).json({ error: 'No geojson data' });
    }

    const shareId = (rawShareId || Date.now().toString())
      .replace(/[^a-zA-Z0-9-]/g, '');

    const filename = `shared/${shareId}.geojson`;

    // Private対応
    const blob = await put(filename, JSON.stringify(geojson), {
      access: 'private',           // ← Privateに変更
      addRandomSuffix: false,
      cacheControlMaxAge: 0,
    });

    const shareUrl = `${req.headers.origin || 'https://side-gutters-map-xnop.vercel.app/'}/?geojson=${encodeURIComponent(blob.url)}`;

    return res.status(200).json({
      success: true,
      rawUrl: blob.url,        // これが署名付きURLになる
      shareUrl: shareUrl,
      shareId: shareId,
    });

  } catch (error) {
    console.error('[uploadToBlob]', error);
    return res.status(500).json({ error: error.message });
  }
}