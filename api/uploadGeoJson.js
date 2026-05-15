export default async function handler(req, res) {
  try {
    if (req.method !== 'POST') {
      return res.status(405).json({ error: 'Method not allowed' });
    }

    const body = req.body;

    if (!body.geojson) {
      return res.status(400).json({ error: 'No geojson' });
    }

    // =========================
    // GitHub設定
    // =========================

    const owner = 'tomi-1090';
    const repo = 'side-gutters-map';

    // ★ 固定shareId
    const fileId = body.shareId || Date.now().toString();

    const path = `shared/${fileId}.geojson`;

    const apiUrl =
      `https://api.github.com/repos/${owner}/${repo}/contents/${path}`;

    // =========================
    // 既存ファイル確認
    // =========================

    let sha = undefined;

    const checkRes = await fetch(apiUrl, {
      headers: {
        Authorization: `token ${process.env.GITHUB_TOKEN}`,
      },
    });

    if (checkRes.ok) {
      const checkData = await checkRes.json();
      sha = checkData.sha;
    }

    // =========================
    // Base64化
    // =========================

    const contentBase64 = Buffer.from(
      JSON.stringify(body.geojson, null, 2)
    ).toString('base64');

    // =========================
    // GitHubへ保存
    // =========================

    const githubRes = await fetch(apiUrl, {
      method: 'PUT',
      headers: {
        Authorization: `token ${process.env.GITHUB_TOKEN}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        message: `update ${fileId}`,
        content: contentBase64,

        // ★ 既存更新に必要
        sha: sha,
      }),
    });

    const githubData = await githubRes.json();

    if (!githubRes.ok) {
      return res.status(500).json(githubData);
    }

    // =========================
    // Raw URL
    // =========================

    const rawUrl =
      `https://raw.githubusercontent.com/${owner}/${repo}/main/${path}`;

    return res.status(200).json({
      success: true,
      rawUrl,
      shareId: fileId,
    });

  } catch (e) {
    return res.status(500).json({
      error: e.toString(),
    });
  }
}