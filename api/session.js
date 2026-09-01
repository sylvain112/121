export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return res.status(405).json({ error: "Method not allowed" });
  }
  if (!process.env.OPENAI_API_KEY) {
    return res.status(500).json({ error: "Vercel 尚未配置 OPENAI_API_KEY。" });
  }

  try {
    const body = typeof req.body === "string" ? JSON.parse(req.body || "{}") : (req.body || {});
    const target = body.target === "zh" ? "zh" : body.target === "fr" ? "fr" : null;
    const transcribe = Boolean(body.transcribe);
    if (!target) return res.status(400).json({ error: "target 必须是 zh 或 fr。" });

    const input = {
      noise_reduction: { type: "far_field" },
      ...(transcribe ? { transcription: { model: "gpt-realtime-whisper" } } : {}),
    };

    const response = await fetch(
      "https://api.openai.com/v1/realtime/translations/client_secrets",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${process.env.OPENAI_API_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          session: {
            model: "gpt-realtime-translate",
            audio: {
              input,
              output: { language: target },
            },
          },
        }),
      },
    );

    const data = await response.json();

    if (!response.ok) {
      return res.status(response.status).json({
        error: data?.error?.message || "创建 Translation client secret 失败。",
      });
    }

    if (!data || typeof data.value !== "string") {
      return res.status(502).json({
        error: "OpenAI 没有返回 Translation client secret。",
      });
    }

    return res.status(200).json({
      client_secret: data.value,
      expires_at: data.expires_at ?? null,
      target,
      transcribe,
    });
  } catch (err) {
    console.error(err);
    return res.status(500).json({
      error: err?.message || "创建 Translation client secret 失败。",
    });
  }
}
