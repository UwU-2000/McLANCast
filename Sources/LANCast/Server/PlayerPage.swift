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
    align-items: center; justify-content: center; gap: 14px;
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
  #controls {
    position: fixed; left: 0; right: 0; bottom: 0; z-index: 6;
    display: flex; align-items: center; gap: 12px;
    padding: 22px 18px 14px;
    background: linear-gradient(to top, rgba(0,0,0,0.65), rgba(0,0,0,0));
    opacity: 0; transform: translateY(8px);
    transition: opacity .25s ease, transform .25s ease;
    pointer-events: none;
  }
  #controls.show { opacity: 1; transform: translateY(0); pointer-events: auto; }
  #controls button {
    background: none; border: none; color: #fff; cursor: pointer; padding: 6px;
    border-radius: 8px; display: inline-flex; align-items: center; justify-content: center;
    transition: background .15s ease;
  }
  #controls button:hover { background: rgba(255,255,255,0.16); }
  #controls svg { width: 26px; height: 26px; fill: currentColor; display: block; }
  #vol { width: 110px; max-width: 30vw; accent-color: #fff; cursor: pointer; }
  #controls .spacer { flex: 1; }
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
  <div id="controls">
    <button id="muteBtn" title="Mute / Unmute" aria-label="Mute / Unmute"></button>
    <input id="vol" type="range" min="0" max="1" step="0.05" value="1" title="Volume" aria-label="Volume">
    <span class="spacer"></span>
    <button id="fsBtn" title="Fullscreen" aria-label="Fullscreen"></button>
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
    if (v.paused) v.play().catch((e) => { dbg('play() rejected: ' + e); });
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
      dbg('ws open; player=v6-segments; UA=' + navigator.userAgent);
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
  v.addEventListener('playing', () => { dbg('video playing'); setTimeout(() => overlay.classList.add('hidden'), 600); });
  v.addEventListener('waiting', () => { lastStateLog = 0; logState('waiting'); });
  v.addEventListener('stalled', () => { lastStateLog = 0; logState('stalled'); });
  v.addEventListener('canplay', () => { dbg('video canplay'); });

  // ---- Playback controls (live stream: mute/volume + fullscreen only) ----
  const controls = document.getElementById('controls');
  const muteBtn = document.getElementById('muteBtn');
  const fsBtn = document.getElementById('fsBtn');
  const vol = document.getElementById('vol');

  const ICON = {
    volume: '<svg viewBox="0 0 24 24"><path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z"/></svg>',
    muted: '<svg viewBox="0 0 24 24"><path d="M16.5 12c0-1.77-1.02-3.29-2.5-4.03v2.21l2.45 2.45c.03-.2.05-.41.05-.63zm2.5 0c0 .94-.2 1.82-.54 2.64l1.51 1.51A8.8 8.8 0 0 0 21 12c0-4.28-2.99-7.86-7-8.77v2.06c2.89.86 5 3.54 5 6.71zM4.27 3L3 4.27 7.73 9H3v6h4l5 5v-6.73l4.25 4.25c-.67.52-1.42.93-2.25 1.18v2.06a8.94 8.94 0 0 0 3.69-1.81L19.73 21 21 19.73l-9-9L4.27 3zM12 4L9.91 6.09 12 8.18V4z"/></svg>',
    enterFs: '<svg viewBox="0 0 24 24"><path d="M7 14H5v5h5v-2H7v-3zm-2-4h2V7h3V5H5v5zm12 7h-3v2h5v-5h-2v3zM14 5v2h3v3h2V5h-5z"/></svg>',
    exitFs: '<svg viewBox="0 0 24 24"><path d="M5 16h3v3h2v-5H5v2zm3-8H5v2h5V5H8v3zm6 11h2v-3h3v-2h-5v5zm2-11V5h-2v5h5V8h-3z"/></svg>'
  };

  function fsActive() { return document.fullscreenElement || document.webkitFullscreenElement; }

  function updateAudioUI() {
    muteBtn.innerHTML = (v.muted || v.volume === 0) ? ICON.muted : ICON.volume;
    vol.value = v.muted ? 0 : v.volume;
  }
  function updateFsUI() { fsBtn.innerHTML = fsActive() ? ICON.exitFs : ICON.enterFs; }

  muteBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    v.muted = !v.muted;
    if (!v.muted && v.volume === 0) v.volume = 0.5;
    updateAudioUI();
  });
  vol.addEventListener('input', (e) => {
    e.stopPropagation();
    const val = parseFloat(vol.value);
    v.volume = val;
    v.muted = (val === 0);
    updateAudioUI();
  });
  vol.addEventListener('click', (e) => e.stopPropagation());

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
  fsBtn.addEventListener('click', (e) => { e.stopPropagation(); toggleFullscreen(); });
  document.addEventListener('fullscreenchange', updateFsUI);
  document.addEventListener('webkitfullscreenchange', updateFsUI);

  // Auto-showing control bar.
  let hideTimer = null;
  function showControls() {
    controls.classList.add('show');
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => controls.classList.remove('show'), 2800);
  }
  ['mousemove', 'pointerdown', 'touchstart', 'keydown'].forEach((ev) =>
    document.addEventListener(ev, showControls, { passive: true }));
  controls.addEventListener('mouseenter', () => { clearTimeout(hideTimer); controls.classList.add('show'); });
  controls.addEventListener('mouseleave', showControls);

  updateAudioUI();
  updateFsUI();

  // First user gesture: satisfy autoplay policy by unmuting + playing, then stop
  // intercepting taps so the controls take over.
  function detachGesture() {
    document.removeEventListener('click', onUserGesture);
    document.removeEventListener('touchstart', onUserGesture);
    document.removeEventListener('keydown', onUserGesture);
  }
  function onUserGesture() {
    v.muted = false;
    v.play().catch(() => {});
    overlay.classList.add('hidden');
    updateAudioUI();
    showControls();
    detachGesture();
  }
  document.addEventListener('click', onUserGesture);
  document.addEventListener('touchstart', onUserGesture, { passive: true });
  document.addEventListener('keydown', onUserGesture);

  connect();
})();
</script>
</body>
</html>
"""#
}
