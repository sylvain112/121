const $ = (s) => document.querySelector(s);

const state = {
  active: false,
  connecting: false,
  stream: null,
  pc: null,
  dc: null,
  remoteAudio: null,
  audioCtx: null,
  analyser: null,
  sourceNode: null,
  raf: 0,
  speaking: false,
  aboveSince: 0,
  silenceSince: 0,
  noiseFloor: 0.008,
  currentTarget: "fr",
  targetUpdatePending: null,
  turn: null,
  finalizeTimer: 0,
  messages: JSON.parse(localStorage.getItem("zhfr.v92.messages") || "[]"),
};

const el = {
  status: $("#status"),
  statusText: $("#statusText"),
  topic: $("#topic"),
  voice: $("#voiceToggle"),
  talk: $("#talkButton"),
  talkLabel: $("#talkLabel"),
  meter: $("#meter"),
  live: $("#liveText"),
  messages: $("#messages"),
  empty: $("#empty"),
  processing: $("#processing"),
  liveSource: $("#liveSource"),
  liveTranslation: $("#liveTranslation"),
  summaryCard: $("#summaryCard"),
  summaryText: $("#summaryText"),
  agentDialog: $("#agentDialog"),
  agentInput: $("#agentInput"),
  agentAnswer: $("#agentAnswer"),
};

el.topic.value = localStorage.getItem("zhfr.v92.topic") || "";
el.voice.checked = localStorage.getItem("zhfr.v92.voice") === "1";

el.topic.oninput = () => localStorage.setItem("zhfr.v92.topic", el.topic.value);
el.voice.onchange = () => {
  localStorage.setItem("zhfr.v92.voice", el.voice.checked ? "1" : "0");
  if (state.remoteAudio) state.remoteAudio.muted = !el.voice.checked;
};

function setStatus(text, mode = "") {
  el.statusText.textContent = text;
  el.status.classList.remove("online", "busy");
  if (mode) el.status.classList.add(mode);
}
function setLive(text) {
  el.live.textContent = text;
}
function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  }[c]));
}
function now() {
  return new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}
function save() {
  localStorage.setItem("zhfr.v92.messages", JSON.stringify(state.messages));
}
function render() {
  el.messages.innerHTML = "";
  if (!state.messages.length) {
    el.messages.appendChild(el.empty);
    el.empty.hidden = false;
  } else {
    for (const m of state.messages) {
      const div = document.createElement("div");
      div.className = `msg ${m.sourceLang}`;
      const dir = m.sourceLang === "zh"
        ? "🇨🇳 中文 → 🇫🇷 Français"
        : "🇫🇷 Français → 🇨🇳 中文";
      div.innerHTML = `
        <div class="msgtop">
          <span class="dir">${dir}</span>
          <span class="time">${esc(m.time)}</span>
        </div>
        <div class="original">${esc(m.original)}</div>
        <div class="translation">${esc(m.translation)}</div>`;
      el.messages.appendChild(div);
    }
  }
  el.messages.scrollTop = el.messages.scrollHeight;
}

function newTurn() {
  return {
    source: "",
    translation: "",
    lang: null,
    startedAt: Date.now(),
    lastSourceAt: 0,
    lastOutputAt: 0,
    stoppedAt: 0,
  };
}
function ensureTurn() {
  if (!state.turn) state.turn = newTurn();
  return state.turn;
}
function detectSourceLanguage(text) {
  const t = String(text || "");
  const han = (t.match(/[\u3400-\u9fff]/g) || []).length;
  const latin = (t.match(/[A-Za-zÀ-ÿŒœÇç]/g) || []).length;
  if (han >= 1) return "zh";
  if (latin >= 3) return "fr";
  return null;
}
function updateLiveTurn() {
  const t = state.turn;
  if (!t) {
    el.processing.hidden = true;
    el.liveSource.textContent = "";
    el.liveTranslation.textContent = "";
    return;
  }
  el.processing.hidden = false;
  el.liveSource.textContent = t.source || "…";
  el.liveTranslation.textContent = t.translation || "…";
}

async function setTarget(language, { clearOutput = false } = {}) {
  if (!["zh", "fr"].includes(language)) return;
  if (clearOutput && state.turn) {
    state.turn.translation = "";
    updateLiveTurn();
  }
  if (state.currentTarget === language && !state.targetUpdatePending) return;
  if (!state.dc || state.dc.readyState !== "open") {
    state.currentTarget = language;
    return;
  }
  state.currentTarget = language;
  state.targetUpdatePending = language;
  state.dc.send(JSON.stringify({
    type: "session.update",
    session: {
      audio: {
        input: {
          transcription: { model: "gpt-realtime-whisper" },
          noise_reduction: { type: "far_field" }
        },
        output: { language }
      }
    }
  }));
}

