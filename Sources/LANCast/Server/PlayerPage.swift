import Foundation

/// The browser player page, served at `GET /`. Embedded as a string so it is
/// always available regardless of how the binary is bundled.
enum PlayerPage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, interactive-widget=resizes-content">
<title>LANCast</title>
<style>
  :root { color-scheme: dark; }
  html, body { margin: 0; height: 100%; background: #000; }
  body {
    display: flex; align-items: center; justify-content: center;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
    color: #e6e6e6; overflow: hidden;
  }
  video { max-width: 100%; max-height: 100%; width: auto; height: auto; background: #000; }
  #overlay {
    position: fixed; inset: 0; display: flex; flex-direction: column;
    align-items: center; justify-content: center; gap: 14px; z-index: 8;
    background: rgba(0,0,0,0.55); text-align: center; padding: 24px;
    transition: opacity .25s ease; cursor: pointer;
  }
  #overlay.hidden { opacity: 0; pointer-events: none; }
  #title { font-size: 22px; font-weight: 600; letter-spacing: .3px; }
  #status { font-size: 14px; opacity: .8; max-width: 80vw; white-space: pre-wrap; }
  #hint { font-size: 13px; opacity: .6; }
  .pill {
    position: fixed; top: 12px; right: 12px; z-index: 5;
    background: rgba(20,20,22,0.7); border: 1px solid rgba(255,255,255,.12);
    border-radius: 999px; padding: 6px 12px; font-size: 12px; opacity: .85;
    backdrop-filter: blur(8px);
  }
  #shortcuts {
    position: fixed; left: 50%; bottom: 16px;
    transform: translateX(-50%) translateY(8px); z-index: 6;
    display: flex; flex-direction: column; align-items: center; gap: 8px;
    padding: 8px; max-width: 96vw;
    opacity: 0; transition: opacity .25s ease, transform .25s ease;
    pointer-events: none;
  }
  #shortcuts.show { opacity: 1; transform: translateX(-50%) translateY(0); pointer-events: auto; }
  #shortcuts .row { display: flex; flex-wrap: nowrap; gap: 8px; justify-content: center; }
  .chip span, .readout { white-space: nowrap; }
  .chip {
    display: inline-flex; align-items: center; gap: 8px;
    height: 38px; box-sizing: border-box;
    background: rgba(20,20,22,0.72); color: #eee;
    border: 1px solid rgba(255,255,255,0.14); border-radius: 999px;
    padding: 0 14px 0 8px; font-size: 13px; line-height: 1; cursor: pointer;
    backdrop-filter: blur(8px);
    transition: background .15s ease, border-color .15s ease, transform .05s ease;
  }
  .chip:hover { background: rgba(52,52,58,0.9); border-color: rgba(255,255,255,0.3); }
  .chip:active { transform: scale(0.95); }
  .chip kbd {
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px;
    min-width: 22px; height: 22px; padding: 0 5px; box-sizing: border-box;
    display: inline-flex; align-items: center; justify-content: center;
    background: rgba(255,255,255,0.16); border-radius: 6px;
    border: 1px solid rgba(255,255,255,0.18); color: #fff;
  }
  .readout {
    display: inline-flex; align-items: center; justify-content: center;
    height: 38px; box-sizing: border-box;
    padding: 0 12px; font-size: 13px; line-height: 1; min-width: 48px; color: #ddd;
    background: rgba(20,20,22,0.55); border-radius: 999px;
    border: 1px solid rgba(255,255,255,0.10); backdrop-filter: blur(8px);
  }
  /* Keep each row on one line by shrinking the chips on narrow screens. */
  @media (max-width: 430px) {
    #shortcuts { gap: 6px; padding: 6px; }
    .chip { height: 34px; gap: 6px; padding: 0 10px 0 6px; font-size: 12px; }
    .chip kbd { min-width: 20px; height: 20px; }
    .readout { height: 34px; padding: 0 8px; min-width: 42px; font-size: 12px; }
  }
  @media (max-width: 340px) {
    .chip span { display: none; }
  }
  .chip.hidden { display: none; }
  .chip.active { background: #2e7d32; border-color: #43a047; }
  #ctrlBanner {
    position: fixed; top: 12px; left: 50%; transform: translateX(-50%);
    z-index: 7; max-width: 92vw; text-align: center;
    background: rgba(20,20,22,0.82); border: 1px solid rgba(255,255,255,0.16);
    border-radius: 999px; padding: 8px 16px; font-size: 13px; color: #fff;
    backdrop-filter: blur(8px); opacity: 0; pointer-events: none;
    transition: opacity .2s ease;
  }
  #ctrlBanner.show { opacity: 1; }
  body.controlling { cursor: crosshair; }

  /* Floating control-mode toolbar (Stop + keyboard toggles). */
  #ctrlTools {
    position: fixed; top: 12px; right: 12px; z-index: 9;
    display: none; gap: 8px;
  }
  #ctrlTools.show { display: flex; }
  .toolbtn {
    display: inline-flex; align-items: center; gap: 7px; height: 38px;
    box-sizing: border-box; padding: 0 14px; font-size: 13px; line-height: 1;
    color: #fff; background: rgba(20,20,22,0.82); cursor: pointer;
    border: 1px solid rgba(255,255,255,0.16); border-radius: 999px;
    backdrop-filter: blur(8px);
    transition: background .15s ease, border-color .15s ease, transform .05s ease;
  }
  .toolbtn:hover { background: rgba(52,52,58,0.92); border-color: rgba(255,255,255,0.32); }
  .toolbtn:active { transform: scale(0.96); }
  .toolbtn.active { background: #1565c0; border-color: #1e88e5; }
  .toolbtn.stop { background: #b3261e; border-color: #d8453b; }
  .toolbtn.stop:hover { background: #c5352c; }

  /* Hidden input used to summon the native soft keyboard on touch devices. */
  #kbCatcher {
    position: fixed; bottom: 0; left: 0; width: 1px; height: 1px;
    opacity: 0; border: 0; padding: 0; margin: 0; z-index: -1;
    background: transparent; color: transparent; caret-color: transparent;
  }

  /* In-browser on-screen keyboard. */
  #osk {
    position: fixed; left: 0; right: 0; bottom: 0; z-index: 9;
    display: none; flex-direction: column; gap: 6px; padding: 8px;
    background: rgba(12,12,14,0.94); border-top: 1px solid rgba(255,255,255,0.12);
    backdrop-filter: blur(10px); user-select: none; -webkit-user-select: none;
  }
  #osk.show { display: flex; }
  #osk .oskrow { display: flex; gap: 6px; justify-content: center; }
  .oskkey {
    flex: 1 1 0; min-width: 0; height: 42px; max-width: 64px;
    display: inline-flex; align-items: center; justify-content: center;
    font-size: 14px; color: #eee; cursor: pointer;
    background: rgba(60,60,66,0.9); border: 1px solid rgba(255,255,255,0.12);
    border-radius: 8px; box-sizing: border-box; padding: 0 4px;
    transition: background .1s ease, transform .05s ease;
  }
  .oskkey:hover { background: rgba(82,82,90,0.95); }
  .oskkey:active { transform: scale(0.94); }
  .oskkey.wide { flex-grow: 1.6; max-width: 110px; }
  .oskkey.space { flex-grow: 6; max-width: none; }
  .oskkey.mod.active { background: #1565c0; border-color: #1e88e5; color: #fff; }
  .oskkey.fn { height: 34px; font-size: 12px; }
  @media (max-width: 560px) {
    .oskkey { height: 38px; font-size: 13px; max-width: none; }
    .oskkey.fn { height: 30px; font-size: 11px; }
  }

  /* Bottom-corner click buttons (mainly for touch, where there is no pointer).
     They ride above the on-screen keyboard via --kb-inset (set from JS). */
  .clickbtn {
    position: fixed; bottom: calc(18px + var(--kb-inset, 0px)); z-index: 10; display: none;
    min-width: 96px; height: 44px; padding: 0 16px; border-radius: 10px;
    align-items: center; justify-content: center; text-align: center;
    font-size: 13px; font-weight: 600; line-height: 1.15; color: #fff;
    background: rgba(20,20,22,0.82); border: 1px solid rgba(255,255,255,0.18);
    backdrop-filter: blur(8px); cursor: pointer;
    transition: bottom 0.15s ease;
  }
  .clickbtn:active { transform: scale(0.94); }
  #leftClickBtn { left: 16px; }
  #rightClickBtn { right: 16px; }
  body.controlling .clickbtn { display: inline-flex; }

  /* Device nickname field in the connect overlay. */
  #nameRow { display: flex; align-items: center; gap: 8px; margin-top: 4px; }
  #nickInput {
    height: 34px; box-sizing: border-box; width: 220px; max-width: 80vw;
    border-radius: 8px; border: 1px solid rgba(255,255,255,0.18);
    background: rgba(255,255,255,0.08); color: #fff; padding: 0 12px; font-size: 14px;
    text-align: center;
  }
  #nickInput::placeholder { color: rgba(255,255,255,0.45); }

  /* Password prompt modal (shown when a token is required but missing/wrong). */
  #pwModal {
    position: fixed; inset: 0; z-index: 20; display: none;
    align-items: center; justify-content: center;
    background: rgba(0,0,0,0.72); padding: 24px;
  }
  #pwModal.show { display: flex; }
  #pwModal .card {
    background: #1b1b1f; border: 1px solid rgba(255,255,255,0.14);
    border-radius: 14px; padding: 22px; width: min(92vw, 340px);
    display: flex; flex-direction: column; gap: 12px; text-align: center;
  }
  #pwModal h2 { margin: 0; font-size: 17px; font-weight: 600; }
  #pwModal p { margin: 0; font-size: 13px; opacity: .7; }
  #pwInput {
    height: 42px; box-sizing: border-box; border-radius: 8px;
    border: 1px solid rgba(255,255,255,0.18); background: rgba(255,255,255,0.08);
    color: #fff; padding: 0 12px; font-size: 16px; text-align: center;
  }
  #pwSubmit {
    height: 42px; border-radius: 8px; border: 0; cursor: pointer;
    background: #1565c0; color: #fff; font-size: 15px; font-weight: 600;
  }
  #pwSubmit:active { transform: scale(0.98); }
  #pwError { color: #ff6b6b; font-size: 12px; min-height: 14px; }
