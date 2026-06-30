import Foundation

/// The browser player page, served at `GET /`. Embedded as a string so it is
/// always available regardless of how the binary is bundled.
enum PlayerPage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>LANCast</title>
<style>
  :root { color-scheme: dark; }
  html, body { margin: 0; height: 100%; background: #000; }
  body {
    display: flex; align-items: center; justify-content: center;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
    color: #e6e6e6; overflow: hidden;
  }
  video { max-width: 100vw; max-height: 100vh; width: auto; height: auto; background: #000; }
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
    display: flex; flex-wrap: wrap; gap: 8px; justify-content: center;
    padding: 8px; max-width: 96vw;
    opacity: 0; transition: opacity .25s ease, transform .25s ease;
    pointer-events: none;
  }
  #shortcuts.show { opacity: 1; transform: translateX(-50%) translateY(0); pointer-events: auto; }
  .chip {
    display: inline-flex; align-items: center; gap: 7px;
    background: rgba(20,20,22,0.72); color: #eee;
    border: 1px solid rgba(255,255,255,0.14); border-radius: 999px;
    padding: 7px 13px 7px 8px; font-size: 13px; cursor: pointer;
    backdrop-filter: blur(8px);
    transition: background .15s ease, border-color .15s ease, transform .05s ease;
  }
  .chip:hover { background: rgba(52,52,58,0.9); border-color: rgba(255,255,255,0.3); }
  .chip:active { transform: scale(0.95); }
  .chip kbd {
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px;
    min-width: 20px; height: 20px; padding: 0 5px;
    display: inline-flex; align-items: center; justify-content: center;
    background: rgba(255,255,255,0.16); border-radius: 6px;
    border: 1px solid rgba(255,255,255,0.18); color: #fff;
  }
  .readout {
    display: inline-flex; align-items: center; justify-content: center;
    padding: 7px 10px; font-size: 13px; min-width: 46px; color: #ddd;
    background: rgba(20,20,22,0.55); border-radius: 999px;
    border: 1px solid rgba(255,255,255,0.10); backdrop-filter: blur(8px);
  }
</style>
</head>
<body>
  <video id="v" autoplay playsinline muted></video>
  <div class="pill" id="pill">connecting...</div>
  <div id="overlay">
    <div id="title">LANCast</div>
    <div id="status">Connecting to stream...</div>
    <div id="hint">Tap / click anywhere to start and unmute audio</div>
  </div>
  <div id="shortcuts" aria-label="Playback shortcuts">
    <button class="chip" data-act="mute" title="Mute / Unmute (M)"><kbd>M</kbd><span id="muteLabel">Mute</span></button>
    <button class="chip" data-act="volDown" title="Volume down (-)"><kbd>&minus;</kbd><span>Vol</span></button>
    <span class="readout" id="volLevel">100%</span>
    <button class="chip" data-act="volUp" title="Volume up (+)"><kbd>+</kbd><span>Vol</span></button>
    <button class="chip" data-act="rotate" title="Rotate video (R)"><kbd>R</kbd><span>Rotate</span></button>
    <button class="chip" data-act="fullscreen" title="Fullscreen (F)"><kbd>F</kbd><span id="fsLabel">Fullscreen</span></button>
  </div>

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

  function wsURL() {
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    const token = new URLSearchParams(location.search).get('token');
    let u = `${proto}://${location.host}/ws`;
    if (token) u += `?token=${encodeURIComponent(token)}`;
    return u;
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
      dbg('ws open; player=v7-shortcuts; UA=' + navigator.userAgent);
    };

    ws.onmessage = (ev) => {
      if (typeof ev.data === 'string') {
        let msg;
        try { msg = JSON.parse(ev.data); } catch (e) { return; }
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

  let started = false;
  let rotation = 0;          // 0 / 90 / 180 / 270 degrees
  let hideTimer = null;

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

  // The shortcuts bar is always visible windowed, but auto-hides in fullscreen.
  function showShortcuts() {
    shortcuts.classList.add('show');
    clearTimeout(hideTimer);
    if (fsActive()) hideTimer = setTimeout(() => shortcuts.classList.remove('show'), 2500);
  }
  function refreshShortcuts() {
    if (fsActive()) { showShortcuts(); }
    else { shortcuts.classList.add('show'); clearTimeout(hideTimer); }
  }

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
    }
    showShortcuts();
  }

  // Clickable shortcut chips.
  shortcuts.querySelectorAll('.chip').forEach((btn) => {
    btn.addEventListener('click', (e) => { e.stopPropagation(); trigger(btn.dataset.act); });
  });

  // Keyboard shortcuts.
  const KEYMAP = { 'm': 'mute', 'f': 'fullscreen', 'r': 'rotate', '+': 'volUp', '=': 'volUp', '-': 'volDown', '_': 'volDown' };
  document.addEventListener('keydown', (e) => {
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
