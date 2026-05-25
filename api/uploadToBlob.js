// api/uploadToBlob.js
import { put } from '@vercel/blob';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

export default async function handler(req, res) {
  // CORSヘッダーを全レスポンスに付与
  Object.entries(CORS_HEADERS).forEach(([k, v]) => res.setHeader(k, v));

  if (req.method === 'OPTIONS') {
    return res.status(204).end();
  }

  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  try {
    // Vercelランタイムによってはreq.bodyが文字列のままの場合があるため手動パース
    let body = req.body;
    if (typeof body === 'string') {
      try { body = JSON.parse(body); } catch { body = {}; }
    }
    body = body || {};

    const { geojson, shareId: rawShareId } = body;

    if (!geojson) {
      return res.status(400).json({ error: 'No geojson data' });
    }

    // BLOB_READ_WRITE_TOKEN が設定されているか確認
    if (!process.env.BLOB_READ_WRITE_TOKEN) {
      console.error('[uploadToBlob] BLOB_READ_WRITE_TOKEN is not set');
      return res.status(500).json({ error: 'BLOB_READ_WRITE_TOKEN is not configured' });
    }

    // shareId：英数字・ハイフン・アンダーバーのみ許可（パストラバーサル対策）
    const shareId = /^[\w-]{1,}$/.test((rawShareId ?? '').trim())
      ? rawShareId.trim()
      : Date.now().toString();

    const filename = `shared/${shareId}.geojson`;
    const jsonBody = JSON.stringify(geojson);

    // @vercel/blob put API
    // allowOverwrite は SDK v0.22+ で対応。古いバージョンでは不要（putは上書きがデフォルト）
    const blob = await put(filename, jsonBody, {
      access         : 'public',
      addRandomSuffix: false,
      contentType    : 'application/geo+json',
    });

    // originヘッダーが無い場合のフォールバック
    const origin   = req.headers.origin ?? req.headers.host ?? '';
    const shareUrl = origin
      ? `${origin}/?geojson=${encodeURIComponent(blob.url)}`
      : blob.url;

    return res.status(200).json({
      success : true,
      rawUrl  : blob.url,
      shareUrl: shareUrl,
      shareId : shareId,
    });

  } catch (error) {
    console.error('[uploadToBlob] error:', error);
    // エラーの詳細をレスポンスに含めてデバッグを容易にする
    return res.status(500).json({
      error  : error.message ?? String(error),
      detail : error.stack   ?? '',
    });
  }
}