</style>
</head>
<body>
  <video id="v" autoplay playsinline muted></video>
  <div class="pill" id="pill">connecting...</div>
  <div id="overlay">
    <div id="title">LANCast</div>
    <div id="status">Connecting to stream...</div>
    <div id="hint">Tap / click anywhere to start and unmute audio</div>
    <div id="nameRow">
      <input id="nickInput" placeholder="Nickname (1 word)" maxlength="20"
             autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false">
    </div>
  </div>
  <div id="pwModal">
    <div class="card">
      <h2>Password required</h2>
      <p>This stream is password-protected.</p>
      <input id="pwInput" type="password" placeholder="Enter password"
             autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false">
      <div id="pwError"></div>
      <button id="pwSubmit">Connect</button>
    </div>
  </div>
  <div id="shortcuts" aria-label="Playback shortcuts">
    <div class="row">
      <button class="chip" data-act="mute" title="Mute / Unmute (M)"><kbd>M</kbd><span id="muteLabel">Mute</span></button>
      <button class="chip" data-act="volDown" title="Volume down (-)"><kbd>&minus;</kbd><span>Vol</span></button>
      <span class="readout" id="volLevel">100%</span>
      <button class="chip" data-act="volUp" title="Volume up (+)"><kbd>+</kbd><span>Vol</span></button>
    </div>
    <div class="row">
      <button class="chip" data-act="rotate" title="Rotate video (R)"><kbd>R</kbd><span>Rotate</span></button>
      <button class="chip" data-act="fullscreen" title="Fullscreen (F)"><kbd>F</kbd><span id="fsLabel">Fullscreen</span></button>
      <button class="chip hidden" id="ctrlBtn" data-act="control" title="Control the host (C)"><kbd>C</kbd><span id="ctrlLabel">Control</span></button>
    </div>
  </div>
  <div id="ctrlBanner"></div>
  <div id="ctrlTools">
    <button class="toolbtn" id="sysKbBtn" title="Show device keyboard">Keyboard</button>
    <button class="toolbtn" id="oskBtn" title="On-screen keyboard">On-screen</button>
    <button class="toolbtn stop" id="stopCtrlBtn" title="Exit control (Esc)">Stop</button>
  </div>
  <input id="kbCatcher" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" inputmode="text" aria-hidden="true" tabindex="-1">
  <div id="osk" aria-label="On-screen keyboard"></div>
  <button class="clickbtn" id="leftClickBtn" title="Left click">Left click</button>
  <button class="clickbtn" id="rightClickBtn" title="Right click">Right click</button>

