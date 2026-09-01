const $=s=>document.querySelector(s);

const state={
  active:false,connecting:false,stream:null,
  audioCtx:null,analyser:null,sourceNode:null,raf:0,
  noiseFloor:.008,speaking:false,aboveSince:0,silenceSince:0,
  lanes:{fr:null,zh:null},
  turn:null,finalizeTimer:0,
  messages:JSON.parse(localStorage.getItem("zhfr.v9.messages")||"[]")
};

const el={
  status:$("#status"),statusText:$("#statusText"),topic:$("#topic"),voice:$("#voiceToggle"),
  talk:$("#talkButton"),talkLabel:$("#talkLabel"),meter:$("#meter"),live:$("#liveText"),
  messages:$("#messages"),empty:$("#empty"),processing:$("#processing"),
  liveSource:$("#liveSource"),liveTranslation:$("#liveTranslation"),
  summaryCard:$("#summaryCard"),summaryText:$("#summaryText"),
  agentDialog:$("#agentDialog"),agentInput:$("#agentInput"),agentAnswer:$("#agentAnswer")
};

el.topic.value=localStorage.getItem("zhfr.v9.topic")||"";
el.voice.checked=localStorage.getItem("zhfr.v9.voice")==="1";
el.topic.oninput=()=>localStorage.setItem("zhfr.v9.topic",el.topic.value);
el.voice.onchange=()=>{
  localStorage.setItem("zhfr.v9.voice",el.voice.checked?"1":"0");
  applyAudioRouting();
};