function handleInputDelta(event) {
  const delta = typeof event.delta === "string" ? event.delta.replace(/\uFFFD/g, "") : "";
  if (!delta) return;
  const t = ensureTurn();
  t.source += delta;
  t.lastSourceAt = Date.now();

  const detected = detectSourceLanguage(t.source);
  if (detected && detected !== t.lang) {
    t.lang = detected;
    if (detected === "fr") {
      setTarget("zh", { clearOutput: true });
      setStatus("Français → 中文", "online");
      setLive("已识别法语，正在实时翻译成中文…");
    } else {
      setTarget("fr");
      setStatus("中文 → Français", "online");
      setLive("已识别中文，正在实时翻译成法语…");
    }
  }
  updateLiveTurn();
}

function handleOutputDelta(event) {
  const delta = typeof event.delta === "string" ? event.delta.replace(/\uFFFD/g, "") : "";
  if (!delta) return;
  const t = ensureTurn();

  if (!t.lang && state.currentTarget === "fr") {
    t.lang = "zh";
    setStatus("中文 → Français", "online");
  }

  t.translation += delta;
  t.lastOutputAt = Date.now();
  updateLiveTurn();

  if (t.lang === "zh") setLive("正在实时翻译成法语…");
  else if (t.lang === "fr") setLive("正在实时翻译成中文…");
  else setLive("正在实时翻译…");

  if (t.stoppedAt) scheduleFinalize(550);
}

function handleRealtimeEvent(raw) {
  let event;
  try {
    event = JSON.parse(raw);
  } catch {
    return;
  }

  if (event.type === "session.created") {
    setLive("Translation 会话已建立");
    return;
  }
  if (event.type === "session.updated") {
    state.targetUpdatePending = null;
    return;
  }
  if (event.type === "session.input_transcript.delta") {
    handleInputDelta(event);
    return;
  }
  if (event.type === "session.output_transcript.delta") {
    handleOutputDelta(event);
    return;
  }
  if (event.type === "error") {
    console.error("Realtime Translation error", event);
    setStatus("接口错误");
    setLive(event.error?.message || "Realtime Translation error");
  }
}

function scheduleFinalize(delay = 700) {
  clearTimeout(state.finalizeTimer);
  state.finalizeTimer = setTimeout(() => {
    const t = state.turn;
    if (!t) return;
    const ts = Date.now();
    const stoppedFor = t.stoppedAt ? ts - t.stoppedAt : 0;
    const outIdle = t.lastOutputAt ? ts - t.lastOutputAt : 99999;
    const sourceIdle = t.lastSourceAt ? ts - t.lastSourceAt : 99999;

    if (t.stoppedAt && stoppedFor > 550 && outIdle > 450 && sourceIdle > 450) {
      finalizeTurn();
    } else if (t.stoppedAt && stoppedFor > 2600) {
      finalizeTurn();
    } else {
      scheduleFinalize(300);
    }
  }, delay);
}

function finalizeTurn() {
  clearTimeout(state.finalizeTimer);
  const t = state.turn;
  if (!t) return;

  let lang = t.lang;
  if (!lang && t.translation && state.currentTarget === "fr") lang = "zh";
  if (!lang && /[\u3400-\u9fff]/.test(t.source)) lang = "zh";
  if (!lang && /[A-Za-zÀ-ÿŒœÇç]{3}/.test(t.source)) lang = "fr";

  const original = t.source.trim();
  const translation = t.translation.trim();
  if (original && translation && lang) {
    state.messages.push({
      sourceLang: lang,
      original,
      translation,
      time: now(),
    });
    save();
    render();
  }

  state.turn = null;
  updateLiveTurn();
  if (state.active) {
    setStatus("同传中", "online");
    setLive("继续讲话即可");
  }
}