<script>
(function () {
  const v = document.getElementById('v');
  const overlay = document.getElementById('overlay');
  const statusEl = document.getElementById('status');
  const pill = document.getElementById('pill');

  const MAX_LATENCY = 1.5;
  const KEEP_SECONDS = 8;

  let socket = null, ms = null, sb = null, mime = null;
  let queue = [];
  let firstAppendDone = false;
  let segCount = 0;

  function setStatus(t) { statusEl.textContent = t; }
  function setPill(t) { pill.textContent = t; }

  // Send a diagnostic line back to the server so it appears in LANCast.log.
  function dbg(msg) {
    try { if (socket && socket.readyState === 1) socket.send(JSON.stringify({ type: 'log', msg: String(msg) })); } catch (e) {}
  }
  function sendCtl(obj) {
    try { if (socket && socket.readyState === 1) socket.send(JSON.stringify(obj)); } catch (e) {}
  }
  function sendInput(obj) { obj.type = 'input'; sendCtl(obj); }

  // Stable per-browser identity so the host can remember control approvals.
  const clientId = (function () {
    try {
      let id = localStorage.getItem('lancastClientId');
      if (!id) {
        id = (window.crypto && crypto.randomUUID) ? crypto.randomUUID()
           : (String(Date.now()) + '-' + Math.random().toString(16).slice(2));
        localStorage.setItem('lancastClientId', id);
      }
      return id;
    } catch (e) { return String(Date.now()); }
  })();

  // Auth token: seeded from the URL, then updated if the viewer types a
  // password into the modal. Reused on reconnects so the prompt isn't repeated.
  let authToken = (new URLSearchParams(location.search).get('token')) || '';
  function wsURL() {
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    let u = `${proto}://${location.host}/ws`;
    if (authToken) u += `?token=${encodeURIComponent(authToken)}`;
    return u;
  }

  // ---- Device identity (name shown to the host on control requests) ----
  // Browsers cannot read the OS username or device serial, so we combine an
  // optional 1-word nickname with an auto-detected model/OS/browser label.
  let nickname = '';
  try { nickname = (localStorage.getItem('lancastNick') || '').trim().split(/\s+/)[0] || ''; } catch (e) {}
  let deviceAuto = (navigator.platform || 'browser');

  // A small map of common Android model codes to marketing names. It can't be
  // exhaustive; unknown codes fall back to the raw model code.
  const MODEL_MAP = {
    'SM-S918B': 'Galaxy S23 Ultra', 'SM-S918U': 'Galaxy S23 Ultra', 'SM-S918U1': 'Galaxy S23 Ultra',
    'SM-S911B': 'Galaxy S23', 'SM-S916B': 'Galaxy S23+',
    'SM-S928B': 'Galaxy S24 Ultra', 'SM-S921B': 'Galaxy S24', 'SM-S926B': 'Galaxy S24+',
    'SM-S908B': 'Galaxy S22 Ultra', 'SM-S901B': 'Galaxy S22',
    'SM-F946B': 'Galaxy Z Fold5', 'SM-F731B': 'Galaxy Z Flip5',
    'Pixel 6': 'Pixel 6', 'Pixel 7': 'Pixel 7', 'Pixel 7 Pro': 'Pixel 7 Pro',
    'Pixel 8': 'Pixel 8', 'Pixel 8 Pro': 'Pixel 8 Pro', 'Pixel 9': 'Pixel 9', 'Pixel 9 Pro': 'Pixel 9 Pro'
  };

  function detectBrowser(ua) {
    if (/edg\//i.test(ua)) return 'Edge';
    if (/opr\/|opera/i.test(ua)) return 'Opera';
    if (/(chrome|crios)/i.test(ua)) return 'Chrome';
    if (/(firefox|fxios)/i.test(ua)) return 'Firefox';
    if (/safari/i.test(ua)) return 'Safari';
    return 'Browser';
  }

  async function detectDevice() {
    const ua = navigator.userAgent || '';
    let model = '', platform = '';
    try {
      const uad = navigator.userAgentData;
      if (uad) {
        platform = uad.platform || '';
        if (uad.getHighEntropyValues) {
          const h = await uad.getHighEntropyValues(['model', 'platform']);
          model = (h.model || '').trim();
          platform = h.platform || platform;
        }
      }
    } catch (e) {}
    if (!model && /android/i.test(ua)) {
      const m = ua.match(/;\s*([^;)]+?)\s+Build\//) || ua.match(/Android[^;]*;\s*([^;)]+)\)/);
      if (m) model = m[1].trim();
    }
    if (!platform) {
      if (/android/i.test(ua)) platform = 'Android';
      else if (/iphone|ipad|ipod/i.test(ua)) platform = 'iOS';
      else if (/mac/i.test(ua)) platform = 'macOS';
      else if (/windows/i.test(ua)) platform = 'Windows';
      else if (/linux/i.test(ua)) platform = 'Linux';
    }
    const friendly = MODEL_MAP[model] || model;
    if (friendly) deviceAuto = friendly + (platform ? ' \u00b7 ' + platform : '');
    else deviceAuto = detectBrowser(ua) + (platform ? ' on ' + platform : '');
  }

  function currentName() { return nickname ? (nickname + ' ' + deviceAuto) : deviceAuto; }
  function sendHello() {
    if (socket && socket.readyState === 1) {
      sendCtl({ type: 'hello', clientId: clientId, name: currentName() });
    }
  }
  // Resolve the auto label, then refresh the host's record.
  detectDevice().then(sendHello).catch(() => {});

  // ---- Nickname field (connect overlay) ----
  const nickInput = document.getElementById('nickInput');
  nickInput.value = nickname;
  function applyNickname() {
    nickname = (nickInput.value || '').trim().split(/\s+/)[0] || '';
    nickInput.value = nickname;
    try { localStorage.setItem('lancastNick', nickname); } catch (e) {}
    sendHello();
  }
  ['click', 'mousedown', 'touchstart'].forEach((ev) =>
    nickInput.addEventListener(ev, (e) => e.stopPropagation(), { passive: true }));
  nickInput.addEventListener('change', applyNickname);
  nickInput.addEventListener('blur', applyNickname);

  // ---- Password modal ----
  const pwModal = document.getElementById('pwModal');
  const pwInput = document.getElementById('pwInput');
  const pwError = document.getElementById('pwError');
  const pwSubmit = document.getElementById('pwSubmit');

  function showPw(err) {
    pwError.textContent = err || '';
    pwModal.classList.add('show');
    setTimeout(() => pwInput.focus(), 50);
  }
  function hidePw() { pwModal.classList.remove('show'); }
  function submitPw() {
    const val = pwInput.value;
    if (!val) { pwError.textContent = 'Enter a password.'; return; }
    authToken = val;
    pwError.textContent = '';
    if (socket && socket.readyState === 1) sendCtl({ type: 'auth', token: val });
    else connect();
  }
  pwModal.addEventListener('mousedown', (e) => e.stopPropagation());
  pwModal.addEventListener('click', (e) => e.stopPropagation());
  pwSubmit.addEventListener('click', (e) => { e.stopPropagation(); submitPw(); });
  pwInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); submitPw(); } });

  function handleAuth(msg) {
    if (msg.state === 'ok') { hidePw(); setStatus('Connected. Waiting for video...'); return; }
    if (msg.state === 'bad') { showPw('Wrong password. Try again.'); pwInput.select(); return; }
    if (msg.state === 'required') { setStatus('Password required'); showPw(''); }
  }

  function resetMSE() {
    queue = [];
    firstAppendDone = false;
    segCount = 0;
    sb = null;
    try { if (v.src) URL.revokeObjectURL(v.src); } catch (e) {}

    if (!('MediaSource' in window)) {
      setStatus('This browser has no MediaSource support.');
      dbg('ERROR: no MediaSource in window');
      return;
    }
    let supported = false;
    try { supported = MediaSource.isTypeSupported(mime); } catch (e) {}
    dbg('isTypeSupported(' + mime + ') = ' + supported);
    if (!supported) {
      setStatus('This browser cannot play the stream codec:\n' + mime);
      return;
    }
    ms = new MediaSource();
    v.src = URL.createObjectURL(ms);
    ms.addEventListener('sourceopen', onSourceOpen, { once: true });
    dbg('MediaSource created, waiting for sourceopen');
  }

  function onSourceOpen() {
    dbg('sourceopen fired, readyState=' + ms.readyState);
    if (!mime || sb) return;
    try {
      sb = ms.addSourceBuffer(mime);
    } catch (e) {
      setStatus('addSourceBuffer failed:\n' + (e && e.message ? e.message : e));
      dbg('ERROR addSourceBuffer: ' + e);
      return;
    }
    // Default 'segments' mode: our fMP4 segments have continuous real timestamps
    // from the encoder, so they line up on their own. (sequence mode stalls with
    // muxed audio+video here.)
    sb.addEventListener('updateend', () => { trim(); pump(); seekLive(); });
    sb.addEventListener('error', () => { dbg('ERROR sourceBuffer error event'); setStatus('Media buffer error.'); });
    dbg('sourceBuffer ready (mode=' + sb.mode + ')');
    pump();
  }

  let lastStateLog = 0;
  function logState(tag) {
    const now = Date.now();
    if (now - lastStateLog < 1500) return;
    lastStateLog = now;
    let ranges = [];
    for (let i = 0; i < v.buffered.length; i++) {
      ranges.push(v.buffered.start(i).toFixed(2) + '-' + v.buffered.end(i).toFixed(2));
    }
    dbg(tag + ' t=' + v.currentTime.toFixed(2) + ' paused=' + v.paused +
        ' rs=' + v.readyState + ' buffered=[' + ranges.join(',') + ']');
  }

  function pump() {
    if (!sb || sb.updating || queue.length === 0) return;
    const chunk = queue.shift();
    try {
      sb.appendBuffer(chunk);
      if (!firstAppendDone) { firstAppendDone = true; dbg('first appendBuffer ok (' + chunk.byteLength + ' bytes)'); }
    } catch (e) {
      if (e && e.name === 'QuotaExceededError') {
        queue.unshift(chunk);
        trim(true);
      } else {
        dbg('ERROR appendBuffer: ' + e);
        setStatus('Append error: ' + (e && e.message ? e.message : e));
      }
    }
  }

  function trim(force) {
    if (!sb || sb.updating || v.buffered.length === 0) return;
    const start = v.buffered.start(0);
    const end = v.buffered.end(v.buffered.length - 1);
    const target = force ? Math.max(start, end - 2) : (end - KEEP_SECONDS);
    if (target > start) {
      try { sb.remove(start, target); } catch (e) {}
    }
  }

  function seekLive() {
    if (v.buffered.length === 0) return;
    const start = v.buffered.start(0);
    const end = v.buffered.end(v.buffered.length - 1);
    // If currentTime is outside the buffered region (e.g. late joiner whose
    // timeline starts at a large timestamp), jump into it.
    if (v.currentTime < start - 0.1 || v.currentTime > end + 0.5) {
      v.currentTime = start;
      dbg('seek into buffer start=' + start.toFixed(2));
    } else if (end - v.currentTime > MAX_LATENCY) {
      v.currentTime = end - 0.4;
    }
    if (v.paused && started) v.play().catch((e) => { dbg('play() rejected: ' + e); });
    logState('state');
    setPill((v.muted ? 'muted ' : 'live ') + Math.max(0, (end - v.currentTime)).toFixed(1) + 's');
  }

  function connect() {
    let ws;
    try { ws = new WebSocket(wsURL()); }
    catch (e) { setStatus('Bad URL'); return; }
    socket = ws;
    ws.binaryType = 'arraybuffer';

    ws.onopen = () => {
      setStatus('Connected. Waiting for video...');
      setPill('connected');
      dbg('ws open; player=v17-qr-auth-name; UA=' + navigator.userAgent);
      sendHello();
    };

    ws.onmessage = (ev) => {
      if (typeof ev.data === 'string') {
        let msg;
        try { msg = JSON.parse(ev.data); } catch (e) { return; }
        if (msg.type === 'auth') { handleAuth(msg); return; }
        if (msg.type === 'control') { handleControl(msg); return; }
        if (msg.type === 'init' && msg.mime) {
          mime = msg.mime;
          dbg('received init message, mime=' + mime);
          resetMSE();
        }
        return;
      }
      segCount++;
      if (segCount <= 3) dbg('received binary #' + segCount + ' (' + ev.data.byteLength + ' bytes)');
      queue.push(new Uint8Array(ev.data));
      pump();
    };

    ws.onerror = () => { dbg('ws error event'); };
    ws.onclose = (e) => {
      setStatus('Disconnected. Reconnecting...');
      setPill('reconnecting...');
      enterControl(false);
      setControlState('unknown');
      setTimeout(connect, 1000);
    };
  }

  v.addEventListener('error', () => {
    const c = v.error ? v.error.code : '?';
    const m = v.error ? v.error.message : '';
    dbg('VIDEO element error code=' + c + ' msg=' + m);
    setStatus('Video error (code ' + c + '). ' + m);
  });
  v.addEventListener('playing', () => { dbg('video playing'); setTimeout(() => overlay.classList.add('hidden'), 600); refreshShortcuts(); });
  v.addEventListener('waiting', () => { lastStateLog = 0; logState('waiting'); });
  v.addEventListener('stalled', () => { lastStateLog = 0; logState('stalled'); });
  v.addEventListener('canplay', () => { dbg('video canplay'); });
  v.addEventListener('loadedmetadata', () => { if (rotation) applyRotation(); });

  // ---- Controls + keyboard shortcuts (live stream) ----
  // m = mute/unmute, f = fullscreen, r = rotate video, +/- = volume.
  const shortcuts = document.getElementById('shortcuts');
  const muteLabel = document.getElementById('muteLabel');
  const fsLabel = document.getElementById('fsLabel');
  const volLevel = document.getElementById('volLevel');
  const ctrlBtn = document.getElementById('ctrlBtn');
  const ctrlLabel = document.getElementById('ctrlLabel');
  const ctrlBanner = document.getElementById('ctrlBanner');
  const ctrlTools = document.getElementById('ctrlTools');
  const sysKbBtn = document.getElementById('sysKbBtn');
  const oskBtn = document.getElementById('oskBtn');
  const stopCtrlBtn = document.getElementById('stopCtrlBtn');
  const kbCatcher = document.getElementById('kbCatcher');
  const osk = document.getElementById('osk');

  let started = false;
  let rotation = 0;          // 0 / 90 / 180 / 270 degrees
  let hideTimer = null;

  // Remote-control state: unknown | available | view-only | unavailable |
  // requesting | granted | denied | busy
  let controlState = 'unknown';
  let controlActive = false;
  let lastMoveSent = 0;
  let lastPos = { x: 0.5, y: 0.5 }; // last forwarded cursor position (for click buttons)

  function fsActive() { return !!(document.fullscreenElement || document.webkitFullscreenElement); }

  function updateAudioUI() {
    const level = v.muted ? 0 : v.volume;
    if (muteLabel) muteLabel.textContent = (v.muted || v.volume === 0) ? 'Unmute' : 'Mute';
    if (volLevel) volLevel.textContent = Math.round(level * 100) + '%';
  }
  function updateFsUI() { if (fsLabel) fsLabel.textContent = fsActive() ? 'Exit' : 'Fullscreen'; }

  function doMute() { v.muted = !v.muted; if (!v.muted && v.volume === 0) v.volume = 0.5; updateAudioUI(); }
  function doVolume(delta) {
    const base = v.muted ? 0 : v.volume;
    const nv = Math.min(1, Math.max(0, Math.round((base + delta) * 100) / 100));
    v.volume = nv;
    v.muted = (nv === 0);
    updateAudioUI();
  }
  function toggleFullscreen() {
    if (!fsActive()) {
      const el = document.documentElement;
      if (el.requestFullscreen) el.requestFullscreen().catch(() => {});
      else if (el.webkitRequestFullscreen) el.webkitRequestFullscreen();
      else if (v.webkitEnterFullscreen) v.webkitEnterFullscreen(); // iOS Safari
    } else {
      if (document.exitFullscreen) document.exitFullscreen();
      else if (document.webkitExitFullscreen) document.webkitExitFullscreen();
    }
  }
  function doRotate() { rotation = (rotation + 90) % 360; applyRotation(); }

  // Rotate the video and scale it so it still fits the viewport (useful for
  // viewing a landscape screen on a portrait device in fullscreen).
  function applyRotation() {
    if (rotation === 0) { v.style.cssText = ''; return; }
    const vw = window.innerWidth, vh = window.innerHeight;
    const ar = (v.videoWidth && v.videoHeight) ? (v.videoWidth / v.videoHeight) : (16 / 9);
    let boxW, boxH;
    if (rotation === 90 || rotation === 270) { boxH = Math.min(vw, vh / ar); boxW = ar * boxH; }
    else { boxW = Math.min(vw, vh * ar); boxH = boxW / ar; }
    v.style.position = 'fixed';
    v.style.left = '50%'; v.style.top = '50%';
    v.style.maxWidth = 'none'; v.style.maxHeight = 'none';
    v.style.width = boxW + 'px'; v.style.height = boxH + 'px';
    v.style.background = '#000';
    v.style.transform = 'translate(-50%, -50%) rotate(' + rotation + 'deg)';
  }

  // The shortcuts bar is always visible windowed, but in fullscreen it only
  // appears on genuine interaction and then auto-hides after ~2.5s.
  function showShortcuts() {
    if (controlActive) return; // bar stays hidden while controlling the host
    shortcuts.classList.add('show');
    clearTimeout(hideTimer);
    if (fsActive()) hideTimer = setTimeout(() => shortcuts.classList.remove('show'), 2500);
  }
  // Reconcile resting state (no interaction): shown when windowed, hidden in
  // fullscreen. Used by background events like 'playing'/fullscreenchange so
  // they never pop the bar up on their own.
  function refreshShortcuts() {
    clearTimeout(hideTimer);
    if (controlActive || fsActive()) shortcuts.classList.remove('show');
    else shortcuts.classList.add('show');
  }

  // ---- Remote control of the host ----
  function setBanner(text) {
    if (!ctrlBanner) return;
    if (text) { ctrlBanner.textContent = text; ctrlBanner.classList.add('show'); }
    else { ctrlBanner.classList.remove('show'); }
  }

  function setControlState(state, reason) {
    controlState = state;
    // The Control chip is hidden when control isn't possible at all.
    const hideChip = (state === 'view-only' || state === 'unavailable' || state === 'unknown');
    if (ctrlBtn) ctrlBtn.classList.toggle('hidden', hideChip);
    if (ctrlLabel) ctrlLabel.textContent = (state === 'requesting') ? 'Requesting…' : (controlActive ? 'Release' : 'Control');
    if (ctrlBtn) ctrlBtn.classList.toggle('active', controlActive);

    if (state === 'requesting') setBanner('Requesting control — waiting for host approval…');
    else if (state === 'denied') setBanner('Control denied' + (reason ? ': ' + reason : ''));
    else if (state === 'busy') setBanner('Another device is currently in control.');
    else if (state === 'view-only') setBanner('');
    else if (state === 'unavailable') setBanner(reason || 'Remote control is disabled on the host.');
    else if (!controlActive) setBanner('');

    if (state === 'denied' || state === 'busy') {
      setTimeout(() => { if (!controlActive && (controlState === 'denied' || controlState === 'busy')) { setControlState('available'); } }, 3500);
    }
  }

  function handleControl(msg) {
    switch (msg.state) {
      case 'granted': enterControl(true); break;
      case 'revoked': enterControl(false); setControlState('available'); setBanner('Control ended' + (msg.reason ? ': ' + msg.reason : '')); setTimeout(() => { if (!controlActive) setBanner(''); }, 3000); break;
      case 'denied': enterControl(false); setControlState('denied', msg.reason); break;
      case 'busy': setControlState('busy'); break;
      case 'view-only': enterControl(false); setControlState('view-only'); break;
      case 'unavailable': enterControl(false); setControlState('unavailable', msg.reason); break;
      case 'available': if (!controlActive) setControlState('available'); break;
      default: break;
    }
  }

  function requestControl() {
    if (controlState === 'view-only' || controlState === 'unavailable') return;
    if (controlActive) { releaseControl(); return; }
    if (!started) startPlayback();
    sendCtl({ type: 'control-request' });
    setControlState('requesting');
  }

  function releaseControl() {
    sendCtl({ type: 'control-release' });
    enterControl(false);
    setControlState('available');
  }

  function enterControl(on) {
    controlActive = on;
    document.body.classList.toggle('controlling', on);
    if (on) {
      // Reset rotation so client coordinates map straight to the host display.
      rotation = 0; applyRotation();
      shortcuts.classList.remove('show');
      ctrlTools.classList.add('show');
      setControlState('granted');
      setBanner('Controlling this Mac — press Esc or Stop to release');
    } else {
      ctrlTools.classList.remove('show');
      closeKeyboards();
      refreshShortcuts();
    }
  }

  // Normalize a pointer event to [0,1] within the video content box.
  function norm(e) {
    const r = v.getBoundingClientRect();
    const x = r.width > 0 ? (e.clientX - r.left) / r.width : 0;
    const y = r.height > 0 ? (e.clientY - r.top) / r.height : 0;
    return { x: Math.max(0, Math.min(1, x)), y: Math.max(0, Math.min(1, y)) };
  }
  function btnName(e) { return e.button === 2 ? 'right' : 'left'; }

  // ---- Control-mode keyboards (native soft keyboard + on-screen keyboard) ----
  const oskMods = { shift: false, ctrl: false, alt: false, meta: false };
  let capsLock = false;
  let oskBuilt = false;
  const oskModEls = [];
  const oskLetterEls = [];

  // Sends a full key press (down then up) to the host with the given modifiers,
  // falling back to the current sticky modifiers when none are supplied.
  function sendKeyTap(code, key, extraMods) {
    const m = extraMods || { shift: oskMods.shift, ctrl: oskMods.ctrl, alt: oskMods.alt, meta: oskMods.meta };
    const base = { kind: 'key', code: code, char: key, shift: !!m.shift, ctrl: !!m.ctrl, alt: !!m.alt, meta: !!m.meta };
    sendInput(Object.assign({ down: true }, base));
    sendInput(Object.assign({ down: false }, base));
  }

  // [label, code, char, options] — options: mod ('shift'|'ctrl'|'alt'|'meta'|'caps'), cls.
  const OSK_LAYOUT = [
    [['Esc','Escape',null,{cls:'fn'}],['F1','F1',null,{cls:'fn'}],['F2','F2',null,{cls:'fn'}],['F3','F3',null,{cls:'fn'}],['F4','F4',null,{cls:'fn'}],['F5','F5',null,{cls:'fn'}],['F6','F6',null,{cls:'fn'}],['F7','F7',null,{cls:'fn'}],['F8','F8',null,{cls:'fn'}],['F9','F9',null,{cls:'fn'}],['F10','F10',null,{cls:'fn'}],['F11','F11',null,{cls:'fn'}],['F12','F12',null,{cls:'fn'}]],
    [['`','Backquote','`'],['1','Digit1','1'],['2','Digit2','2'],['3','Digit3','3'],['4','Digit4','4'],['5','Digit5','5'],['6','Digit6','6'],['7','Digit7','7'],['8','Digit8','8'],['9','Digit9','9'],['0','Digit0','0'],['-','Minus','-'],['=','Equal','='],['Backspace','Backspace',null,{cls:'wide'}]],
    [['Tab','Tab',null,{cls:'wide'}],['q','KeyQ','q'],['w','KeyW','w'],['e','KeyE','e'],['r','KeyR','r'],['t','KeyT','t'],['y','KeyY','y'],['u','KeyU','u'],['i','KeyI','i'],['o','KeyO','o'],['p','KeyP','p'],['[','BracketLeft','['],[']','BracketRight',']'],['\\','Backslash','\\']],
    [['Caps','CapsLock',null,{mod:'caps',cls:'wide'}],['a','KeyA','a'],['s','KeyS','s'],['d','KeyD','d'],['f','KeyF','f'],['g','KeyG','g'],['h','KeyH','h'],['j','KeyJ','j'],['k','KeyK','k'],['l','KeyL','l'],[';','Semicolon',';'],["'",'Quote',"'"],['Enter','Enter',null,{cls:'wide'}]],
    [['Shift','ShiftLeft',null,{mod:'shift',cls:'wide'}],['z','KeyZ','z'],['x','KeyX','x'],['c','KeyC','c'],['v','KeyV','v'],['b','KeyB','b'],['n','KeyN','n'],['m','KeyM','m'],[',','Comma',','],['.','Period','.'],['/','Slash','/'],['Shift','ShiftRight',null,{mod:'shift',cls:'wide'}]],
    [['Ctrl','ControlLeft',null,{mod:'ctrl'}],['Alt','AltLeft',null,{mod:'alt'}],['Cmd','MetaLeft',null,{mod:'meta'}],['Space','Space',' ',{cls:'space'}],['Cmd','MetaRight',null,{mod:'meta'}],['Alt','AltRight',null,{mod:'alt'}],['←','ArrowLeft',null],['↑','ArrowUp',null],['↓','ArrowDown',null],['→','ArrowRight',null]]
  ];

  function buildOSK() {
    OSK_LAYOUT.forEach((row) => {
      const rowEl = document.createElement('div');
      rowEl.className = 'oskrow';
      row.forEach((def) => {
        const [label, code, key, opts] = def;
        const o = opts || {};
        const btn = document.createElement('button');
        btn.className = 'oskkey' + (o.cls ? ' ' + o.cls : '') + (o.mod ? ' mod' : '');
        btn.textContent = label;
        // mousedown preventDefault keeps focus/selection stable and stops the
        // press from bubbling to the video as a host click.
        btn.addEventListener('mousedown', (e) => { e.preventDefault(); e.stopPropagation(); });
        btn.addEventListener('click', (e) => { e.stopPropagation(); handleOskKey({ code: code, key: key, mod: o.mod }); });
        if (o.mod) { btn.dataset.mod = o.mod; oskModEls.push(btn); }
        else if (/^Key[A-Z]$/.test(code)) { btn.dataset.lower = key; oskLetterEls.push(btn); }
        rowEl.appendChild(btn);
      });
      osk.appendChild(rowEl);
    });
  }

  function refreshOskUI() {
    const upper = oskMods.shift || capsLock;
    oskLetterEls.forEach((el) => { el.textContent = upper ? el.dataset.lower.toUpperCase() : el.dataset.lower; });
    oskModEls.forEach((el) => {
      const m = el.dataset.mod;
      const on = (m === 'caps') ? capsLock : oskMods[m];
      el.classList.toggle('active', !!on);
    });
  }

  function clearStickyMods() {
    oskMods.shift = oskMods.ctrl = oskMods.alt = oskMods.meta = false;
    capsLock = false;
    refreshOskUI();
  }

  function handleOskKey(def) {
    if (def.mod) {
      if (def.mod === 'caps') capsLock = !capsLock;
      else oskMods[def.mod] = !oskMods[def.mod];
      refreshOskUI();
      return;
    }
    const isLetter = /^Key[A-Z]$/.test(def.code);
    const shift = oskMods.shift || (capsLock && isLetter);
    sendKeyTap(def.code, def.key, { shift: shift, ctrl: oskMods.ctrl, alt: oskMods.alt, meta: oskMods.meta });
    // One-shot modifiers clear after a normal key (caps lock persists).
    oskMods.shift = oskMods.ctrl = oskMods.alt = oskMods.meta = false;
    refreshOskUI();
  }

  function setOSK(show) {
    if (show) {
      if (!oskBuilt) { buildOSK(); oskBuilt = true; refreshOskUI(); }
      setSysKb(false);            // the two keyboards are mutually exclusive
      kbCatcher.readOnly = true;  // stop the OS keyboard from appearing while shown
    } else {
      kbCatcher.readOnly = false;
    }
    osk.classList.toggle('show', show);
    oskBtn.classList.toggle('active', show);
    updateKbInset();
  }
  function toggleOSK() { setOSK(!osk.classList.contains('show')); }

  function setSysKb(show) {
    if (show) {
      setOSK(false);              // hide the web OSK first (mutually exclusive)
      kbCatcher.readOnly = false;
      resetCatcher();
      kbCatcher.focus();
    } else {
      kbCatcher.blur();
    }
    sysKbBtn.classList.toggle('active', show);
  }
  function toggleSysKb() { setSysKb(document.activeElement !== kbCatcher); }

  function closeKeyboards() {
    setOSK(false);
    kbCatcher.blur();
    sysKbBtn.classList.remove('active');
    clearStickyMods();
  }

  // Native soft-keyboard capture. Mobile IMEs (e.g. Gboard) compose words and
  // don't emit reliable keydown/beforeinput per character, so we diff the input
  // value on every 'input' event (including composition updates) and forward the
  // delta as Unicode text + Backspace. Special keys come via keydown below.
  let kbLastVal = '';
  function resetCatcher() { kbCatcher.value = ''; kbLastVal = ''; }

  kbCatcher.addEventListener('input', () => {
    if (!controlActive) { resetCatcher(); return; }
    const val = kbCatcher.value;
    let i = 0;
    const minLen = Math.min(val.length, kbLastVal.length);
    while (i < minLen && val.charCodeAt(i) === kbLastVal.charCodeAt(i)) i++;
    const deletes = kbLastVal.length - i;
    const inserts = val.slice(i);
    for (let d = 0; d < deletes; d++) sendKeyTap('Backspace', 'Backspace', {});
    if (inserts) sendInput({ kind: 'text', text: inserts });
    kbLastVal = val;
    if (val.length > 256) resetCatcher(); // keep the buffer bounded
  });

  // Non-printable keys that won't show up in the value diff.
  kbCatcher.addEventListener('keydown', (e) => {
    if (!controlActive) return;
    const SPECIAL = { 'Enter': 'Enter', 'Tab': 'Tab', 'ArrowUp': 'ArrowUp', 'ArrowDown': 'ArrowDown', 'ArrowLeft': 'ArrowLeft', 'ArrowRight': 'ArrowRight', 'Escape': 'Escape' };
    const code = SPECIAL[e.key];
    if (!code) return; // printable handled by the input-diff above
    e.preventDefault();
    if (e.key === 'Escape') { releaseControl(); return; }
    sendKeyTap(code, e.key, { shift: e.shiftKey, ctrl: e.ctrlKey, alt: e.altKey, meta: e.metaKey });
  });

  kbCatcher.addEventListener('blur', () => { sysKbBtn.classList.remove('active'); resetCatcher(); });

  // Toolbar buttons.
  ctrlTools.addEventListener('mousedown', (e) => e.stopPropagation());
  sysKbBtn.addEventListener('click', (e) => { e.stopPropagation(); toggleSysKb(); });
  oskBtn.addEventListener('mousedown', (e) => e.preventDefault());
  oskBtn.addEventListener('click', (e) => { e.stopPropagation(); toggleOSK(); });
  stopCtrlBtn.addEventListener('click', (e) => { e.stopPropagation(); releaseControl(); });

  function startPlayback() {
    started = true;
    v.muted = false;
    v.play().catch(() => {});
    overlay.classList.add('hidden');
    updateAudioUI();
    detachPointerGesture();
    refreshShortcuts();
  }

  function trigger(act) {
    // The first interaction just starts playback (autoplay policy); for mute we
    // stop there since starting already unmutes.
    if (!started) { startPlayback(); if (act === 'mute') return; }
    switch (act) {
      case 'mute': doMute(); break;
      case 'volUp': doVolume(0.1); break;
      case 'volDown': doVolume(-0.1); break;
      case 'rotate': doRotate(); break;
      case 'fullscreen': toggleFullscreen(); break;
      case 'control': requestControl(); break;
    }
    showShortcuts();
  }

  // Clickable shortcut chips.
  shortcuts.querySelectorAll('.chip').forEach((btn) => {
    btn.addEventListener('click', (e) => { e.stopPropagation(); trigger(btn.dataset.act); });
  });

  // Keyboard shortcuts (disabled while controlling the host).
  const KEYMAP = { 'm': 'mute', 'f': 'fullscreen', 'r': 'rotate', 'c': 'control', '+': 'volUp', '=': 'volUp', '-': 'volDown', '_': 'volDown' };
  document.addEventListener('keydown', (e) => {
    if (controlActive) return;
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    let k = e.key;
    if (k === 'Add') k = '+'; else if (k === 'Subtract') k = '-';
    const act = KEYMAP[k.toLowerCase()];
    if (!act) return;
    e.preventDefault();
    trigger(act);
  });

  // Fullscreen + resize handling.
  function onFsChange() { updateFsUI(); refreshShortcuts(); applyRotation(); }
  document.addEventListener('fullscreenchange', onFsChange);
  document.addEventListener('webkitfullscreenchange', onFsChange);
  window.addEventListener('resize', () => { if (rotation) applyRotation(); });

  // Reveal shortcuts on interaction with the player (key in fullscreen).
  ['mousemove', 'pointerdown', 'touchstart', 'click'].forEach((ev) =>
    v.addEventListener(ev, () => { showShortcuts(); }, { passive: true }));

  // Forward input to the host while controlling. Coordinates are normalized to
  // the video content box; rotation is reset to 0 on entering control mode.
  v.addEventListener('mousemove', (e) => {
    if (!controlActive) return;
    const now = performance.now();
    if (now - lastMoveSent < 16) return; // ~60 Hz cap
    lastMoveSent = now;
    const n = norm(e); lastPos = n; sendInput({ kind: 'move', x: n.x, y: n.y });
  });
  v.addEventListener('mousedown', (e) => {
    if (!controlActive) return;
    e.preventDefault();
    const n = norm(e); sendInput({ kind: 'down', x: n.x, y: n.y, button: btnName(e) });
  });
  window.addEventListener('mouseup', (e) => {
    if (!controlActive) return;
    e.preventDefault();
    const n = norm(e); sendInput({ kind: 'up', x: n.x, y: n.y, button: btnName(e) });
  });
  v.addEventListener('contextmenu', (e) => { if (controlActive) e.preventDefault(); });
  v.addEventListener('wheel', (e) => {
    if (!controlActive) return;
    e.preventDefault();
    const n = norm(e); sendInput({ kind: 'scroll', x: n.x, y: n.y, dx: e.deltaX, dy: e.deltaY });
  }, { passive: false });
  document.addEventListener('keydown', (e) => {
    if (!controlActive) return;
    // Let the native soft keyboard's input/beforeinput path handle the catcher.
    if (e.target === kbCatcher || e.isComposing || e.keyCode === 229) return;
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); releaseControl(); return; }
    e.preventDefault(); e.stopPropagation();
    sendInput({ kind: 'key', down: true, code: e.code, char: e.key, shift: e.shiftKey, ctrl: e.ctrlKey, alt: e.altKey, meta: e.metaKey });
  }, true);
  document.addEventListener('keyup', (e) => {
    if (!controlActive) return;
    if (e.target === kbCatcher || e.isComposing || e.keyCode === 229) return;
    if (e.key === 'Escape') return;
    e.preventDefault(); e.stopPropagation();
    sendInput({ kind: 'key', down: false, code: e.code, char: e.key, shift: e.shiftKey, ctrl: e.ctrlKey, alt: e.altKey, meta: e.metaKey });
  }, true);

  // Touch: drag on the video to move the host cursor (there is no pointer on
  // touch), then use the corner click buttons to click at that position.
  function touchNorm(t) { return norm({ clientX: t.clientX, clientY: t.clientY }); }
  v.addEventListener('touchstart', (e) => {
    if (!controlActive || !e.touches.length) return;
    e.preventDefault();
    const n = touchNorm(e.touches[0]); lastPos = n;
    sendInput({ kind: 'move', x: n.x, y: n.y });
  }, { passive: false });
  v.addEventListener('touchmove', (e) => {
    if (!controlActive || !e.touches.length) return;
    e.preventDefault();
    const now = performance.now();
    if (now - lastMoveSent < 16) return;
    lastMoveSent = now;
    const n = touchNorm(e.touches[0]); lastPos = n;
    sendInput({ kind: 'move', x: n.x, y: n.y });
  }, { passive: false });

  // Corner click buttons: click at the last cursor position.
  function sendClick(button) {
    sendInput({ kind: 'down', x: lastPos.x, y: lastPos.y, button: button });
    sendInput({ kind: 'up', x: lastPos.x, y: lastPos.y, button: button });
  }
  const leftClickBtn = document.getElementById('leftClickBtn');
  const rightClickBtn = document.getElementById('rightClickBtn');
  [leftClickBtn, rightClickBtn].forEach((b) => {
    b.addEventListener('mousedown', (e) => { e.preventDefault(); e.stopPropagation(); });
    b.addEventListener('touchstart', (e) => { e.stopPropagation(); }, { passive: true });
  });
  leftClickBtn.addEventListener('click', (e) => { e.stopPropagation(); sendClick('left'); });
  rightClickBtn.addEventListener('click', (e) => { e.stopPropagation(); sendClick('right'); });

  // Lift the corner buttons above whatever keyboard is up. For the OS keyboard
  // the visual viewport shrinks; for our in-page web OSK we use its own height.
  function updateKbInset() {
    const vv = window.visualViewport;
    let inset = 0;
    if (vv) inset = Math.max(0, window.innerHeight - vv.height - vv.offsetTop);
    if (osk.classList.contains('show')) inset = Math.max(inset, osk.offsetHeight);
    document.documentElement.style.setProperty('--kb-inset', inset + 'px');
  }
  if (window.visualViewport) {
    window.visualViewport.addEventListener('resize', updateKbInset);
    window.visualViewport.addEventListener('scroll', updateKbInset);
  }
  updateKbInset();

  // First pointer gesture starts playback (browser autoplay policy).
  function onPointerGesture() { if (!started) startPlayback(); }
  function detachPointerGesture() {
    document.removeEventListener('click', onPointerGesture);
    document.removeEventListener('touchstart', onPointerGesture);
  }
  document.addEventListener('click', onPointerGesture);
  document.addEventListener('touchstart', onPointerGesture, { passive: true });

  updateAudioUI();
  updateFsUI();

  connect();
})();
</script>
</body>
</html>
"""#
}
