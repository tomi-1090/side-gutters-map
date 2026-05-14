export default async function handler(req, res) {
  try {
    console.log('TOKEN EXISTS:', !!process.env.GITHUB_TOKEN);
      console.log(
        'TOKEN START:',
        process.env.GITHUB_TOKEN?.substring(0, 10)
      );
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
    const owner = 'tomi1090';
    const repo = 'side-gutter-map';

    // ファイル名
    const fileId = Date.now();
    const path = `shared/${fileId}.geojson`;

    // GitHub API URL
    const apiUrl =
      `https://api.github.com/repos/${owner}/${repo}/contents/${path}`;

    // Base64化
    const contentBase64 = Buffer.from(
      JSON.stringify(body.geojson, null, 2)
    ).toString('base64');

    // GitHubへ保存
    const githubRes = await fetch(apiUrl, {
      method: 'PUT',
      headers: {
        Authorization: `Bearer ${process.env.GITHUB_TOKEN}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        message: `upload ${fileId}`,
        content: contentBase64,
      }),
    });

    const githubData = await githubRes.json();

    if (!githubRes.ok) {
      return res.status(500).json(githubData);
    }

    // Raw URL
    const rawUrl =
      `https://raw.githubusercontent.com/${owner}/${repo}/main/${path}`;

    return res.status(200).json({
      success: true,
      rawUrl,
    });

  } catch (e) {
    return res.status(500).json({
      error: e.toString(),
    });
  }
}