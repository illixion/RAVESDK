import AVFAudio
import CoreMedia
import DebugLog
import Foundation

/// PCM → Opus via Apple's native AudioToolbox Opus codec
/// (`kAudioFormatOpus` through `AVAudioConverter`) — deliberately not a
/// vendored libopus, which Longwave stubs out in CI/release builds. The
/// converter also handles any capture-rate → 48 kHz resample.
/// Runs on the caller's thread (a mic tap's render thread, a program clock).
///
/// Lifted from Longwave's `BroadcastCore/BroadcastAudioEncoder.swift`
/// (2026-11-10). Adds `encode(_:timestamp48k:)`: a source on its own clock
/// (a broadcast delay whose audio jumps when it is flushed) passes each
/// buffer's RTP timestamp, and each packet out takes the timestamp of the
/// buffer whose samples it starts with, in order. Without it the timestamp
/// runs on from a random start, 960 per packet, as before.
public final class RAVEOpusEncoder: @unchecked Sendable {

    /// One 20 ms Opus frame and its RTP timestamp (48 kHz clock, 960 samples
    /// per frame). Fires on the caller's thread.
    public nonisolated(unsafe) var onEncodedFrame: ((_ frame: Data, _ timestamp48k: UInt32) -> Void)?
    /// Native Opus encode unavailable or failed — the caller downgrades the
    /// broadcast to video-only.
    public nonisolated(unsafe) var onError: ((String) -> Void)?

    public static let samplesPerFrame: UInt32 = 960   // 20 ms @ 48 kHz

    public let channels: UInt32
    public let bitRate: Int
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private nonisolated(unsafe) var outputFormat: AVAudioFormat?
    private nonisolated(unsafe) var pendingBuffers: [AVAudioPCMBuffer] = []
    private nonisolated(unsafe) var nextTimestamp: UInt32 = UInt32.random(in: 0...0x7FFFFFFF)
    /// Explicit timestamps, one per 960 input samples not yet encoded.
    private nonisolated(unsafe) var pendingTimestamps: [UInt32] = []
    private nonisolated(unsafe) var failed = false

    public init(channels: Int, bitRate: Int = 96_000) {
        self.channels = UInt32(max(1, min(2, channels)))
        self.bitRate = bitRate
    }

    /// The running timestamp: 960 a packet from a random start.
    public func encode(_ pcm: AVAudioPCMBuffer) {
        encode(pcm, timestamps: nil)
    }

    /// `pcm` is whole 20 ms frames (a multiple of 960 samples at 48 kHz);
    /// `timestamp48k` is the RTP timestamp of its first sample.
    public func encode(_ pcm: AVAudioPCMBuffer, timestamp48k: UInt32) {
        let frames = max(1, Int(pcm.frameLength) / Int(Self.samplesPerFrame))
        encode(pcm, timestamps: (0..<frames).map { timestamp48k &+ UInt32($0) &* Self.samplesPerFrame })
    }

    private func encode(_ pcm: AVAudioPCMBuffer, timestamps: [UInt32]?) {
        guard !failed, pcm.frameLength > 0 else { return }
        if converter == nil {
            createConverter(inputFormat: pcm.format)
        }
        guard let converter, let outputFormat else { return }
        if let timestamps { pendingTimestamps.append(contentsOf: timestamps) }

        pendingBuffers.append(pcm)
        while true {
            let packet = AVAudioCompressedBuffer(format: outputFormat, packetCapacity: 1,
                                                 maximumPacketSize: 1500)
            var conversionError: NSError?
            let status = converter.convert(to: packet, error: &conversionError) { [self] _, outStatus in
                if pendingBuffers.isEmpty {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return pendingBuffers.removeFirst()
            }
            if let conversionError {
                failOnce("Opus conversion failed: \(conversionError.localizedDescription)")
                return
            }
            guard status == .haveData, packet.byteLength > 0 else { break }
            let frame = Data(bytes: packet.data, count: Int(packet.byteLength))
            let timestamp: UInt32
            if timestamps != nil, !pendingTimestamps.isEmpty {
                timestamp = pendingTimestamps.removeFirst()
                nextTimestamp = timestamp &+ Self.samplesPerFrame
            } else {
                timestamp = nextTimestamp
                nextTimestamp &+= Self.samplesPerFrame
            }
            onEncodedFrame?(frame, timestamp)
        }
    }

    private func createConverter(inputFormat: AVAudioFormat) {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: Self.samplesPerFrame, mBytesPerFrame: 0,
            mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        guard let opusFormat = AVAudioFormat(streamDescription: &description),
              let newConverter = AVAudioConverter(from: inputFormat, to: opusFormat) else {
            failOnce("Native Opus encoding unavailable on this OS")
            return
        }
        newConverter.bitRate = bitRate
        converter = newConverter
        outputFormat = opusFormat
        RAVEBroadcastLog.broadcast.log("""
            Opus encoder ready: \(inputFormat.sampleRate, privacy: .public) Hz \
            \(inputFormat.channelCount, privacy: .public)ch → 48 kHz \(self.channels, privacy: .public)ch
            """)
    }

    /// CMSampleBuffer entry point — used by broadcast extensions, whose
    /// ReplayKit mic feed arrives as sample buffers rather than PCM buffers.
    public func encode(sampleBuffer: CMSampleBuffer) {
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        encode(pcm)
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(frameCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }

    private func failOnce(_ message: String) {
        guard !failed else { return }
        failed = true
        RAVEBroadcastLog.broadcast.error("\(message)")
        onError?(message)
    }
}
