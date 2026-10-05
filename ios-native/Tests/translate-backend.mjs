import assert from "node:assert/strict";
import handler from "../../api/translate.js";

process.env.OPENAI_API_KEY = "test-key";
let payload;
globalThis.fetch = async (_url, options) => {
  payload = JSON.parse(options.body);
  return { ok: true, status: 200, json: async () => ({ output: [{ type: "message", content: [{ type: "output_text", text: "这个学期很难。" }] }] }) };
};
function response() {
  return { statusCode: 200, headers: {}, setHeader(key, value) { this.headers[key] = value; }, status(code) { this.statusCode = code; return this; }, json(body) { this.body = body; return this; } };
}
for (const model of ["gpt-6-luna", "gpt-4o-mini", "gpt-6.1-sol", "gpt-6-astra"]) {
  const res = response();
  await handler({ method: "POST", body: { original: "Le semestre a été difficile.", sourceLang: "fr", model } }, res);
  assert.equal(res.statusCode, 200);
  assert.equal(res.body.translation, "这个学期很难。");
  assert.equal(payload.input, "Le semestre a été difficile.");
  assert.equal(payload.model, model);
  assert.equal(payload.audio, undefined);
  assert.equal(payload.transcription, undefined);
  if (model === "gpt-4o-mini") assert.equal(payload.reasoning, undefined);
}
for (const body of [{ original: "Hi", sourceLang: "en" }, { original: "", sourceLang: "fr" }, { original: "x".repeat(6001), sourceLang: "fr" }, { original: "Bonjour", sourceLang: "fr", model: "unknown" }]) {
  const res = response();
  await handler({ method: "POST", body }, res);
  assert.equal(res.statusCode, 400);
}
let res = response();
await handler({ method: "GET" }, res);
assert.equal(res.statusCode, 405);
globalThis.fetch = async () => ({ ok: false, status: 429, json: async () => ({ error: { code: "credit_balance_exhausted", message: "Private upstream details" } }) });
res = response();
await handler({ method: "POST", body: { original: "Bonjour", sourceLang: "fr" } }, res);
assert.equal(res.statusCode, 429);
assert.equal(res.body.code, "credit_balance_exhausted");
assert(!res.body.error.includes("Private"));
globalThis.fetch = async () => ({ ok: true, status: 200, json: async () => ({ output: [] }) });
res = response();
await handler({ method: "POST", body: { original: "Bonjour", sourceLang: "fr" } }, res);
assert.equal(res.statusCode, 502);
delete process.env.OPENAI_API_KEY;
res = response();
await handler({ method: "POST", body: { original: "Bonjour", sourceLang: "fr" } }, res);
assert.equal(res.statusCode, 503);
console.log("PASS: four text models, text-only payloads, input validation, empty replies and API errors");
