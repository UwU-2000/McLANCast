import AppKit
import SwiftUI
import CoreGraphics

/// Wires together capture -> mux -> server and drives the menu-bar UI.
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let config = StreamConfig()

    private var capture: ScreenCaptureManager?
    private var muxer: SegmentMuxer?
    private let server = StreamServer()
    private let input = RemoteInputController()
    private let approvals = ApprovalStore()

    private var isStreaming = false
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private weak var viewersMenuItem: NSMenuItem?

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "play.rectangle.on.rectangle",
                                   accessibilityDescription: "LANCast")
            button.image?.isTemplate = true
        }
        statusItem = item
        wireServerCallbacks()
        rebuildMenu()
    }

    private func wireServerCallbacks() {
        server.onViewerCountChanged = { [weak self] count in
            self?.viewersMenuItem?.title = "Viewers: \(count)"
        }
        server.onControlRequest = { [weak self] request in
            self?.handleControlRequest(request)
        }
        server.onInput = { [weak self] event in
            self?.input.handle(event)
        }
        server.onControllerCleared = { [weak self] in
            self?.input.releaseHeld()
        }
        NotificationCenter.default.addObserver(
            forName: .lanCastForgetControlApprovals, object: nil, queue: .main
        ) { [weak self] _ in
            self?.approvals.forgetAll()
            self?.server.revokeControl(reason: "Approvals were cleared on the host.")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopStreaming()
    }

    // MARK: - Streaming control

    private func startStreaming() {
        Task { @MainActor in
            do {
                let displays = try await ScreenCaptureManager.availableDisplays()
                guard let display = displays.first(where: { $0.id == config.displayID }) ?? displays.first else {
                    throw CaptureError.noDisplay
                }
                config.displayID = display.id

                let scale = Double(min(100, max(10, config.scalePercent))) / 100.0
                let width = max(2, Int((Double(display.width) * scale).rounded()))
                let height = max(2, Int((Double(display.height) * scale).rounded()))

                let muxer = SegmentMuxer(config: config, pixelWidth: width, pixelHeight: height)
                muxer.onInit = { [weak self] mime, data in
                    self?.server.setInit(mime: mime, segment: data)
                }
                muxer.onSegment = { [weak self] data in
                    self?.server.broadcastSegment(data)
                }

                let capture = ScreenCaptureManager()
                capture.onVideo = { muxer.appendVideo($0) }
                capture.onAudio = { muxer.appendAudio($0) }
                capture.onStop = { [weak self] error in
                    Task { @MainActor in self?.handleUnexpectedStop(error) }
                }

                input.displayID = display.id
                try server.start(config: config)
                Log.log("Server started on port \(config.port)")
                try await capture.start(config: config)

                self.muxer = muxer
                self.capture = capture
                self.isStreaming = true
                rebuildMenu()
                Log.log("Streaming started (display \(display.id), \(width)x\(height))")
            } catch {
                Log.log("Start failed: \(error)")
                stopStreaming()
                presentError(error)
            }
        }
    }

    private func stopStreaming() {
        let capture = self.capture
        let muxer = self.muxer
        self.capture = nil
        self.muxer = nil
        Task {
            await capture?.stop()
            muxer?.finish()
        }
        server.stop()
        approvals.clearSession()
        isStreaming = false
        rebuildMenu()
    }

    private func handleUnexpectedStop(_ error: Error?) {
        stopStreaming()
        if let error {
            presentError(error)
        }
    }

    // MARK: - URL

    private var streamURL: String? {
        guard let ip = StreamServer.localIPv4Address() else { return nil }
        var url = "http://\(ip):\(config.port)"
        if !config.password.isEmpty {
            url += "/?token=\(config.password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? config.password)"
        }
        return url
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        if isStreaming {
            let url = streamURL ?? "No network address found"
            let header = NSMenuItem(title: "Streaming at:", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            let urlItem = NSMenuItem(title: url, action: #selector(copyURL), keyEquivalent: "")
            urlItem.target = self
            menu.addItem(urlItem)

            let viewers = NSMenuItem(title: "Viewers: \(server.viewerCount)", action: nil, keyEquivalent: "")
            viewers.isEnabled = false
            menu.addItem(viewers)
            viewersMenuItem = viewers

            menu.addItem(.separator())

            let open = NSMenuItem(title: "Open in Browser", action: #selector(openInBrowser), keyEquivalent: "o")
            open.target = self
            menu.addItem(open)

            let copy = NSMenuItem(title: "Copy URL", action: #selector(copyURL), keyEquivalent: "c")
            copy.target = self
            menu.addItem(copy)

            let stop = NSMenuItem(title: "Stop Streaming", action: #selector(toggleStreaming), keyEquivalent: "s")
            stop.target = self
            menu.addItem(stop)
        } else {
            let start = NSMenuItem(title: "Start Streaming", action: #selector(toggleStreaming), keyEquivalent: "s")
            start.target = self
            menu.addItem(start)
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let perm = NSMenuItem(title: "Grant Screen Recording Permission…",
                              action: #selector(requestPermission), keyEquivalent: "")
        perm.target = self
        menu.addItem(perm)

        let axPerm = NSMenuItem(title: "Grant Accessibility Permission (for control)…",
                                action: #selector(requestAccessibilityPermission), keyEquivalent: "")
        axPerm.target = self
        menu.addItem(axPerm)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit LANCast", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func toggleStreaming() {
        if isStreaming { stopStreaming() } else { startStreaming() }
    }

    @objc private func copyURL() {
        guard let url = streamURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc private func openInBrowser() {
        guard let url = streamURL, let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }

    @objc private func requestPermission() {
        // Triggers the system Screen Recording prompt if not yet granted.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        } else {
            let alert = NSAlert()
            alert.messageText = "Screen Recording is already allowed."
            alert.informativeText = "LANCast can capture your screen and system audio."
            alert.runModal()
        }
    }

    @objc private func requestAccessibilityPermission() {
        if RemoteInputController.hasAccessibility() {
            let alert = NSAlert()
            alert.messageText = "Accessibility is already allowed."
            alert.informativeText = "Approved viewers can control this Mac's mouse and keyboard."
            alert.runModal()
        } else {
            RemoteInputController.requestAccessibility()
            let alert = NSAlert()
            alert.messageText = "Grant Accessibility permission"
            alert.informativeText = "Open System Settings > Privacy & Security > Accessibility and enable LANCast, then control requests can be honored."
            alert.runModal()
        }
    }

    // MARK: - Remote control approval

    private func handleControlRequest(_ request: StreamServer.ControlRequest) {
        guard RemoteInputController.hasAccessibility() else {
            server.denyControl(request, state: "denied",
                               reason: "The host hasn't granted Accessibility permission yet.")
            RemoteInputController.requestAccessibility()
            return
        }

        // Previously approved (and unexpired) clients are auto-granted.
        if approvals.isApproved(request.clientId) {
            input.displayID = config.displayID
            server.grantControl(request)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Allow remote control?"
        alert.informativeText = "A viewer at \(request.ip) wants to control this Mac's mouse and keyboard."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")

        let expiries = ApprovalStore.Expiry.allCases
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        popup.addItems(withTitles: expiries.map { $0.label })
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 52))
        let label = NSTextField(labelWithString: "Allow control for:")
        label.frame = NSRect(x: 0, y: 30, width: 240, height: 18)
        wrapper.addSubview(label)
        popup.frame = NSRect(x: 0, y: 0, width: 240, height: 26)
        wrapper.addSubview(popup)
        alert.accessoryView = wrapper

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let expiry = expiries[min(popup.indexOfSelectedItem, expiries.count - 1)]
            approvals.approve(request.clientId, expiry: expiry)
            input.displayID = config.displayID
            server.grantControl(request)
        } else {
            server.denyControl(request, state: "denied", reason: "The host denied control.")
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if isStreaming { viewersMenuItem?.title = "Viewers: \(server.viewerCount)" }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 540),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            window.title = "LANCast Settings"
            window.isReleasedWhenClosed = false
            window.center()
            let view = SettingsView(config: config)
            window.contentViewController = NSHostingController(rootView: view)
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        stopStreaming()
        NSApp.terminate(nil)
    }

    // MARK: - Errors

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "LANCast could not start streaming"
        alert.informativeText = error.localizedDescription
            + "\n\nIf this is about permissions, grant Screen Recording in System Settings > Privacy & Security, then try again."
        alert.runModal()
    }
}
