// api/uploadGeoJsonToBlob.js
import { put } from '@vercel/blob';
import { v4 as uuidv4 } from 'uuid'; // npm install uuid

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
    const { geojson, shareId: rawShareId } = req.body ?? {};
    if (!geojson) {
      return res.status(400).json({ error: 'No geojson provided' });
    }

    const shareId = (rawShareId ?? uuidv4()).replace(/[^a-zA-Z0-9-]/g, '');
    const filename = `shared/${shareId}.geojson`;

    const blob = await put(filename, JSON.stringify(geojson), {
      access: 'public',           // 公開
      addRandomSuffix: false,     // 同じshareIdで上書きしたい場合
      cacheControlMaxAge: 0,      // キャッシュを最小に（即時反映重視）
    });

    const shareUrl = `${window.location.origin}/?geojson=${encodeURIComponent(blob.url)}`;

    return res.status(200).json({
      success: true,
      rawUrl: blob.url,           // これを保存・共有に使用
      shareUrl,
      shareId,
    });

  } catch (err) {
    console.error(err);
    return res.status(500).json({ error: err.message });
  }
}