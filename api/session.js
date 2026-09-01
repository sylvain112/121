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

    const payload = {
      expires_after: { anchor: "created_at", seconds: 600 },
      session: {
        model: "gpt-realtime-translate",
        audio: {
          input: {
            transcription: transcribe ? { model: "gpt-realtime-whisper" } : null,
            noise_reduction: { type: "far_field" }
          },
          output: { language: target }
        }
      }
    };

    const r = await fetch("https://api.openai.com/v1/realtime/translations/client_secrets", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${process.env.OPENAI_API_KEY}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify(payload)
    });

    const data = await r.json();
    if (!r.ok) {
      return res.status(r.status).json({ error: data?.error?.message || "创建 Translation client secret 失败。" });
    }

    return res.status(200).json({
      client_secret: data.value,
      expires_at: data.expires_at,
      target
    });
  } catch (err) {
    console.error(err);
    return res.status(500).json({ error: err?.message || "创建 Translation client secret 失败。" });
  }
}
