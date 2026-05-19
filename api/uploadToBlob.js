// api/uploadToBlob.js
import { put } from '@vercel/blob';
import { v4 as uuidv4 } from 'uuid';   // ← UUIDでセキュリティ強化

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

    // shareIdをUUIDで強化（予測されにくい）
    const shareId = (rawShareId && rawShareId.length > 8) 
      ? rawShareId 
      : uuidv4();

    const filename = `shared/${shareId}.geojson`;

    const blob = await put(filename, JSON.stringify(geojson), {
      access: 'public',           // Public
      addRandomSuffix: false,
      cacheControlMaxAge: 0,
    });

    const shareUrl = `${req.headers.origin || 'https://side-gutters-map-xnop.vercel.app/'}/?geojson=${encodeURIComponent(blob.url)}`;

    return res.status(200).json({
      success: true,
      rawUrl: blob.url,
      shareUrl: shareUrl,
      shareId: shareId,
    });

  } catch (error) {
    console.error('[uploadToBlob]', error);
    return res.status(500).json({ error: error.message });
  }
}