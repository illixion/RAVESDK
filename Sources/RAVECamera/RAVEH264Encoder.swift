/*
 RAVECamera - realtime H.264 encoding.

 A convergence of two encoders that had drifted apart by a splitter and a log
 line: Longwave's `BroadcastVideoEncoder` (Persona camera and Mirror My View to
 RTSP) and Raven's `ScreenBroadcastEncoder` (Mirror My View into a web page's
 `VideoDecoder`). Both were VideoToolbox sessions with the same tuning, paid
 for on device:

 - **Realtime mode, no B-frames.** PTS stays monotonic, so a caller can hand
   timestamps straight to RTP or to `EncodedVideoChunk` without a reorder
   buffer.
 - **A 1-second GOP by default.** Whoever is downstream — an RTSP reader
   joining mid-stream, a page decoder that missed a chunk, a relay that had to
   drop until the next keyframe — recovers within a second.
 - **The session is created lazily from the first frame's dimensions.** There
   is no reconfigure: a source that changes size mid-stream is a new encoder.

 What comes out is one AVCC access unit per frame — exactly the bytes
 VideoToolbox produced — plus the parameter sets whenever they change. That is
 the shape a WebCodecs decoder wants verbatim; an RTP publisher splits it with
 `RAVEAVCC.nalUnits(fromAVCC:)` and prepends the parameter sets to keyframes
 itself, which is the one thing the two original encoders genuinely disagreed
 on and so stays with the caller.

 Everything runs on the caller's capture thread and VideoToolbox's output
 thread; nothing here touches the main actor.
 */

import CoreMedia
import Foundation
import os
import VideoToolbox

public final class RAVEH264Encoder: @unchecked Sendable {

    public struct Configuration: Sendable {
        /// Average bit rate in bits per second.
        public var bitrate: Int
        /// Expected input rate. A hint to the rate controller, not a cap.
        public var frameRate: Int
        /// Maximum seconds between keyframes.
        public var keyframeInterval: TimeInterval
        public var profile: Profile

        public init(bitrate: Int, frameRate: Int = 30, keyframeInterval: TimeInterval = 1, profile: Profile = .main) {
            self.bitrate = bitrate
            self.frameRate = frameRate
            self.keyframeInterval = keyframeInterval
            self.profile = profile
        }
    }

    /// Level is always left to the encoder (`AutoLevel`): it derives from the
    /// frame size and rate, which this class only learns at the first frame.
    public enum Profile: Sendable {
        case baseline
        case main
        case high

        var videoToolboxProfileLevel: CFString {
            switch self {
            case .baseline: kVTProfileLevel_H264_Baseline_AutoLevel
            case .main: kVTProfileLevel_H264_Main_AutoLevel
            case .high: kVTProfileLevel_H264_High_AutoLevel
            }
        }
    }

    /// SPS and PPS, plus the NAL length-prefix size the access units use —
    /// what `RAVEAVCC.avcC` needs to describe the stream to a decoder, and
    /// what an SDP embeds.
    public struct ParameterSets: Equatable, Sendable {
        public let sps: Data
        public let pps: Data
        public let nalUnitLengthSize: Int
    }

    /// One encoded frame in AVCC form, as VideoToolbox emitted it.
    public struct AccessUnit {
        public let data: Data
        public let presentationTime: CMTime
        public let isKeyframe: Bool
    }

    /// Fires when SPS/PPS first become available, and again only if they
    /// change. On the VideoToolbox output thread.
    public var onParameterSets: ((ParameterSets) -> Void)?
    /// One access unit per encoded frame. On the VideoToolbox output thread.
    public var onAccessUnit: ((AccessUnit) -> Void)?
    /// A session that could not be created or a frame that could not be
    /// submitted. Encoding does not recover from either on its own.
    public var onError: ((String) -> Void)?

