// api/uploadToBlob.js
import { put } from '@vercel/blob';
import { v4 as uuidv4 } from 'uuid';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

export default async function handler(req, res) {
  if (req.method === 'OPTIONS') return res.status(204).set(CORS_HEADERS).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  try {
    const { geojson, shareId: rawShareId } = req.body || {};
    if (!geojson) return res.status(400).json({ error: 'No geojson data' });

    const shareId = rawShareId?.length > 8 ? rawShareId : uuidv4();
    const blob = await put(`shared/${shareId}.geojson`, JSON.stringify(geojson), {
      access: 'public',
      addRandomSuffix: false,
      allowOverwrite: true,
      cacheControlMaxAge: 0,
    });

    return res.status(200).json({
      success: true,
      rawUrl: blob.url,
      shareUrl: `${req.headers.origin}/?geojson=${encodeURIComponent(blob.url)}`,
      shareId,
    });
  } catch (error) {
    console.error('[uploadToBlob]', error);
    return res.status(500).json({ error: error.message });
  }
}
