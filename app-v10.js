const $ = (s) => document.querySelector(s);

const state = {
  active: false,
  connecting: false,
  stream: null,
  audioCtx: null,
  analyser: null,
  sourceNode: null,
  raf: 0,
  noiseFloor: 0.008,
  speaking: false,
  aboveSince: 0,
  silenceSince: 0,
  lanes: { fr: null, zh: null },
  turn: null,
  finalizeTimer: 0,
  messages: JSON.parse(localStorage.getItem("zhfr.v10.messages") || "[]"),
  diag: {
    fr: { dc: "closed", pc: "new", input: 0, output: 0, error: "" },
    zh: { dc: "closed", pc: "new", input: 0, output: 0, error: "" },
  },
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
  debug: $("#debugText"),
  summaryCard: $("#summaryCard"),
  summaryText: $("#summaryText"),
  agentDialog: $("#agentDialog"),
  agentInput: $("#agentInput"),
  agentAnswer: $("#agentAnswer"),
};

el.topic.value = localStorage.getItem("zhfr.v10.topic") || "";
el.voice.checked = localStorage.getItem("zhfr.v10.voice") === "1";
el.topic.oninput = () => localStorage.setItem("zhfr.v10.topic", el.topic.value);
el.voice.onchange = () => {
  localStorage.setItem("zhfr.v10.voice", el.voice.checked ? "1" : "0");
  applyAudioRouting();
};

