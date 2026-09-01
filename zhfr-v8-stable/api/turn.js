function extractResponseText(data) {
  const out = [];
  for (const item of (data?.output || [])) {
    for (const part of (item?.content || [])) {
      if (typeof part?.text === "string") out.push(part.text);
    }
  }
  return out.join("\n").trim();
}

function fallbackLanguage(text) {
  const zh = (text.match(/[\u3400-\u9fff]/g) || []).length;
  const latin = (text.match(/[A-Za-zÀ-ÿŒœÇç]/g) || []).length;
  return zh >= Math.max(1, latin * 0.15) ? "zh" : "fr";
}

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
    const audio = body.audio;
    const mimeType = String(body.mimeType || "audio/webm").split(";")[0];
    const topic = String(body.topic || "").trim().slice(0, 600);

    if (!audio) return res.status(400).json({ error: "没有收到音频。" });

    const buffer = Buffer.from(audio, "base64");
    if (buffer.length > 4_000_000) {
      return res.status(413).json({ error: "单句话音频太长，请分段说。" });
    }

    const ext =
      mimeType.includes("mp4") ? "m4a" :
      mimeType.includes("wav") ? "wav" :
      mimeType.includes("mpeg") ? "mp3" : "webm";

    const form = new FormData();
    form.append("model", process.env.OPENAI_TRANSCRIBE_MODEL || "gpt-transcribe");
    form.append("file", new Blob([buffer], { type: mimeType }), `turn.${ext}`);
    form.append("languages[]", "zh");
    form.append("languages[]", "fr");
    form.append(
      "prompt",
      [
        "This is a face-to-face conversation between a Mandarin Chinese speaker and a French speaker.",
        "Transcribe exactly what is spoken in the original language.",
        "Do not translate during transcription.",
        topic ? `Conversation topic: ${topic}` : ""
      ].filter(Boolean).join(" ")
    );

    const tr = await fetch("https://api.openai.com/v1/audio/transcriptions", {
      method: "POST",
      headers: { Authorization: `Bearer ${process.env.OPENAI_API_KEY}` },
      body: form
    });

    const transcriptData = await tr.json();
    if (!tr.ok) {
      return res.status(tr.status).json({ error: transcriptData?.error?.message || "语音识别失败。" });
    }

    const original = String(transcriptData.text || "").trim();
    if (!original) return res.status(200).json({ original: "", sourceLang: "zh", translation: "" });

    let sourceLang = transcriptData.languages?.[0]?.code;
    if (!["zh", "fr"].includes(sourceLang)) sourceLang = fallbackLanguage(original);

    const target = sourceLang === "fr" ? "Simplified Chinese" : "French";
    const source = sourceLang === "fr" ? "French" : "Mandarin Chinese";

    const rr = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${process.env.OPENAI_API_KEY}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        model: process.env.OPENAI_TRANSLATE_MODEL || "gpt-5.6-luna",
        reasoning: { effort: "none" },
        instructions: [
          `Translate strictly from ${source} to ${target}.`,
          "Return ONLY the translation.",
          "Do not answer questions, explain, summarize, add labels, or add quotation marks.",
          "Preserve names, numbers, dates, money, addresses, institutional terms, uncertainty and tone.",
          "If the transcript contains recognition noise, translate only the meaning actually present; do not invent missing content.",
          topic ? `Conversation topic: ${topic}` : ""
        ].filter(Boolean).join(" "),
        input: original,
        max_output_tokens: 1000
      })
    });

    const responseData = await rr.json();
    if (!rr.ok) {
      return res.status(rr.status).json({ error: responseData?.error?.message || "翻译失败。" });
    }

    const translation = extractResponseText(responseData);
    return res.status(200).json({ original, sourceLang, translation });
  } catch (err) {
    console.error(err);
    return res.status(500).json({ error: err?.message || "处理语音失败。" });
  }
}