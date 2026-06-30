# LANCast

Stream your Mac's **screen + system audio** to any browser on the **same local
network** (Wi-Fi / Ethernet). LANCast runs as a small menu-bar app; click
**Start Streaming**, then open the shown URL (e.g. `http://192.168.1.20:8080`)
from a phone, tablet, or another computer on the same network.

## How it works

```
ScreenCaptureKit (screen + system audio)
        -> AVAssetWriter (H.264/HEVC + AAC, fragmented-MP4 segments)
        -> embedded HTTP + WebSocket server
        -> browser (Media Source Extensions player)
```

- **Capture:** `ScreenCaptureKit` captures the display and system audio under a
  single Screen Recording permission. No virtual audio driver (BlackHole /
  Loopback) needed.
- **Encode + mux:** `AVAssetWriter` emits fragmented-MP4 segments. Each segment
  starts on a keyframe, so a browser can join mid-stream.
- **Transport:** A dependency-free HTTP + WebSocket server (built on Apple's
  `Network` framework) serves the player page and pushes segments to viewers.
- **Playback:** The browser uses Media Source Extensions to play the live fMP4.
- **Latency knob:** Segment size is configurable (Settings → Latency).
  ~300–700 ms segments give a good balance (sub-second to ~1.5 s end to end).

## Requirements

- macOS 13 (Ventura) or later — required for system-audio capture.
- Swift toolchain (Xcode or Command Line Tools). Build verified with Swift 6.x.
- A modern browser on the viewing device (Chrome, Edge, Firefox, Safari).

## Build & run

```bash
cd ~/LANCast
./build_app.sh          # produces ./LANCast.app and ad-hoc signs it
open LANCast.app        # launches the menu-bar app
```

Or run directly during development:

```bash
swift run
```

On first capture, macOS prompts for **Screen Recording** permission. Use the
menu-bar item **Grant Screen Recording Permission…**, approve it in
**System Settings → Privacy & Security → Screen & System Audio Recording**, then
**Start Streaming**.

## Usage

1. Click the menu-bar icon → **Start Streaming**.
2. The menu shows the stream URL. Click **Copy URL** or **Open in Browser**.
3. On another device on the same network, open that URL in a browser.
4. Tap/click the page once to unmute audio (browser autoplay policy).

In the browser player you get a shortcut bar (also clickable) with keyboard
shortcuts: `M` mute/unmute, `+` / `-` volume, `R` rotate the video, `F`
fullscreen. The bar stays visible in windowed mode and auto-hides a couple of
seconds after you interact in fullscreen.

## Settings

- **Port** — server port (default 8080).
- **Password** — optional; viewers must use the URL containing `?token=…`.
- **Display / Scale / Cursor** — what to capture and at what resolution.
- **Frame rate / Bitrate / Codec** — video quality (H.264 is most compatible).
- **Latency (segment size)** — the main latency vs. efficiency trade-off.
- **Capture system audio** — toggle audio.

Changes apply the next time you start streaming.

## Notes & limitations

- The stream is served on your LAN. Without a password it is open to anyone on
  the network; set a password for basic access control.
- Browser autoplay policies start video muted until the first user interaction.
- HEVC has limited browser support; prefer H.264 for compatibility.
- Microphone capture is intentionally not included (would require macOS 15+);
  this app streams **system audio** (what the Mac is playing).

## Project layout

- `Sources/LANCast/Config/StreamConfig.swift` — persisted settings.
- `Sources/LANCast/Capture/ScreenCaptureManager.swift` — ScreenCaptureKit.
- `Sources/LANCast/Encode/SegmentMuxer.swift` — fMP4 segmenter.
- `Sources/LANCast/Server/StreamServer.swift` — HTTP + WebSocket server.
- `Sources/LANCast/Server/PlayerPage.swift` — embedded browser player (HTML/JS).
- `Sources/LANCast/App/` — menu-bar app + settings UI.
- `bundle/` — `Info.plist` + entitlements used by `build_app.sh`.

## License

Copyright (c) 2026 Timotius Ivan C.

Licensed under the Creative Commons
[Attribution-NonCommercial-NoDerivatives 4.0 International](https://creativecommons.org/licenses/by-nc-nd/4.0/)
(CC BY-NC-ND 4.0) license. You may share the work with attribution for
non-commercial purposes, but may not distribute modified versions. See
[LICENSE](LICENSE) for the full text.
```