function setStatus(text, mode = "") {
  el.statusText.textContent = text;
  el.status.classList.remove("online", "busy");
  if (mode) el.status.classList.add(mode);
}
function setLive(text) {
  el.live.textContent = text;
}
function esc(value) {
  return String(value ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}
function now() {
  return new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}
function save() {
  localStorage.setItem("zhfr.v10.messages", JSON.stringify(state.messages));
}
function render() {
  el.messages.innerHTML = "";
  if (!state.messages.length) {
    el.messages.appendChild(el.empty);
    el.empty.hidden = false;
  } else {
    for (const m of state.messages) {
      const card = document.createElement("div");
      card.className = `msg ${m.sourceLang}`;
      const dir = m.sourceLang === "zh"
        ? "🇨🇳 中文 → 🇫🇷 Français"
        : "🇫🇷 Français → 🇨🇳 中文";
      card.innerHTML = `
        <div class="msgtop"><span class="dir">${dir}</span><span class="time">${esc(m.time)}</span></div>
        <div class="original">${esc(m.original)}</div>
        <div class="translation">${esc(m.translation)}</div>`;
      el.messages.appendChild(card);
    }
  }
  el.messages.scrollTop = el.messages.scrollHeight;
}

function cleanDelta(value) {
  return String(value || "").replace(/\uFFFD/g, "");
}
function detectLang(text) {
  const s = String(text || "");
  const han = (s.match(/[\u3400-\u9fff]/g) || []).length;
  const latin = (s.match(/[A-Za-zÀ-ÿŒœÇç]/g) || []).length;
  if (han >= 1) return "zh";
  if (latin >= 3) return "fr";
  return null;
}
function newTurn() {
  return {
    source: "",
    outFr: "",
    outZh: "",
    lang: null,
    startedAt: Date.now(),
    lastSourceAt: 0,
    lastOutAt: 0,
    speechStoppedAt: 0,
  };
}
function ensureTurn() {
  if (!state.turn) state.turn = newTurn();
  return state.turn;
}
function chooseLane(turn = state.turn) {
  if (!turn) return null;
  if (turn.lang === "zh") return "fr";
  if (turn.lang === "fr") return "zh";
  if (turn.outFr && !turn.outZh) return "fr";
  if (turn.outZh && !turn.outFr) return "zh";
  return null;
}
function chosenOutput(turn = state.turn) {
  const lane = chooseLane(turn);
  if (!turn || !lane) return "";
  return lane === "fr" ? turn.outFr : turn.outZh;
}
function inferLang(turn = state.turn) {
  if (!turn) return null;
  if (turn.lang) return turn.lang;
  const fromText = detectLang(turn.source);
  if (fromText) return fromText;
  if (turn.outFr && !turn.outZh) return "zh";
  if (turn.outZh && !turn.outFr) return "fr";
  return null;
}
function applyAudioRouting() {
  const chosen = chooseLane(state.turn);
  for (const key of ["fr", "zh"]) {
    const lane = state.lanes[key];
    if (!lane?.audio) continue;
    lane.audio.muted = !el.voice.checked || chosen !== key;
    lane.audio.volume = 1;
    if (!lane.audio.muted) lane.audio.play().catch(() => {});
  }
}
function updateDebug() {
  if (!el.debug) return;
  const fr = state.diag.fr;
  const zh = state.diag.zh;
  const errors = [fr.error && `FR:${fr.error}`, zh.error && `ZH:${zh.error}`].filter(Boolean).join(" | ");
  el.debug.textContent =
    `FR dc:${fr.dc} pc:${fr.pc} out:${fr.output} · ` +
    `ZH dc:${zh.dc} pc:${zh.pc} out:${zh.output} · ` +
    `SRC:${fr.input}` +
    (errors ? ` · ${errors}` : "");
}
function updateLiveTurn() {
  const t = state.turn;
  if (!t) {
    el.processing.hidden = true;
    el.liveSource.textContent = "";
    el.liveTranslation.textContent = "";
    applyAudioRouting();
    return;
  }
  el.processing.hidden = false;
  el.liveSource.textContent = t.source || "…";
  const output = chosenOutput(t);
  el.liveTranslation.textContent = output || (t.lang ? "正在等待译文…" : "正在判断中文 / Français…");
  if (t.lang === "zh") setStatus("中文 → Français", "online");
  else if (t.lang === "fr") setStatus("Français → 中文", "online");
  else setStatus("识别语言中", "busy");
  applyAudioRouting();
}

function handleInputDelta(event) {
  const delta = cleanDelta(event.delta);
  if (!delta) return;
  state.diag.fr.input += 1;
  updateDebug();

  const t = ensureTurn();
  t.source += delta;
  t.lastSourceAt = Date.now();
  if (!t.lang) t.lang = detectLang(t.source);
  updateLiveTurn();
  if (t.speechStoppedAt) scheduleFinalize(700);
}
function handleOutputDelta(target, event) {
  const delta = cleanDelta(event.delta);
  if (!delta) return;
  state.diag[target].output += 1;
  updateDebug();

  const t = ensureTurn();
  if (target === "fr") t.outFr += delta;
  else t.outZh += delta;
  t.lastOutAt = Date.now();
  updateLiveTurn();
  if (t.speechStoppedAt) scheduleFinalize(650);
}

function handleLaneEvent(target, raw) {
  let event;
  try {
    event = JSON.parse(raw);
  } catch {
    state.diag[target].error = "non-JSON event";
    updateDebug();
    return;
  }

  if (event.type === "session.input_transcript.delta" && target === "fr") {
    handleInputDelta(event);
    return;
  }
  if (event.type === "session.output_transcript.delta") {
    handleOutputDelta(target, event);
    return;
  }
  if (event.type === "error") {
    const msg = event.error?.message || "Realtime error";
    state.diag[target].error = msg.slice(0, 100);
    updateDebug();
    setLive(`${target === "fr" ? "FR" : "ZH"} 通道错误：${msg}`);
    return;
  }
  if (event.type === "session.created" || event.type === "session.updated") {
    updateDebug();
  }
}

function scheduleFinalize(delay = 900) {
  clearTimeout(state.finalizeTimer);
  state.finalizeTimer = setTimeout(() => {
    const t = state.turn;
    if (!t) return;

    t.lang = inferLang(t);
    const n = Date.now();
    const sourceIdle = t.lastSourceAt ? n - t.lastSourceAt : 99999;
    const outputIdle = t.lastOutAt ? n - t.lastOutAt : 99999;
    const stoppedIdle = t.speechStoppedAt ? n - t.speechStoppedAt : 0;

    if (t.speechStoppedAt && sourceIdle > 700 && outputIdle > 650 && stoppedIdle > 850) {
      finalizeTurn();
    } else if (t.speechStoppedAt && stoppedIdle > 4200) {
      finalizeTurn();
    } else {
      scheduleFinalize(450);
    }
  }, delay);
}
function finalizeTurn() {
  clearTimeout(state.finalizeTimer);
  const t = state.turn;
  if (!t) return;

  t.lang = inferLang(t);
  const original = t.source.trim();
  const translation = chosenOutput(t).trim();

  if (original && t.lang && translation) {
    state.messages.push({
      sourceLang: t.lang,
      original,
      translation,
      time: now(),
    });
    save();
    render();
  } else if (original && !translation) {
    setLive("检测到原文，但该轮没有收到译文；诊断栏可查看通道状态");
  }

  state.turn = null;
  updateLiveTurn();
  if (state.active) {
    setStatus("同传中", "online");
    if (translation) setLive("继续讲话即可");
  }
}

function waitForDataChannel(dc, timeoutMs = 10000) {
  if (dc.readyState === "open") return Promise.resolve();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("DataChannel 打开超时")), timeoutMs);
    const onOpen = () => {
      clearTimeout(timer);
      dc.removeEventListener("open", onOpen);
      resolve();
    };
    dc.addEventListener("open", onOpen);
  });
}

