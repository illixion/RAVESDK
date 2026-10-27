import AVFoundation
import Foundation

/// Mono analysis audio from the film's currently selected source. This is a
/// transport adapter; it owns no caption model or inference dependency.
public struct RAVEFilmAudioChunk: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public let time: Double
    public init(buffer: AVAudioPCMBuffer, time: Double) { self.buffer = buffer; self.time = time }
}
public struct RAVEFilmAudioSource: Sendable {
    public let next: @Sendable () async throws -> RAVEFilmAudioChunk?
    public init(next: @escaping @Sendable () async throws -> RAVEFilmAudioChunk?) { self.next = next }
}

@available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
extension FilmPlayer {
    /// Analysis reads the selected audio track ahead through the same source
    /// as playback. It owns no audio renderer or second playback clock.
    public func captionAudioSource(start: Double) throws -> RAVEFilmAudioSource {
        guard let scene, let source = captionSource else { throw URLError(.resourceUnavailable) }
        let reader = FilmCaptionReader(source: source, scene: scene, start: start)
        return RAVEFilmAudioSource { try await reader.next() }
    }
}

/// Only one decoded segment is retained. Mix excludes LFE and normalizes the
/// sum; spatialization is unnecessary for recognition. This also covers discs
/// and offline packages, whose audio sources implement the same protocol.
private actor FilmCaptionReader {
    let source: any FilmAudioSource
    let scene: AtmosScene
    let start: Double
    var segment: Int
    init(source: any FilmAudioSource, scene: AtmosScene, start: Double) {
        self.source = source; self.scene = scene; self.start = start
        segment = max(0, Int((start - scene.startSeconds) * Double(scene.sampleRate)) / scene.segmentFrames)
    }
    func next() async throws -> RAVEFilmAudioChunk? {
        guard segment < scene.segmentCount else { return nil }
        try Task.checkCancellation()
        let index = segment
        let content = try await source.audioSegment(index, of: scene)
        try Task.checkCancellation()
        segment += 1
        let time = scene.startSeconds + Double(index * scene.segmentFrames) / Double(scene.sampleRate)
        let skip = max(0, Int((start - time) * Double(scene.sampleRate)))
        let frames = min(scene.segmentFrames, content.buffers.map { Int($0.frameLength) }.max() ?? 0)
        guard frames > skip, let mono = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(standardFormatWithSampleRate: Double(scene.sampleRate), channels: 1)!,
            frameCapacity: AVAudioFrameCount(frames - skip)), let destination = mono.floatChannelData?[0] else {
            throw URLError(.cannotDecodeContentData)
        }
        mono.frameLength = mono.frameCapacity
        // AVAudioPCMBuffer does not guarantee that newly allocated samples are
        // zeroed. The mix below accumulates into every output frame.
        destination.initialize(repeating: 0, count: Int(mono.frameLength))
        let excluded = Set(scene.elements.filter { $0.bedChannel?.uppercased() == "LFE" }.map(\.channel))
        var channels = 0
        for (group, buffer) in zip(scene.groups, content.buffers) {
            let interleaved = buffer.format.isInterleaved
            let count = Int(buffer.format.channelCount)
            for channel in 0..<min(group.count, count) where !excluded.contains(group[channel]) {
                channels += 1
                for frame in skip..<min(frames, Int(buffer.frameLength)) {
                    let offset = interleaved ? frame * count + channel : frame
                    let plane = interleaved ? 0 : channel
                    let value: Float
                    switch buffer.format.commonFormat {
                    case .pcmFormatFloat32: value = buffer.floatChannelData![plane][offset]
                    case .pcmFormatInt16: value = Float(buffer.int16ChannelData![plane][offset]) / 32768
                    case .pcmFormatInt32: value = Float(buffer.int32ChannelData![plane][offset]) / 2147483648
                    default: throw URLError(.cannotDecodeContentData)
                    }
                    destination[frame - skip] += value
                }
            }
        }
        let gain = 1 / sqrt(Float(max(1, channels)))
        for frame in 0..<Int(mono.frameLength) { destination[frame] = min(1, max(-1, destination[frame] * gain)) }
        return .init(buffer: mono, time: time + Double(skip) / Double(scene.sampleRate))
    }
}