function vadLoop() {
  if (!state.active || !state.analyser) return;
  const samples = new Float32Array(state.analyser.fftSize);
  state.analyser.getFloatTimeDomainData(samples);
  let sum = 0;
  for (const x of samples) sum += x * x;
  const rms = Math.sqrt(sum / samples.length);
  el.meter.style.width = `${Math.min(100, rms * 900)}%`;

  if (!state.speaking && rms < 0.04) {
    state.noiseFloor = 0.985 * state.noiseFloor + 0.015 * rms;
  }

  const threshold = Math.max(0.012, state.noiseFloor * 2.8);
  const ts = performance.now();

  if (rms > threshold) {
    state.silenceSince = 0;
    if (!state.aboveSince) state.aboveSince = ts;

    if (!state.speaking && ts - state.aboveSince > 90) {
      if (state.turn?.stoppedAt) finalizeTurn();
      state.speaking = true;
      state.turn = newTurn();
      setTarget("fr", { clearOutput: true });
      setStatus("正在听", "busy");
      setLive("讲话中：实时识别方向并同步翻译…");
      updateLiveTurn();
    }
  } else {
    state.aboveSince = 0;
    if (state.speaking) {
      if (!state.silenceSince) state.silenceSince = ts;
      if (ts - state.silenceSince > 520) {
        state.speaking = false;
        state.silenceSince = 0;
        const t = ensureTurn();
        t.stoppedAt = Date.now();
        setLive("检测到停顿，等待最后几个实时片段…");
        scheduleFinalize(550);
      }
    }
  }

  state.raf = requestAnimationFrame(vadLoop);
}

function waitForDataChannelOpen(dc, timeoutMs = 8000) {
  if (dc.readyState === "open") return Promise.resolve();
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      cleanup();
      reject(new Error("Realtime DataChannel 连接超时"));
    }, timeoutMs);
    const onOpen = () => {
      cleanup();
      resolve();
    };
    const onError = () => {
      cleanup();
      reject(new Error("Realtime DataChannel 连接失败"));
    };
    const cleanup = () => {
      clearTimeout(timeout);
      dc.removeEventListener("open", onOpen);
      dc.removeEventListener("error", onError);
    };
    dc.addEventListener("open", onOpen, { once: true });
    dc.addEventListener("error", onError, { once: true });
  });
}

