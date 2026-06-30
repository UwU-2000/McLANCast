import SwiftUI

/// Scan-to-connect QR code with the stream URL. Reused by the menu-bar window
/// and the Settings panel. Observes `StreamConfig` so it regenerates live when
/// the port, password, or "include password" toggle changes.
struct QRCodeView: View {
    @ObservedObject var config: StreamConfig

    private var ip: String? { StreamServer.localIPv4Address() }

    var body: some View {
        VStack(spacing: 12) {
            Text("Scan to connect")
                .font(.headline)

            if let ip {
                let url = config.qrURL(ip: ip)
                if let image = QRCode.image(from: url, size: 220) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                        .padding(10)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Text(url)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                if !config.password.isEmpty {
                    Toggle("Include password in QR code", isOn: $config.includePasswordInQR)
                    Text(config.includePasswordInQR
                         ? "Scanning connects instantly with the password embedded."
                         : "Scanning opens the stream; the viewer is asked to enter the password.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                Text("No LAN address found. Connect to Wi-Fi or Ethernet, then reopen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(height: 220)
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}
