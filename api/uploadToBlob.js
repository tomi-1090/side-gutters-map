// api/uploadToBlob.js
import { put } from '@vercel/blob';
import { v4 as uuidv4 } from 'uuid';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

function setCors(res) {
  Object.entries(CORS_HEADERS).forEach(([k, v]) => res.setHeader(k, v));
}

export default async function handler(req, res) {
  setCors(res);

  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'POST')   return res.status(405).json({ error: 'Method not allowed' });

  try {
    const { geojson, shareId: rawShareId } = req.body || {};
    if (!geojson) return res.status(400).json({ error: 'No geojson data' });

    const shareId = typeof rawShareId === 'string' && rawShareId.length > 8
      ? rawShareId
      : uuidv4();

    // @vercel/blob の put() は同じパスへの上書きを allowOverwrite オプションで制御する。
    // ライブラリバージョンによってオプション名が異なるため、両方を渡して対応。
    const blob = await put(
      `shared/${shareId}.geojson`,
      JSON.stringify(geojson),
      {
        access          : 'public',
        addRandomSuffix : false,
        allowOverwrite  : true,   // @vercel/blob >= 0.22
        cacheControlMaxAge: 0,
      },
    );

    const shareUrl = `${req.headers.origin}/?geojson=${encodeURIComponent(blob.url)}`;

    return res.status(200).json({
      success : true,
      rawUrl  : blob.url,
      shareUrl,
      shareId,
    });

  } catch (error) {
    // Vercel のログに詳細を出力
    console.error('[uploadToBlob] error:', error?.message ?? error);
    console.error('[uploadToBlob] stack:', error?.stack);
    return res.status(500).json({
      error : error?.message ?? String(error),
      hint  : 'Check Vercel function logs for details.',
    });
  }
}