async function start() {
  if (state.active || state.connecting) return;
  state.connecting = true;
  el.talkLabel.textContent = "正在连接…";
  setStatus("连接中", "busy");
  setLive("正在建立官方 Realtime Translation 通道…");

  try {
    state.stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true,
      },
    });

    const sessionResponse = await fetch("/api/session", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ target: "fr" }),
    });
    const session = await sessionResponse.json();

    if (!sessionResponse.ok) {
      throw new Error(session.error?.message || session.error || "创建 Translation session 失败");
    }
    if (!session.client_secret) {
      throw new Error("Translation session 没有返回 client_secret");
    }

    state.pc = new RTCPeerConnection();
    state.dc = state.pc.createDataChannel("oai-events");

    state.remoteAudio = new Audio();
    state.remoteAudio.autoplay = true;
    state.remoteAudio.playsInline = true;
    state.remoteAudio.muted = !el.voice.checked;

    state.pc.ontrack = ({ streams }) => {
      state.remoteAudio.srcObject = streams[0];
      if (el.voice.checked) state.remoteAudio.play().catch(() => {});
    };

    state.pc.onconnectionstatechange = () => {
      const s = state.pc?.connectionState;
      console.log("webrtc.connection", s);
      if (state.active && ["failed", "disconnected", "closed"].includes(s)) {
        setStatus("连接中断");
        setLive(`WebRTC ${s}`);
      }
    };

    state.dc.onmessage = ({ data }) => handleRealtimeEvent(data);
    state.dc.onerror = (e) => {
      console.error("datachannel.error", e);
      setLive("Realtime DataChannel 出现错误");
    };

    for (const track of state.stream.getAudioTracks()) {
      state.pc.addTrack(track, state.stream);
    }

    const offer = await state.pc.createOffer();
    await state.pc.setLocalDescription(offer);

    const sdpResponse = await fetch("https://api.openai.com/v1/realtime/translations/calls", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${session.client_secret}`,
        "Content-Type": "application/sdp",
      },
      body: offer.sdp,
    });

    const answerSdp = await sdpResponse.text();
    if (!sdpResponse.ok) throw new Error(answerSdp);

    await state.pc.setRemoteDescription({
      type: "answer",
      sdp: answerSdp,
    });

    await waitForDataChannelOpen(state.dc);

    state.audioCtx = new (window.AudioContext || window.webkitAudioContext)();
    await state.audioCtx.resume();
    state.analyser = state.audioCtx.createAnalyser();
    state.analyser.fftSize = 1024;
    state.sourceNode = state.audioCtx.createMediaStreamSource(state.stream);
    state.sourceNode.connect(state.analyser);

    state.currentTarget = "fr";
    state.active = true;
    el.talk.classList.add("active");
    el.talkLabel.textContent = "结束同传";
    setStatus("同传中", "online");
    setLive("已连接：讲话过程中会直接出现译文");
    vadLoop();
  } catch (err) {
    console.error(err);
    await stop(false);
    setStatus("启动失败");
    setLive(err.message);
    alert(`无法启动实时同传：${err.message}`);
  } finally {
    state.connecting = false;
    if (!state.active) el.talkLabel.textContent = "开始同传";
  }
}

async function stop(update = true) {
  state.active = false;
  state.connecting = false;
  cancelAnimationFrame(state.raf);
  clearTimeout(state.finalizeTimer);

  if (state.turn) finalizeTurn();

  try { state.dc?.close(); } catch {}
  try { state.pc?.close(); } catch {}
  try { state.stream?.getTracks().forEach((t) => t.stop()); } catch {}
  try { state.sourceNode?.disconnect(); } catch {}
  try { await state.audioCtx?.close(); } catch {}
  try {
    if (state.remoteAudio) {
      state.remoteAudio.pause();
      state.remoteAudio.srcObject = null;
    }
  } catch {}

  state.pc = null;
  state.dc = null;
  state.stream = null;
  state.remoteAudio = null;
  state.audioCtx = null;
  state.analyser = null;
  state.sourceNode = null;
  state.turn = null;
  state.speaking = false;
  state.aboveSince = 0;
  state.silenceSince = 0;
  state.currentTarget = "fr";
  state.targetUpdatePending = null;

  el.talk.classList.remove("active");
  el.talkLabel.textContent = "开始同传";
  el.meter.style.width = "0";
  updateLiveTurn();
  setStatus("未连接");
  if (update) setLive("同传已结束");
}

el.talk.onclick = () => state.active || state.connecting ? stop() : start();

$("#copyBtn").onclick = async () => {
  if (!state.messages.length) return;
  const text = state.messages.map((m) =>
    `[${m.time}] ${m.sourceLang === "zh" ? "中文→法语" : "法语→中文"}\n原文：${m.original}\n译文：${m.translation}`
  ).join("\n\n");
  await navigator.clipboard.writeText(text);
  setLive("对话已复制");
};

$("#clearBtn").onclick = async () => {
  if (!confirm("确定清空本次全部记录吗？")) return;
  state.messages = [];
  save();
  render();
  el.summaryCard.hidden = true;
  el.summaryText.textContent = "";
  setLive("记录已清空");
};

$("#agentBtn").onclick = () => {
  el.agentAnswer.hidden = true;
  el.agentAnswer.textContent = "";
  el.agentDialog.showModal();
  setTimeout(() => el.agentInput.focus(), 50);
};

$("#agentClose").onclick = () => el.agentDialog.close();

$("#agentSend").onclick = async () => {
  const q = el.agentInput.value.trim();
  if (!q) return;

  el.agentAnswer.hidden = false;
  el.agentAnswer.textContent = "AI 正在处理…";
  try {
    const r = await fetch("/api/assistant", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        mode: "agent",
        question: q,
        topic: el.topic.value.trim(),
        transcript: state.messages,
      }),
    });
    const d = await r.json();
    if (!r.ok) throw new Error(d.error || "请求失败");
    el.agentAnswer.textContent = d.text;
  } catch (e) {
    el.agentAnswer.textContent = `出错：${e.message}`;
  }
};

$("#summaryBtn").onclick = async () => {
  if (!state.messages.length) return alert("目前还没有可总结的对话。");

  el.summaryCard.hidden = false;
  el.summaryText.textContent = "正在整理本次谈话…";
  el.summaryCard.scrollIntoView({ behavior: "smooth" });

  try {
    const r = await fetch("/api/assistant", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        mode: "summary",
        topic: el.topic.value.trim(),
        transcript: state.messages,
      }),
    });
    const d = await r.json();
    if (!r.ok) throw new Error(d.error || "总结失败");
    el.summaryText.textContent = d.text;
  } catch (e) {
    el.summaryText.textContent = `总结失败：${e.message}`;
  }
};

$("#copySummary").onclick = async () => {
  if (!el.summaryText.textContent) return;
  await navigator.clipboard.writeText(el.summaryText.textContent);
  setLive("总结已复制");
};

window.addEventListener("beforeunload", () => {
  if (state.active) {
    try { state.dc?.close(); } catch {}
    try { state.pc?.close(); } catch {}
    try { state.stream?.getTracks().forEach((t) => t.stop()); } catch {}
  }
});

render();