function setStatus(t,m=""){
  el.statusText.textContent=t;
  el.status.classList.remove("online","busy");
  if(m)el.status.classList.add(m);
}
function setLive(t){el.live.textContent=t}
function esc(s){return String(s??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]))}
function now(){return new Date().toLocaleTimeString([],{hour:"2-digit",minute:"2-digit"})}
function save(){localStorage.setItem("zhfr.v9.messages",JSON.stringify(state.messages))}
function render(){
  el.messages.innerHTML="";
  if(!state.messages.length){
    el.messages.appendChild(el.empty);el.empty.hidden=false;
  }else{
    for(const m of state.messages){
      const d=document.createElement("div");
      d.className=`msg ${m.sourceLang}`;
      const dir=m.sourceLang==="zh"?"🇨🇳 中文 → 🇫🇷 Français":"🇫🇷 Français → 🇨🇳 中文";
      d.innerHTML=`<div class="msgtop"><span class="dir">${dir}</span><span class="time">${esc(m.time)}</span></div>
        <div class="original">${esc(m.original)}</div><div class="translation">${esc(m.translation)}</div>`;
      el.messages.appendChild(d);
    }
  }
  el.messages.scrollTop=el.messages.scrollHeight;
}
function cleanDelta(s){
  return String(s||"").replace(/\uFFFD/g,"");
}
function detectLang(text){
  const t=String(text||"");
  const han=(t.match(/[\u3400-\u9fff]/g)||[]).length;
  const latin=(t.match(/[A-Za-zÀ-ÿŒœÇç]/g)||[]).length;
  if(han>=1)return "zh";
  if(latin>=3)return "fr";
  return null;
}
function newTurn(){
  return {
    source:"",outFr:"",outZh:"",lang:null,
    startedAt:Date.now(),lastSourceAt:0,lastOutAt:0,
    speechStoppedAt:0
  };
}
function ensureTurn(){
  if(!state.turn)state.turn=newTurn();
  return state.turn;
}
function chosenOutput(turn=state.turn){
  if(!turn?.lang)return "";
  return turn.lang==="zh"?turn.outFr:turn.outZh;
}
function applyAudioRouting(){
  const lang=state.turn?.lang;
  for(const key of ["fr","zh"]){
    const lane=state.lanes[key];
    if(!lane?.audio)continue;
    const chosen=lang==="zh"?"fr":lang==="fr"?"zh":null;
    lane.audio.muted=!el.voice.checked || chosen!==key;
  }
}
function updateLiveTurn(){
  const t=state.turn;
  if(!t){
    el.processing.hidden=true;
    el.liveSource.textContent="";
    el.liveTranslation.textContent="";
    return;
  }
  el.processing.hidden=false;
  el.liveSource.textContent=t.source||"…";
  el.liveTranslation.textContent=chosenOutput(t)||"…";
  if(t.lang){
    setStatus(t.lang==="zh"?"中文 → Français":"Français → 中文","online");
  }else{
    setStatus("识别语言中","busy");
  }
}
function scheduleFinalize(delay=900){
  clearTimeout(state.finalizeTimer);
  state.finalizeTimer=setTimeout(()=>{
    const t=state.turn;
    if(!t)return;
    const n=Date.now();
    const sourceIdle=t.lastSourceAt? n-t.lastSourceAt : 99999;
    const outIdle=t.lastOutAt? n-t.lastOutAt : 99999;
    const stoppedIdle=t.speechStoppedAt? n-t.speechStoppedAt : 0;
    if(t.speechStoppedAt && sourceIdle>650 && outIdle>500 && stoppedIdle>650){
      finalizeTurn();
    }else if(t.speechStoppedAt && stoppedIdle>4000){
      finalizeTurn();
    }else{
      scheduleFinalize(450);
    }
  },delay);
}
function finalizeTurn(){
  clearTimeout(state.finalizeTimer);
  const t=state.turn;
  if(!t)return;
  const original=t.source.trim();
  const translation=chosenOutput(t).trim();
  if(original && t.lang && translation){
    state.messages.push({sourceLang:t.lang,original,translation,time:now()});
    save();render();
  }
  state.turn=null;
  updateLiveTurn();
  applyAudioRouting();
  setStatus(state.active?"同传中":"未连接",state.active?"online":"");
  if(state.active)setLive("继续讲话即可");
}
function handleSourceDelta(event){
  const delta=cleanDelta(event.delta);
  if(!delta)return;
  const t=ensureTurn();
  t.source+=delta;
  t.lastSourceAt=Date.now();
  if(!t.lang){
    t.lang=detectLang(t.source);
    if(t.lang){
      applyAudioRouting();
      setLive(t.lang==="zh"?"正在实时翻译成法语…":"正在实时翻译成中文…");
    }
  }
  updateLiveTurn();
  if(t.speechStoppedAt)scheduleFinalize(700);
}
function handleOutputDelta(target,event){
  const delta=cleanDelta(event.delta);
  if(!delta)return;
  const t=ensureTurn();
  if(target==="fr")t.outFr+=delta;
  else t.outZh+=delta;
  t.lastOutAt=Date.now();
  if(t.lang){
    const chosen=t.lang==="zh"?"fr":"zh";
    if(target===chosen){
      updateLiveTurn();
      if(t.speechStoppedAt)scheduleFinalize(650);
    }
  }
}
function handleLaneEvent(target,raw){
  let e;
  try{e=JSON.parse(raw)}catch{return}
  if(e.type==="session.input_transcript.delta" && target==="fr"){
    handleSourceDelta(e);
  }else if(e.type==="session.output_transcript.delta"){
    handleOutputDelta(target,e);
  }else if(e.type==="error"){
    console.error("translation lane error",target,e);
    setLive(`${target.toUpperCase()} 通道错误：${e.error?.message||"Realtime error"}`);
  }
}
async function createLane(target,transcribe){
  const r=await fetch("/api/session",{
    method:"POST",
    headers:{"Content-Type":"application/json"},
    body:JSON.stringify({target,transcribe})
  });
  const data=await r.json();
  if(!r.ok)throw new Error(data.error?.message||data.error||`创建 ${target} 通道失败`);
  const secret=data.client_secret||data.value;
  if(!secret)throw new Error(`${target} 通道没有返回临时密钥`);

  const pc=new RTCPeerConnection();
  const dc=pc.createDataChannel("oai-events");
  const audio=document.createElement("audio");
  audio.autoplay=true;audio.playsInline=true;audio.muted=true;
  audio.style.display="none";document.body.appendChild(audio);

  pc.ontrack=({streams})=>{
    audio.srcObject=streams[0];
    audio.play().catch(()=>{});
  };
  dc.onmessage=({data})=>handleLaneEvent(target,data);

  for(const track of state.stream.getAudioTracks()){
    pc.addTrack(track,state.stream);
  }

  const offer=await pc.createOffer();
  await pc.setLocalDescription(offer);
  const sdp=await fetch("https://api.openai.com/v1/realtime/translations/calls",{
    method:"POST",
    headers:{
      Authorization:`Bearer ${secret}`,
      "Content-Type":"application/sdp"
    },
    body:offer.sdp
  });
  if(!sdp.ok)throw new Error(await sdp.text());
  await pc.setRemoteDescription({type:"answer",sdp:await sdp.text()});

  return {target,pc,dc,audio};
}
function closeLane(lane){
  if(!lane)return;
  try{lane.dc?.send(JSON.stringify({type:"session.close"}))}catch{}
  try{lane.dc?.close()}catch{}
  try{lane.pc?.close()}catch{}
  try{lane.audio?.pause()}catch{}
  try{lane.audio?.remove()}catch{}
}
function vadLoop(){
  if(!state.active||!state.analyser)return;
  const arr=new Float32Array(state.analyser.fftSize);
  state.analyser.getFloatTimeDomainData(arr);
  let sum=0;for(const x of arr)sum+=x*x;
  const rms=Math.sqrt(sum/arr.length);
  el.meter.style.width=`${Math.min(100,rms*900)}%`;

  if(!state.speaking&&rms<.04){
    state.noiseFloor=.985*state.noiseFloor+.015*rms;
  }
  const threshold=Math.max(.012,state.noiseFloor*2.8);
  const t=performance.now();

  if(rms>threshold){
    state.silenceSince=0;
    if(!state.aboveSince)state.aboveSince=t;
    if(!state.speaking&&t-state.aboveSince>100){
      if(state.turn?.speechStoppedAt)finalizeTurn();
      state.speaking=true;
      const turn=ensureTurn();
      turn.speechStoppedAt=0;
      setStatus("正在听","busy");
      setLive("讲话中，译文会边说边出现…");
    }
  }else{
    state.aboveSince=0;
    if(state.speaking){
      if(!state.silenceSince)state.silenceSince=t;
      if(t-state.silenceSince>620){
        state.speaking=false;state.silenceSince=0;
        const turn=ensureTurn();
        turn.speechStoppedAt=Date.now();
        setLive("检测到停顿，等待最后几个译文片段…");
        scheduleFinalize(650);
      }
    }
  }
  state.raf=requestAnimationFrame(vadLoop);
}
async function start(){
  if(state.active||state.connecting)return;
  state.connecting=true;
  el.talkLabel.textContent="正在连接…";
  setStatus("连接中","busy");
  setLive("正在建立中法双实时翻译通道…");
  try{
    state.stream=await navigator.mediaDevices.getUserMedia({
      audio:{echoCancellation:true,noiseSuppression:true,autoGainControl:true}
    });
    state.audioCtx=new (window.AudioContext||window.webkitAudioContext)();
    await state.audioCtx.resume();
    state.analyser=state.audioCtx.createAnalyser();
    state.analyser.fftSize=1024;
    state.sourceNode=state.audioCtx.createMediaStreamSource(state.stream);
    state.sourceNode.connect(state.analyser);

    const [frLane,zhLane]=await Promise.all([
      createLane("fr",true),
      createLane("zh",false)
    ]);
    state.lanes.fr=frLane;state.lanes.zh=zhLane;
    state.active=true;
    el.talk.classList.add("active");
    el.talkLabel.textContent="结束同传";
    setStatus("同传中","online");
    setLive("已连接：讲话过程中会直接出现译文");
    vadLoop();
  }catch(err){
    console.error(err);
    await stop(false);
    setStatus("启动失败");
    setLive(err.message);
    alert(`无法启动实时同传：${err.message}`);
  }finally{
    state.connecting=false;
    if(!state.active)el.talkLabel.textContent="开始同传";
  }
}
async function stop(update=true){
  state.active=false;state.connecting=false;
  cancelAnimationFrame(state.raf);
  clearTimeout(state.finalizeTimer);
  if(state.turn)finalizeTurn();
  closeLane(state.lanes.fr);closeLane(state.lanes.zh);
  state.lanes.fr=null;state.lanes.zh=null;
  try{state.stream?.getTracks().forEach(t=>t.stop())}catch{}
  try{state.sourceNode?.disconnect()}catch{}
  try{await state.audioCtx?.close()}catch{}
  state.stream=null;state.audioCtx=null;state.analyser=null;state.sourceNode=null;
  state.speaking=false;state.aboveSince=0;state.silenceSince=0;
  el.talk.classList.remove("active");
  el.talkLabel.textContent="开始同传";
  el.meter.style.width="0";
  updateLiveTurn();
  setStatus("未连接");
  if(update)setLive("同传已结束");
}
el.talk.onclick=()=>state.active||state.connecting?stop():start();

