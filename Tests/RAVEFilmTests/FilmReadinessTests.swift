import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import RAVEFilm

@Suite @MainActor struct FilmReadinessTests {
    @available(macOS 26.0, *)
    final class MonoPictures: FilmPictureSource, @unchecked Sendable {
        let durationSeconds = 1.0
        let frameRate = 30.0
        let summary = "test pictures"
        let pictures: [FilmPictureFrame]
        init() throws {
            var pixels: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 32, kCVPixelFormatType_32BGRA, nil, &pixels)
            let image = try #require(pixels)
            let format = try CMVideoFormatDescription(imageBuffer: image)
            pictures = try (0..<30).map { n in
                let timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                    presentationTimeStamp: CMTime(value: Int64(n), timescale: 30), decodeTimeStamp: .invalid)
                return FilmPictureFrame(picture: try CMSampleBuffer(imageBuffer: image,
                    formatDescription: format, sampleTiming: timing))
            }
        }
        func frames(from filmTime: Double, stereo: Bool) -> AsyncThrowingStream<FilmPictureFrame, Error> {
            AsyncThrowingStream { continuation in
                for picture in pictures { continuation.yield(picture) }
                continuation.finish()
            }
        }
    }
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
    @Test func monoFilmTapFillsAheadWithoutMovingItsClock() async throws {
        guard #available(macOS 26.0, *) else { return }
        let player = FilmVideoPlayer()
        defer { player.stop() }
        let counter = Counter()
        player.onSampleBuffer = { _ in counter.add() }
        player.load(try MonoPictures())
        let deadline = Date.now.addingTimeInterval(5)
        while counter.value < 12, Date.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(counter.value >= 12)
        #expect(CMTimebaseGetRate(player.timebase) == 0)
        #expect(player.currentTime == 0)
        #expect(!player.isPlaying)
    }

    @Test func captionsAndDepthMustBothReleaseBeforeTransportCanResume() {
        guard #available(macOS 15.0, *) else { return }
        let player = FilmPlayer()
        defer { player.stop() }
        player.setAnalysisBuffering(true)
        player.setDepthBuffering(true)
        #expect(player.analysisBuffering)
        player.setAnalysisBuffering(false)
        #expect(player.analysisBuffering)
        player.setDepthBuffering(false)
        #expect(!player.analysisBuffering)
        player.setDepthBuffering(true)
        player.setAnalysisBuffering(true)
        player.setDepthBuffering(false)
        #expect(player.analysisBuffering)
        player.stop()
        #expect(!player.analysisBuffering)
        #expect(!player.isPlaying)
    }
}