    public let configuration: Configuration
    private var session: VTCompressionSession?
    private var currentParameterSets: ParameterSets?
    /// Set by `requestKeyframe()` from any thread, consumed by the next
    /// `encode` on the capture thread.
    private let keyframeRequested = OSAllocatedUnfairLock(initialState: false)

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Encodes the sample's image buffer at the sample's presentation time.
    /// Samples without an image buffer are ignored.
    public func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        encode(pixelBuffer: pixelBuffer, presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    public func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        if session == nil {
            createSession(width: CVPixelBufferGetWidth(pixelBuffer),
                          height: CVPixelBufferGetHeight(pixelBuffer))
        }
        guard let session else { return }
        let forceKeyframe = keyframeRequested.withLock { requested in
            defer { requested = false }
            return requested
        }
        let frameProperties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any] as CFDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTime,
            duration: .invalid, frameProperties: frameProperties, infoFlagsOut: nil
        ) { [weak self] status, _, encodedBuffer in
            guard let self, status == noErr, let encodedBuffer else { return }
            self.emit(encodedBuffer)
        }
        if status != noErr {
            onError?("VTCompressionSessionEncodeFrame failed (\(status))")
        }
    }

    /// Makes the next encoded frame a keyframe. Thread-safe; coalesces if
    /// called more than once before a frame is encoded.
    ///
    /// This is what lets a downstream relay recover in one frame instead of
    /// waiting out the GOP: a relay that had to drop a delta cannot resume
    /// until a keyframe, and the natural one may be a whole
    /// `keyframeInterval` away. With this available, callers can afford a
    /// long interval — fewer large keyframes on the wire — and still rejoin
    /// promptly, because they ask for one exactly when they need it.
    public func requestKeyframe() {
        keyframeRequested.withLock { $0 = true }
    }

    /// Flushes and tears the session down. The next `encode` starts a fresh
    /// session from that frame's dimensions.
    public func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        currentParameterSets = nil
    }

    private func createSession(width: Int, height: Int) {
        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &newSession)
        guard status == noErr, let newSession else {
            onError?("VTCompressionSessionCreate failed (\(status))")
            return
        }
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: configuration.profile.videoToolboxProfileLevel)
        // No B-frames: PTS stays monotonic, so callers can timestamp RTP or
        // EncodedVideoChunk directly without a reorder buffer.
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: configuration.bitrate as CFNumber)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: configuration.frameRate as CFNumber)
        // Short GOP: readers join, and any relay that had to drop recovers, at
        // the next keyframe — so this bounds both to the interval.
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: configuration.keyframeInterval as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(newSession)
        session = newSession
        RAVECameraLog.encoder.info("""
        H.264 encoder ready: \(width, privacy: .public)x\(height, privacy: .public) \
        @ \(self.configuration.bitrate / 1_000_000, privacy: .public) Mbps
        """)
    }

    private func emit(_ encodedBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(encodedBuffer) else { return }

        let keyframe: Bool = {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(encodedBuffer, createIfNecessary: false)
                    as? [[CFString: Any]], let first = attachments.first else { return true }
            return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        }()

        if let formatDescription = CMSampleBufferGetFormatDescription(encodedBuffer) {
            refreshParameterSets(from: formatDescription)
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(encodedBuffer) else { return }
        let length = CMBlockBufferGetDataLength(dataBuffer)
        var avcc = Data(count: length)
        let copyStatus = avcc.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: baseAddress)
        }
        guard copyStatus == noErr else { return }

        onAccessUnit?(AccessUnit(
            data: avcc,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(encodedBuffer),
            isKeyframe: keyframe
        ))
    }

    private func refreshParameterSets(from formatDescription: CMFormatDescription) {
        var nalUnitLengthSize: Int32 = 4
        func parameterSet(at index: Int) -> Data? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: &nalUnitLengthSize)
            guard status == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
        guard let sps = parameterSet(at: 0), let pps = parameterSet(at: 1) else { return }
        let sets = ParameterSets(sps: sps, pps: pps, nalUnitLengthSize: Int(nalUnitLengthSize))
        if sets != currentParameterSets {
            currentParameterSets = sets
            onParameterSets?(sets)
        }
    }
}

/// Rebases presentation times to the first one seen and expresses them in
/// microseconds — the shape `EncodedVideoChunk.timestamp` conventionally
/// takes. Capture and ReplayKit both stamp host-clock times (huge,
/// boot-relative), and every consumer that fed a page had written this same
/// dozen lines.
///
/// A value type: hold one per stream and feed it every access unit in order.
public struct RAVEMicrosecondClock: Sendable {
    private var base: Double?

    public init() {}

    /// nil for a non-finite time, which a caller should drop rather than
    /// stamp with a garbage value.
    public mutating func microseconds(for time: CMTime) -> UInt64? {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { return nil }
        if base == nil { base = seconds }
        return UInt64(max(0, (seconds - (base ?? seconds)) * 1_000_000).rounded())
    }
}
