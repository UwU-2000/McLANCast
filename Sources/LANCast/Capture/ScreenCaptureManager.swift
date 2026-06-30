import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Information about a capturable display, surfaced to the settings UI.
struct DisplayInfo: Identifiable, Hashable {
    let id: UInt32          // CGDirectDisplayID
    let width: Int
    let height: Int

    var label: String { "Display \(id) (\(width)x\(height))" }
}

enum CaptureError: LocalizedError {
    case noDisplay
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No capturable display was found."
        case .permissionDenied(let msg):
            return "Screen Recording permission is required. \(msg)"
        }
    }
}

/// Wraps ScreenCaptureKit. Captures one display's screen frames plus system
/// audio, and forwards the raw `CMSampleBuffer`s via closures. Screen and audio
/// buffers share the stream's presentation clock, so downstream muxing stays in
/// sync.
final class ScreenCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {

    /// Called for each complete screen frame (CVImageBuffer-backed sample).
    var onVideo: ((CMSampleBuffer) -> Void)?
    /// Called for each system-audio sample buffer (PCM).
    var onAudio: ((CMSampleBuffer) -> Void)?
    /// Called if the stream stops unexpectedly.
    var onStop: ((Error?) -> Void)?

    private var stream: SCStream?
    private let videoQueue = DispatchQueue(label: "lancast.capture.video")
    private let audioQueue = DispatchQueue(label: "lancast.capture.audio")

    private var videoFrameCount = 0
    private var audioFrameCount = 0

    /// Lists displays available for capture. Triggers the Screen Recording
    /// permission prompt on first call if not yet granted.
    static func availableDisplays() async throws -> [DisplayInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        return content.displays.map {
            DisplayInfo(id: $0.displayID, width: $0.width, height: $0.height)
        }
    }

    /// Starts capturing the configured display.
    func start(config: StreamConfig) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        guard !content.displays.isEmpty else { throw CaptureError.noDisplay }

        let display: SCDisplay = content.displays.first(where: { $0.displayID == config.displayID })
            ?? content.displays.first!

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let streamConfig = SCStreamConfiguration()

        // Output pixel dimensions, scaled from the display's native size.
        let scale = Double(min(100, max(10, config.scalePercent))) / 100.0
        streamConfig.width = max(2, Int((Double(display.width) * scale).rounded()))
        streamConfig.height = max(2, Int((Double(display.height) * scale).rounded()))

        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, config.fps)))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.queueDepth = 6
        streamConfig.showsCursor = config.showsCursor
        streamConfig.scalesToFit = true

        if config.captureAudio {
            streamConfig.capturesAudio = true
            streamConfig.sampleRate = 48000
            streamConfig.channelCount = 2
            streamConfig.excludesCurrentProcessAudio = true
        }

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if config.captureAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }

        self.stream = stream
        try await stream.startCapture()
        Log.log("Capture started on display \(display.displayID): \(streamConfig.width)x\(streamConfig.height) @ \(config.fps)fps, audio=\(config.captureAudio)")
    }

    func stop() async {
        guard let stream = stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }

        switch type {
        case .screen:
            guard isComplete(sampleBuffer) else { return }
            videoFrameCount += 1
            if videoFrameCount == 1 { Log.log("First screen frame delivered") }
            else if videoFrameCount % 120 == 0 { Log.log("Screen frames delivered: \(videoFrameCount)") }
            onVideo?(sampleBuffer)
        case .audio:
            audioFrameCount += 1
            if audioFrameCount == 1 { Log.log("First audio buffer delivered") }
            onAudio?(sampleBuffer)
        default:
            break
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStop?(error)
    }

    // MARK: - Helpers

    /// Screen frames carry a status attachment; `.complete` frames hold new
    /// pixels. We skip frames explicitly marked incomplete (idle/blank/etc.), but
    /// if the status can't be read we forward the frame rather than drop it, so a
    /// parsing mismatch can never silently stall the whole stream.
    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRaw = attachments[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw) else {
            return true
        }
        return status == .complete
    }
}
