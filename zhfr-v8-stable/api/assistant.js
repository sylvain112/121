function transcriptText(items = []) {
  return items.slice(-160).map((m, i) => {
    const d = m.sourceLang === "zh" ? "中文→法语" : "法语→中文";
    return `${i + 1}. [${m.time || ""} ${d}]\n原文：${m.original || ""}\n译文：${m.translation || ""}`;
  }).join("\n\n");
}
function extractText(data) {
  const out = [];
  for (const item of (data?.output || [])) {
    for (const part of (item?.content || [])) {
      if (typeof part?.text === "string") out.push(part.text);
    }
  }
  return out.join("\n").trim();
}
export default async function handler(req, res) {
  if (req.method !== "POST") return res.status(405).json({ error: "Method not allowed" });
  if (!process.env.OPENAI_API_KEY) return res.status(500).json({ error: "Vercel 尚未配置 OPENAI_API_KEY。" });
  try {
    const body = typeof req.body === "string" ? JSON.parse(req.body || "{}") : (req.body || {});
    const mode = body.mode === "summary" ? "summary" : "agent";
    const topic = String(body.topic || "").slice(0, 500);
    const transcript = Array.isArray(body.transcript) ? body.transcript : [];
    let instructions, input;
    if (mode === "summary") {
      instructions = "用简体中文总结中法现场谈话。必须忠于记录，不要虚构承诺。按需要使用：对话概要、关键信息、明确承诺/结论、待办事项、时间/金额/联系方式。无法确定的内容标记为待确认。";
      input = `谈话主题：${topic || "未填写"}\n\n完整对话：\n${transcriptText(transcript)}`;
    } else {
      const q = String(body.question || "").trim();
      if (!q) return res.status(400).json({ error: "缺少问题。" });
      instructions = "你是中法同传网页里的旁路 AI。主要用简体中文回答。必须区分对方实际说过的话和你的建议。如果用户要一句现场对法国人说的话，把自然法语放在第一行。回答尽量简洁。";
      input = `谈话主题：${topic || "未填写"}\n\n已有对话：\n${transcriptText(transcript)}\n\n用户问题：\n${q}`;
    }
    const r = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: { Authorization: `Bearer ${process.env.OPENAI_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ model: process.env.OPENAI_ASSISTANT_MODEL || "gpt-5.6-luna", reasoning: { effort: "low" }, instructions, input })
    });
    const data = await r.json();
    if (!r.ok) return res.status(r.status).json({ error: data?.error?.message || "AI 请求失败。" });
    return res.status(200).json({ text: extractText(data) });
  } catch (err) {
    return res.status(500).json({ error: err?.message || "AI 请求失败。" });
  }
}