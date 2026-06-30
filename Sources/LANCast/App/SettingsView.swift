import SwiftUI

extension Notification.Name {
    /// Posted from settings to forget all stored control approvals.
    static let lanCastForgetControlApprovals = Notification.Name("LANCastForgetControlApprovals")
    /// Posted from settings to revoke a single device's approval. userInfo: ["clientId": String].
    static let lanCastRevokeControlApproval = Notification.Name("LANCastRevokeControlApproval")
}

/// Settings UI bound to `StreamConfig`. Changes are persisted immediately and
/// take effect the next time streaming is started.
struct SettingsView: View {
    @ObservedObject var config: StreamConfig
    let approvals: ApprovalStore

    @State private var displays: [DisplayInfo] = []
    @State private var loadError: String?
    @State private var approvedDevices: [ApprovedDevice] = []

    var body: some View {
        Form {
            Section("Network") {
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("Port", value: $config.port, format: .number.grouping(.never))
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("Password (optional)")
                    Spacer()
                    SecureField("none", text: $config.password)
                        .frame(width: 160)
                        .multilineTextAlignment(.trailing)
                }
                Text("Leave the password empty for open access on your LAN. With a password, viewers either use a URL containing ?token= or are prompted for it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Scan to connect") {
                HStack {
                    Spacer()
                    QRCodeView(config: config)
                    Spacer()
                }
            }

            Section("Display") {
                Picker("Capture", selection: $config.displayID) {
                    ForEach(displays) { d in
                        Text(d.label).tag(d.id)
                    }
                }
                if let loadError {
                    Text(loadError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Text("Scale")
                    Slider(value: Binding(
                        get: { Double(config.scalePercent) },
                        set: { config.scalePercent = Int($0) }
                    ), in: 10...100, step: 5)
                    Text("\(config.scalePercent)%").frame(width: 44, alignment: .trailing)
                }
                Toggle("Show mouse cursor", isOn: $config.showsCursor)
            }

            Section("Quality") {
                HStack {
                    Text("Frame rate")
                    Spacer()
                    Picker("", selection: $config.fps) {
                        ForEach([15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                HStack {
                    Text("Bitrate")
                    Slider(value: $config.bitrateMbps, in: 1...50, step: 1)
                    Text(String(format: "%.0f Mbps", config.bitrateMbps))
                        .frame(width: 70, alignment: .trailing)
                }
                Picker("Codec", selection: $config.codec) {
                    ForEach(VideoCodec.allCases) { Text($0.displayName).tag($0) }
                }
            }

            Section("Latency") {
                HStack {
                    Text("Segment size")
                    Slider(value: Binding(
                        get: { Double(config.segmentIntervalMs) },
                        set: { config.segmentIntervalMs = Int($0) }
                    ), in: 100...3000, step: 100)
                    Text("\(config.segmentIntervalMs) ms").frame(width: 64, alignment: .trailing)
                }
                Text("Smaller segments = lower latency, slightly higher overhead. ~300–700 ms is a good balance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Audio") {
                Toggle("Capture system audio", isOn: $config.captureAudio)
                Text("Captures what your Mac is playing (no virtual audio driver needed). Requires macOS 13+.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Remote control") {
                Toggle("Allow clients to request control", isOn: $config.allowRemoteControl)
                Text("When enabled, a viewer can ask to control this Mac's mouse and keyboard. Each request must be approved here on the host, and a browser on this same Mac is always view-only. Requires Accessibility permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Approved devices") {
                if approvedDevices.isEmpty {
                    Text("No approved devices.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(approvedDevices) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).lineLimit(1)
                                Text(device.expiryLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Revoke") { revoke(device) }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                        }
                    }
                    Button("Revoke all") { revokeAll() }
                        .foregroundStyle(.red)
                }
            }

            Text("Changes apply the next time you start streaming.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 540)
        .task { await loadDisplays() }
        .onAppear { refreshDevices() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            refreshDevices()
        }
    }

    private func refreshDevices() {
        approvedDevices = approvals.approvedDevices()
    }

    private func revoke(_ device: ApprovedDevice) {
        approvals.revoke(device.clientId)
        NotificationCenter.default.post(name: .lanCastRevokeControlApproval,
                                        object: nil,
                                        userInfo: ["clientId": device.clientId])
        refreshDevices()
    }

    private func revokeAll() {
        approvals.forgetAll()
        NotificationCenter.default.post(name: .lanCastForgetControlApprovals, object: nil)
        refreshDevices()
    }

    private func loadDisplays() async {
        do {
            let result = try await ScreenCaptureManager.availableDisplays()
            displays = result
            if !result.contains(where: { $0.id == config.displayID }), let first = result.first {
                config.displayID = first.id
            }
        } catch {
            loadError = "Could not list displays. Grant Screen Recording permission and reopen settings."
        }
    }
}