async function createLane(target, transcribe, sourceTrack) {
  const response = await fetch("/api/session", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ target, transcribe }),
  });
  const session = await response.json();
  if (!response.ok) throw new Error(session.error || `创建 ${target} Translation session 失败`);
  if (!session.client_secret) throw new Error(`${target} Translation session 没有临时密钥`);

  const pc = new RTCPeerConnection();
  const dc = pc.createDataChannel("oai-events");
  const track = sourceTrack.clone();
  const laneStream = new MediaStream([track]);

  const audio = document.createElement("audio");
  audio.autoplay = true;
  audio.playsInline = true;
  audio.muted = true;
  audio.style.display = "none";
  document.body.appendChild(audio);

  pc.ontrack = ({ streams }) => {
    audio.srcObject = streams[0];
    applyAudioRouting();
  };
  pc.onconnectionstatechange = () => {
    state.diag[target].pc = pc.connectionState;
    updateDebug();
  };
  dc.onopen = () => {
    state.diag[target].dc = "open";
    updateDebug();
  };
  dc.onclose = () => {
    state.diag[target].dc = "closed";
    updateDebug();
  };
  dc.onerror = () => {
    state.diag[target].error = "datachannel error";
    updateDebug();
  };
  dc.onmessage = ({ data }) => handleLaneEvent(target, data);

  pc.addTrack(track, laneStream);

  const offer = await pc.createOffer();
  await pc.setLocalDescription(offer);

  const sdpResponse = await fetch("https://api.openai.com/v1/realtime/translations/calls", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${session.client_secret}`,
      "Content-Type": "application/sdp",
    },
    body: offer.sdp,
  });
  const answer = await sdpResponse.text();
  if (!sdpResponse.ok) throw new Error(answer);

  await pc.setRemoteDescription({ type: "answer", sdp: answer });
  await waitForDataChannel(dc);

  return { target, pc, dc, track, laneStream, audio };
}

function closeLane(lane) {
  if (!lane) return;
  try { lane.dc?.close(); } catch {}
  try { lane.pc?.close(); } catch {}
  try { lane.track?.stop(); } catch {}
  try { lane.audio?.pause(); } catch {}
  try { lane.audio?.remove(); } catch {}
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
  const t = performance.now();

  if (rms > threshold) {
    state.silenceSince = 0;
    if (!state.aboveSince) state.aboveSince = t;
    if (!state.speaking && t - state.aboveSince > 100) {
      if (state.turn?.speechStoppedAt) finalizeTurn();
      state.speaking = true;
      const turn = ensureTurn();
      turn.speechStoppedAt = 0;
      setStatus("正在听", "busy");
      setLive("讲话中：Translation 通道正在连续翻译…");
    }
  } else {
    state.aboveSince = 0;
    if (state.speaking) {
      if (!state.silenceSince) state.silenceSince = t;
      if (t - state.silenceSince > 700) {
        state.speaking = false;
        state.silenceSince = 0;
        const turn = ensureTurn();
        turn.speechStoppedAt = Date.now();
        setLive("检测到停顿，等待最后几个流式译文片段…");
        scheduleFinalize(800);
      }
    }
  }

  state.raf = requestAnimationFrame(vadLoop);
}

async function start() {
  if (state.active || state.connecting) return;
  state.connecting = true;
  el.talkLabel.textContent = "正在连接…";
  setStatus("连接中", "busy");
  setLive("正在建立 FR / ZH 两条固定 Translation 通道…");

  state.diag.fr = { dc: "connecting", pc: "new", input: 0, output: 0, error: "" };
  state.diag.zh = { dc: "connecting", pc: "new", input: 0, output: 0, error: "" };
  updateDebug();

  try {
    state.stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true,
      },
    });

    const sourceTrack = state.stream.getAudioTracks()[0];
    if (!sourceTrack) throw new Error("没有取得麦克风音轨");

    state.audioCtx = new (window.AudioContext || window.webkitAudioContext)();
    await state.audioCtx.resume();
    state.analyser = state.audioCtx.createAnalyser();
    state.analyser.fftSize = 1024;
    state.sourceNode = state.audioCtx.createMediaStreamSource(state.stream);
    state.sourceNode.connect(state.analyser);

    const [frLane, zhLane] = await Promise.all([
      createLane("fr", true, sourceTrack),
      createLane("zh", false, sourceTrack),
    ]);

    state.lanes.fr = frLane;
    state.lanes.zh = zhLane;
    state.active = true;

    el.talk.classList.add("active");
    el.talkLabel.textContent = "结束同传";
    setStatus("同传中", "online");
    setLive("FR / 中文通道都已连接，直接讲话即可");
    applyAudioRouting();
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

  closeLane(state.lanes.fr);
  closeLane(state.lanes.zh);
  state.lanes.fr = null;
  state.lanes.zh = null;

  try { state.stream?.getTracks().forEach((t) => t.stop()); } catch {}
  try { state.sourceNode?.disconnect(); } catch {}
  try { await state.audioCtx?.close(); } catch {}

  state.stream = null;
  state.audioCtx = null;
  state.analyser = null;
  state.sourceNode = null;
  state.speaking = false;
  state.aboveSince = 0;
  state.silenceSince = 0;

  el.talk.classList.remove("active");
  el.talkLabel.textContent = "开始同传";
  el.meter.style.width = "0";
  updateLiveTurn();
  setStatus("未连接");
  if (update) setLive("同传已结束");
  updateDebug();
}

el.talk.onclick = () => (state.active || state.connecting ? stop() : start());

$("#copyBtn").onclick = async () => {
  if (!state.messages.length) return;
  const text = state.messages.map((m) =>
    `[${m.time}] ${m.sourceLang === "zh" ? "中文→法语" : "法语→中文"}\n原文：${m.original}\n译文：${m.translation}`
  ).join("\n\n");
  await navigator.clipboard.writeText(text);
  setLive("对话已复制");
};

$("#clearBtn").onclick = () => {
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
    const data = await r.json();
    if (!r.ok) throw new Error(data.error || "请求失败");
    el.agentAnswer.textContent = data.text;
  } catch (err) {
    el.agentAnswer.textContent = `出错：${err.message}`;
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
    const data = await r.json();
    if (!r.ok) throw new Error(data.error || "总结失败");
    el.summaryText.textContent = data.text;
  } catch (err) {
    el.summaryText.textContent = `总结失败：${err.message}`;
  }
};

$("#copySummary").onclick = async () => {
  if (!el.summaryText.textContent) return;
  await navigator.clipboard.writeText(el.summaryText.textContent);
  setLive("总结已复制");
};

window.addEventListener("beforeunload", () => {
  if (state.active) stop(false);
});

render();
updateDebug();