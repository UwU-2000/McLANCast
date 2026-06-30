import Foundation
import Combine

/// Video codec used for the stream.
enum VideoCodec: String, CaseIterable, Identifiable {
    case h264
    case hevc

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .h264: return "H.264 (most compatible)"
        case .hevc: return "HEVC / H.265 (smaller, less browser support)"
        }
    }
}

/// User-facing, persisted configuration for the stream.
///
/// All knobs the user can tune live here. The most important one for the
/// "customizable latency" requirement is `segmentIntervalMs`: smaller segments
/// mean lower latency at a small efficiency cost.
final class StreamConfig: ObservableObject {

    private enum Keys {
        static let port = "port"
        static let displayID = "displayID"
        static let scalePercent = "scalePercent"
        static let fps = "fps"
        static let bitrateMbps = "bitrateMbps"
        static let codec = "codec"
        static let segmentIntervalMs = "segmentIntervalMs"
        static let captureAudio = "captureAudio"
        static let showsCursor = "showsCursor"
        static let password = "password"
        static let allowRemoteControl = "allowRemoteControl"
    }

    private let defaults = UserDefaults.standard

    /// TCP port the HTTP + WebSocket server listens on.
    @Published var port: Int { didSet { defaults.set(port, forKey: Keys.port) } }

    /// CGDirectDisplayID of the display to capture. 0 means "main display".
    @Published var displayID: UInt32 { didSet { defaults.set(Int(displayID), forKey: Keys.displayID) } }

    /// Output scale relative to the captured display, in percent (10...100).
    @Published var scalePercent: Int { didSet { defaults.set(scalePercent, forKey: Keys.scalePercent) } }

    /// Target frame rate.
    @Published var fps: Int { didSet { defaults.set(fps, forKey: Keys.fps) } }

    /// Target average video bitrate, in megabits per second.
    @Published var bitrateMbps: Double { didSet { defaults.set(bitrateMbps, forKey: Keys.bitrateMbps) } }

    /// Video codec.
    @Published var codec: VideoCodec { didSet { defaults.set(codec.rawValue, forKey: Keys.codec) } }

    /// fMP4 segment interval in milliseconds. This is the primary latency knob.
    @Published var segmentIntervalMs: Int { didSet { defaults.set(segmentIntervalMs, forKey: Keys.segmentIntervalMs) } }

    /// Whether to capture system audio.
    @Published var captureAudio: Bool { didSet { defaults.set(captureAudio, forKey: Keys.captureAudio) } }

    /// Whether to render the mouse cursor in the stream.
    @Published var showsCursor: Bool { didSet { defaults.set(showsCursor, forKey: Keys.showsCursor) } }

    /// Optional password. Empty means no auth.
    @Published var password: String { didSet { defaults.set(password, forKey: Keys.password) } }

    /// Master switch: whether LAN clients may request control of the host.
    /// Each request is still individually approved by the host.
    @Published var allowRemoteControl: Bool { didSet { defaults.set(allowRemoteControl, forKey: Keys.allowRemoteControl) } }

    init() {
        let d = UserDefaults.standard
        port = (d.object(forKey: Keys.port) as? Int) ?? 8080
        displayID = UInt32((d.object(forKey: Keys.displayID) as? Int) ?? 0)
        scalePercent = (d.object(forKey: Keys.scalePercent) as? Int) ?? 100
        fps = (d.object(forKey: Keys.fps) as? Int) ?? 30
        bitrateMbps = (d.object(forKey: Keys.bitrateMbps) as? Double) ?? 8.0
        codec = VideoCodec(rawValue: (d.string(forKey: Keys.codec) ?? "")) ?? .h264
        segmentIntervalMs = (d.object(forKey: Keys.segmentIntervalMs) as? Int) ?? 500
        captureAudio = (d.object(forKey: Keys.captureAudio) as? Bool) ?? true
        showsCursor = (d.object(forKey: Keys.showsCursor) as? Bool) ?? true
        password = d.string(forKey: Keys.password) ?? ""
        allowRemoteControl = (d.object(forKey: Keys.allowRemoteControl) as? Bool) ?? true
    }

    /// Segment interval as seconds for AVFoundation APIs.
    var segmentIntervalSeconds: Double {
        Double(max(100, segmentIntervalMs)) / 1000.0
    }

    /// Average bitrate in bits per second.
    var bitrateBitsPerSecond: Int {
        Int(max(0.5, bitrateMbps) * 1_000_000.0)
    }
}
