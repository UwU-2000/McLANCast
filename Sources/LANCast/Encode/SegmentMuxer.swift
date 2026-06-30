import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox
import UniformTypeIdentifiers

/// Encodes incoming screen + audio sample buffers to H.264/HEVC + AAC and emits
/// fragmented-MP4 segments through `AVAssetWriter`'s delegate.
///
/// The first segment is the initialization segment (ftyp + moov); subsequent
/// segments are self-contained media segments (moof + mdat). Each media segment
/// begins on a keyframe (we force keyframes at the segment interval) so a browser
/// joining mid-stream can start decoding from the next segment.
final class SegmentMuxer: NSObject, AVAssetWriterDelegate {

    /// Called once with the MSE MIME type and the initialization segment.
    var onInit: ((_ mime: String, _ data: Data) -> Void)?
    /// Called for each subsequent media segment.
    var onSegment: ((_ data: Data) -> Void)?

    private let queue = DispatchQueue(label: "lancast.muxer")

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?

    private var sessionStarted = false
    private var startOffset: CMTime?
    private let captureAudio: Bool
    private let codec: VideoCodec

    private var emittedInit = false
    private var segmentCount = 0

    init(config: StreamConfig, pixelWidth: Int, pixelHeight: Int) {
        self.captureAudio = config.captureAudio
        self.codec = config.codec
        super.init()
        setup(config: config, width: pixelWidth, height: pixelHeight)
    }

    private func setup(config: StreamConfig, width: Int, height: Int) {
        let writer = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)
        // Produces fragmented MP4 (init segment + independent media segments) that
        // Media Source Extensions in the browser can consume.
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.shouldOptimizeForNetworkUse = true
        writer.preferredOutputSegmentInterval = CMTime(
            seconds: config.segmentIntervalSeconds,
            preferredTimescale: 600
        )
        writer.initialSegmentStartTime = .zero
        writer.delegate = self

