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
2. The menu shows the stream URL. Click **Copy URL**, **Open in Browser**, or
   **Show QR Code…** and scan it from a phone/tablet to open the stream.
3. On another device on the same network, open that URL in a browser.
4. Tap/click the page once to unmute audio (browser autoplay policy).

While streaming, LANCast keeps the Mac (and its display) awake, since a sleeping
display stops the screen capture.

### Scan to connect (QR code)

**Show QR Code…** (menu bar) and the **Scan to connect** section in Settings both
render a QR code for the stream URL. If a password is set, a **Include password
in QR code** toggle controls whether the QR embeds the `?token=…`:

- **On** — scanning connects instantly.
- **Off** — scanning opens the stream and the viewer is asked for the password
  in an in-page modal before the video starts.

In the browser player you get a shortcut bar (also clickable) with keyboard
shortcuts: `M` mute/unmute, `+` / `-` volume, `R` rotate the video, `F`
fullscreen, and `C` request control. The bar stays visible in windowed mode and
auto-hides a couple of seconds after you interact in fullscreen.

## Remote control (control the host from a viewer)

A viewer can drive the host Mac's mouse and keyboard:

1. Click **Control** (or press `C`) in the player.
2. The host shows an Allow/Deny prompt — identifying the requesting device by
   name — with an expiry (15 min / 1 hour / until streaming stops / always).
   Approved browsers are remembered and skip the prompt until expiry.
3. Once granted, mouse moves/clicks/scroll and typing forward to the host;
   the player's own shortcuts are suspended. A floating toolbar appears with:
   - **Stop** — exit control (same as pressing `Esc`).
   - **Keyboard** — summon the device's native keyboard (touch devices).
   - **On-screen** — toggle an in-browser full-QWERTY keyboard (all platforms,
     with sticky Shift/Ctrl/Alt/Cmd for shortcuts like Cmd+C).
   - **Left/Right click** — bottom-corner buttons that click at the cursor.

On a touch device there is no pointer, so drag on the video to move the host
cursor, then tap the **Left click** / **Right click** corner buttons.

Notes:

- Requires macOS **Accessibility** permission. Use the menu-bar item **Grant
  Accessibility Permission (for control)…** and enable LANCast in
  **System Settings → Privacy & Security → Accessibility**.
- A browser opened on the **same Mac** that's streaming is always view-only
  (prevents a control feedback loop).
- Only one viewer controls at a time; others see "another device is in control".
- It can be disabled entirely in **Settings → Remote control**. The
  **Approved devices** section lists each approved device with its expiry and a
  **Revoke** button, plus **Revoke all**.

### Device names

Because browsers can't read a device's serial number or the OS username, each
device identifies itself by an optional **1-word nickname** (entered on the
connect screen) plus an **auto-detected label** (model / OS / browser). For
example `Casey Galaxy S23 Ultra · Android`, or just `Chrome on macOS` when no
nickname is set. Common Android model codes are mapped to marketing names;
unknown codes show the raw code, and iOS reports only a generic device (Apple
hides the model).

## Settings

- **Port** — server port (default 8080).
- **Password** — optional; viewers either use a URL containing `?token=…` or are
  prompted for the password in the browser.
- **Scan to connect** — QR code for the stream URL, with a toggle to embed the
  password or not.
- **Display / Scale / Cursor** — what to capture and at what resolution.
- **Frame rate / Bitrate / Codec** — video quality (H.264 is most compatible).
- **Latency (segment size)** — the main latency vs. efficiency trade-off.
- **Capture system audio** — toggle audio.
- **Allow clients to request control** — master switch for remote control
  (each request is still approved individually on the host).
- **Approved devices** — review and revoke remembered controllers.

Changes apply the next time you start streaming.

## Notes & limitations

- The stream is served on your LAN. Without a password it is open to anyone on
  the network; set a password for basic access control. The player page itself
  is served openly — the password gate is enforced on the stream (WebSocket).
- While streaming, the Mac is kept awake (display sleep is prevented so capture
  keeps working). Closing the lid still sleeps the Mac unless on AC power with an
  external display attached.
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
- `Sources/LANCast/Input/RemoteInputController.swift` — CGEvent injection for remote control.
- `Sources/LANCast/Input/ApprovalStore.swift` — persisted control approvals + device names.
- `Sources/LANCast/Util/QRCode.swift` — QR-code image generation.
- `Sources/LANCast/Util/SleepGuard.swift` — keeps the Mac awake while streaming.
- `Sources/LANCast/App/` — menu-bar app, settings UI, and QR view.
- `bundle/` — `Info.plist` + entitlements used by `build_app.sh`.

## License

Copyright (c) 2026 Timotius Ivan C.

Licensed under the Creative Commons
[Attribution-NonCommercial-NoDerivatives 4.0 International](https://creativecommons.org/licenses/by-nc-nd/4.0/)
(CC BY-NC-ND 4.0) license. You may share the work with attribution for
non-commercial purposes, but may not distribute modified versions. See
[LICENSE](LICENSE) for the full text.
```