$("#copyBtn").onclick=async()=>{
  if(!state.messages.length)return;
  const text=state.messages.map(m=>`[${m.time}] ${m.sourceLang==="zh"?"中文→法语":"法语→中文"}\n原文：${m.original}\n译文：${m.translation}`).join("\n\n");
  await navigator.clipboard.writeText(text);setLive("对话已复制");
};
$("#clearBtn").onclick=async()=>{
  if(!confirm("确定清空本次全部记录吗？"))return;
  state.messages=[];save();render();
  el.summaryCard.hidden=true;el.summaryText.textContent="";
  setLive("记录已清空");
};
$("#agentBtn").onclick=()=>{
  el.agentAnswer.hidden=true;el.agentAnswer.textContent="";
  el.agentDialog.showModal();setTimeout(()=>el.agentInput.focus(),50);
};
$("#agentClose").onclick=()=>el.agentDialog.close();
$("#agentSend").onclick=async()=>{
  const q=el.agentInput.value.trim();if(!q)return;
  el.agentAnswer.hidden=false;el.agentAnswer.textContent="AI 正在处理…";
  try{
    const r=await fetch("/api/assistant",{
      method:"POST",headers:{"Content-Type":"application/json"},
      body:JSON.stringify({mode:"agent",question:q,topic:el.topic.value.trim(),transcript:state.messages})
    });
    const d=await r.json();if(!r.ok)throw new Error(d.error||"请求失败");
    el.agentAnswer.textContent=d.text;
  }catch(e){el.agentAnswer.textContent=`出错：${e.message}`}
};
$("#summaryBtn").onclick=async()=>{
  if(state.turn)finalizeTurn();
  if(!state.messages.length)return alert("目前还没有可总结的对话。");
  el.summaryCard.hidden=false;el.summaryText.textContent="正在整理本次谈话…";
  el.summaryCard.scrollIntoView({behavior:"smooth"});
  try{
    const r=await fetch("/api/assistant",{
      method:"POST",headers:{"Content-Type":"application/json"},
      body:JSON.stringify({mode:"summary",topic:el.topic.value.trim(),transcript:state.messages})
    });
    const d=await r.json();if(!r.ok)throw new Error(d.error||"总结失败");
    el.summaryText.textContent=d.text;
  }catch(e){el.summaryText.textContent=`总结失败：${e.message}`}
};
$("#copySummary").onclick=async()=>{
  if(el.summaryText.textContent){
    await navigator.clipboard.writeText(el.summaryText.textContent);
    setLive("总结已复制");
  }
};
window.addEventListener("beforeunload",()=>{if(state.active)stop(false)});
render();