        let codecType: AVVideoCodecType = (codec == .hevc) ? .hevc : .h264
        let profileLevel: Any = (codec == .hevc)
            ? (kVTProfileLevel_HEVC_Main_AutoLevel as String)
            : (AVVideoProfileLevelH264HighAutoLevel as String)

        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: config.bitrateBitsPerSecond,
            AVVideoExpectedSourceFrameRateKey: config.fps,
            // Force a keyframe at every segment boundary so segments are
            // independently decodable for late-joining clients.
            AVVideoMaxKeyFrameIntervalDurationKey: config.segmentIntervalSeconds,
            // Disable B-frames to minimize encode/decode latency.
            AVVideoAllowFrameReorderingKey: false,
            AVVideoProfileLevelKey: profileLevel
        ]

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        if writer.canAdd(videoInput) { writer.add(videoInput) }

        var audioInput: AVAssetWriterInput?
        if captureAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput

        let ok = writer.startWriting()
        Log.log("Muxer setup: \(width)x\(height) codec=\(codec.rawValue) audio=\(captureAudio) segInterval=\(config.segmentIntervalSeconds)s startWriting=\(ok) status=\(writer.status.rawValue)")
        if let error = writer.error {
            Log.log("Muxer writer error after startWriting: \(error)")
        }

        // Stall diagnostic: if no init segment is produced shortly after frames
        // should be flowing, report the writer's state.
        queue.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            if !self.emittedInit {
                let status = self.writer?.status.rawValue ?? -1
                let err = self.writer?.error.map { "\($0)" } ?? "none"
                Log.log("WARNING: no init segment after 4s. sessionStarted=\(self.sessionStarted) writerStatus=\(status) error=\(err)")
            }
        }
    }

    // MARK: - Input

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self, let writer = self.writer, let videoInput = self.videoInput else { return }
            guard writer.status == .writing else { return }

            if !self.sessionStarted {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                self.startOffset = pts
                // Normalize the timeline to start at 0 (capture PTS is mach-time
                // based, ~thousands of seconds, which breaks browser playback).
                writer.startSession(atSourceTime: .zero)
                self.sessionStarted = true
                Log.log("Muxer session started; normalizing timeline (firstPTS=\(pts.seconds)s -> 0)")
            }

            guard let offset = self.startOffset else { return }
            if videoInput.isReadyForMoreMediaData {
                let buffer = self.retime(sampleBuffer, by: offset) ?? sampleBuffer
                if !videoInput.append(buffer) {
                    Log.log("Video append failed. writerStatus=\(writer.status.rawValue) error=\(writer.error.map { "\($0)" } ?? "none")")
                }
            }
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self, let writer = self.writer, let audioInput = self.audioInput else { return }
            guard writer.status == .writing, self.sessionStarted, let offset = self.startOffset else { return }

            if audioInput.isReadyForMoreMediaData {
                let buffer = self.retime(sampleBuffer, by: offset) ?? sampleBuffer
                audioInput.append(buffer)
            }
        }
    }

    func finish() {
        queue.async { [weak self] in
            guard let self, let writer = self.writer else { return }
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            if writer.status == .writing {
                writer.finishWriting { }
            }
            self.writer = nil
            self.videoInput = nil
            self.audioInput = nil
        }
    }

    /// Returns a copy of the sample buffer with its timestamps shifted earlier by
    /// `offset`, so the muxed timeline starts at zero.
    private func retime(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr else {
            return nil
        }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count) == noErr else {
            return nil
        }
        for i in 0..<timings.count {
            if timings[i].presentationTimeStamp.isValid {
                timings[i].presentationTimeStamp = timings[i].presentationTimeStamp - offset
            }
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = timings[i].decodeTimeStamp - offset
            }
        }
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                    sampleBuffer: sampleBuffer,
                                                    sampleTimingEntryCount: count,
                                                    sampleTimingArray: &timings,
                                                    sampleBufferOut: &out) == noErr else {
            return nil
        }
        return out
    }

    // MARK: - AVAssetWriterDelegate

    func assetWriter(_ writer: AVAssetWriter,
                     didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType,
                     segmentReport: AVAssetSegmentReport?) {
        switch segmentType {
        case .initialization:
            let mime = makeMimeType(initSegment: segmentData)
            emittedInit = true
            segmentCount = 0
            Log.log("Init segment emitted (\(segmentData.count) bytes), mime=\(mime)")
            onInit?(mime, segmentData)
        case .separable:
            // Ignore any media segments that arrive before the init segment.
            guard emittedInit else { return }
            segmentCount += 1
            if segmentCount <= 3 || segmentCount % 20 == 0 {
                Log.log("Media segment #\(segmentCount) emitted (\(segmentData.count) bytes)")
            }
            onSegment?(segmentData)
        @unknown default:
            break
        }
    }

    // MARK: - MIME / codec string

    /// Builds the `video/mp4; codecs="..."` string MSE needs, deriving the exact
    /// video codec parameters from the init segment so the browser accepts it.
    private func makeMimeType(initSegment: Data) -> String {
        var codecs: [String] = []

        if codec == .hevc {
            codecs.append(hevcCodecString(from: initSegment) ?? "hvc1.1.6.L120.B0")
        } else {
            codecs.append(avcCodecString(from: initSegment) ?? "avc1.640028")
        }

        if captureAudio {
            codecs.append("mp4a.40.2")
        }

        return "video/mp4; codecs=\"\(codecs.joined(separator: ","))\""
    }

    /// Parses the `avcC` box for profile/compat/level -> `avc1.PPCCLL`.
    private func avcCodecString(from data: Data) -> String? {
        guard let range = findBox("avcC", in: data) else { return nil }
        // box payload: configurationVersion(1), profile(1), compat(1), level(1)
        let start = range.lowerBound
        guard data.count >= start + 4 else { return nil }
        let profile = data[start + 1]
        let compat = data[start + 2]
        let level = data[start + 3]
        return String(format: "avc1.%02X%02X%02X", profile, compat, level)
    }

    /// Best-effort HEVC codec string from the `hvcC` box.
    private func hevcCodecString(from data: Data) -> String? {
        guard let range = findBox("hvcC", in: data) else { return nil }
        let start = range.lowerBound
        guard data.count >= start + 13 else { return nil }
        // hvcC layout: version(1), general_profile_space/tier/idc(1),
        // general_profile_compatibility_flags(4), general_constraint_flags(6),
        // general_level_idc(1)
        let profileByte = data[start + 1]
        let profileSpace = (profileByte & 0xC0) >> 6
        let tierFlag = (profileByte & 0x20) >> 5
        let profileIDC = profileByte & 0x1F

        let compatFlags = UInt32(data[start + 2]) << 24 | UInt32(data[start + 3]) << 16
            | UInt32(data[start + 4]) << 8 | UInt32(data[start + 5])
        let levelIDC = data[start + 12]

        let prefix: String
        switch profileSpace {
        case 1: prefix = "A"
        case 2: prefix = "B"
        case 3: prefix = "C"
        default: prefix = ""
        }
        let tier = tierFlag == 1 ? "H" : "L"
        // Reverse-bit representation of compatibility flags, hex, trimmed.
        let compatHex = String(reverseBits32(compatFlags), radix: 16, uppercase: false)
        return "hvc1.\(prefix)\(profileIDC).\(compatHex).\(tier)\(levelIDC).B0"
    }

    private func reverseBits32(_ value: UInt32) -> UInt32 {
        var v = value
        var r: UInt32 = 0
        for _ in 0..<32 {
            r = (r << 1) | (v & 1)
            v >>= 1
        }
        return r
    }

    /// Returns the range of a box's payload (immediately after the 8-byte header).
    private func findBox(_ name: String, in data: Data) -> Range<Int>? {
        let needle = Array(name.utf8)
        guard needle.count == 4 else { return nil }
        let bytes = [UInt8](data)
        var i = 0
        while i + 4 <= bytes.count {
            if bytes[i] == needle[0], bytes[i + 1] == needle[1],
               bytes[i + 2] == needle[2], bytes[i + 3] == needle[3] {
                let payloadStart = i + 4
                return payloadStart..<bytes.count
            }
            i += 1
        }
        return nil
    }
}
