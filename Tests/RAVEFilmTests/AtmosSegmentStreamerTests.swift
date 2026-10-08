import AVFoundation
import Foundation
import os
import Testing
@testable import RAVEFilm

/// The streamer's use of spare time: fetching ahead of its decoded slots,
/// and telling a source when the playhead outran it.
@Suite("Atmos segment streamer")
struct AtmosSegmentStreamerTests {
    /// A source that answers instantly and logs what it is asked.
    final class Source: FilmStreamingAudioSource, @unchecked Sendable {
        let itemID = "stub"
        var audioStream: Int? { nil }
        private let log = OSAllocatedUnfairLock(initialState: (prefetches: [[Int]](), discards: [ClosedRange<Int>](), stalls: 0, held: Set<Int>()))

        func with(audioStream: Int?) -> any FilmAudioSource { self }
        func audioTracks(languages: [String]) async throws -> [FilmAudioTrack] { [] }
        func audioScene(startSeconds: Double) async throws -> AtmosScene? { nil }

        func audioSegment(_ segment: Int, of scene: AtmosScene) async throws -> FilmAudioSegment {
            let format = AVAudioFormat(standardFormatWithSampleRate: Double(scene.sampleRate), channels: 2)!
            let buffers = scene.groups.map { _ -> AVAudioPCMBuffer in
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(scene.segmentFrames))!
                buffer.frameLength = AVAudioFrameCount(scene.segmentFrames)
                return buffer
            }
            return FilmAudioSegment(events: [], buffers: buffers)
        }

        func prefetchAudio(_ segments: [Int], of scene: AtmosScene) async -> Bool {
            log.withLock { state in
                state.prefetches.append(segments)
                guard let next = segments.first(where: { !state.held.contains($0) }) else { return false }
                state.held.insert(next)
                return true
            }
        }

        func discardPrefetchedAudio(outside range: ClosedRange<Int>) {
            log.withLock { state in
                state.discards.append(range)
                state.held = state.held.filter { range.contains($0) }
            }
        }

        func audioPlaybackStalled(of scene: AtmosScene) { log.withLock { $0.stalls += 1 } }

        var prefetches: [[Int]] { log.withLock { $0.prefetches } }
        var discards: [ClosedRange<Int>] { log.withLock { $0.discards } }
        var held: Set<Int> { log.withLock { $0.held } }
        var stalls: Int { log.withLock { $0.stalls } }
    }

    /// Twelve 0.1 s segments of four channels: six slots, three decoded ahead.
    static let scene = AtmosScene(
        sampleRate: 48000,
        elements: (0 ..< 4).map { AtmosScene.Element(id: $0, channel: $0, kind: "object", bedChannel: nil) },
        frameCount: 12 * 4800, segmentFrames: 4800, segmentCount: 12,
        groups: [[0, 1], [2, 3]], startSeconds: 0, bundleCodecs: nil)

    func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func fetchesAheadOnlyOnceWhatItNeedsIsDecoded() async throws {
        // Synchronization.Atomic, which the streamer is built on, needs macOS 15.
        guard #available(macOS 15.0, *) else { return }
        let source = Source()
        let audio = AtmosObjectAudio(scene: Self.scene)
        let streamer = AtmosSegmentStreamer(audio: audio, client: source, scene: Self.scene)
        streamer.focus(on: 0)
        let task = Task { await streamer.run() }
        defer { task.cancel() }
        // Segments 0...3 decode (one behind is kept, so 0 and three ahead), then the bytes of 4... are fetched.
        #expect(await waitUntil { (0 ... 3).allSatisfy(audio.isResident) })
        #expect(await waitUntil { source.held.count == 8 })
        // Never a request for what the slots hold, or past the film's end.
        let asked = source.prefetches.flatMap { $0 }
        #expect(asked.allSatisfy { $0 >= 4 && $0 <= 11 })
        #expect(source.held == Set(4 ... 11))
        #expect(streamer.prefetched.load(ordering: .relaxed) == 8)
        // Nothing ahead of the first segment is let go of.
        #expect(source.discards.allSatisfy { $0.lowerBound == 0 })
    }

    @Test func letsGoOfWhatItHasMovedPast() async throws {
        // Synchronization.Atomic, which the streamer is built on, needs macOS 15.
        guard #available(macOS 15.0, *) else { return }
        let source = Source()
        let audio = AtmosObjectAudio(scene: Self.scene)
        let streamer = AtmosSegmentStreamer(audio: audio, client: source, scene: Self.scene)
        streamer.focus(on: 0)
        let task = Task { await streamer.run() }
        defer { task.cancel() }
        #expect(await waitUntil { source.held.count == 8 })
        // Seek to segment 8: segments before 7 are no use.
        streamer.focus(on: 8 * 4800)
        #expect(await waitUntil { source.held.allSatisfy { $0 >= 7 } })
        #expect(source.held.isSubset(of: Set(7 ... 11)))
    }

    @Test func tellsTheSourceWhenThePlayheadRunsOut() async throws {
        // Synchronization.Atomic, which the streamer is built on, needs macOS 15.
        guard #available(macOS 15.0, *) else { return }
        let source = Source()
        let audio = AtmosObjectAudio(scene: Self.scene)
        let streamer = AtmosSegmentStreamer(audio: audio, client: source, scene: Self.scene)
        streamer.focus(on: 0)
        let task = Task { await streamer.run() }
        defer { task.cancel() }
        #expect(await waitUntil { audio.isResident(0) })
        // Not playing: an underrun (a render with nothing to play) isn't a stall of the stream.
        audio.underruns.add(1, ordering: .relaxed)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(source.stalls == 0)
        audio.start(at: 0)
        audio.underruns.add(1, ordering: .relaxed)
        #expect(await waitUntil { source.stalls >= 1 })
    }
}
