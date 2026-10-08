#if os(macOS)
import AVFoundation
import CoreMedia
import CoreVideo
import Testing
@testable import RAVEMedia

/// Real B-frame H.264 samples: catches decode-order/PTS confusion, future
/// pictures after seek, duplicate paused frames, and the pump's BGRA contract.
/// Fixture: ffmpeg -f lavfi -i testsrc2=size=64x64:rate=30 -t 1
/// -c:v libx264 -bf 2 -g 15 -pix_fmt yuv420p -movflags +faststart clocked-h264.mp4
@Suite struct SampleBufferFrameSourceTests {
    private func samples() async throws -> [CMSampleBuffer] {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/clocked-h264", withExtension: "mp4"))
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var samples: [CMSampleBuffer] = []
        while let sample = output.copyNextSampleBuffer() { samples.append(sample) }
        #expect(reader.status == .completed)
        return samples
    }

    private func clock(at seconds: Double) throws -> CMTimebase {
        var timebase: CMTimebase?
        #expect(CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase) == noErr)
        let clock = try #require(timebase)
        CMTimebaseSetRate(clock, rate: 0)
        CMTimebaseSetTime(clock, time: CMTime(seconds: seconds, preferredTimescale: 600))
        return clock
    }

    @Test func decodesThePictureDueNowRatherThanTheLastPrefetchedSample() async throws {
        let clock = try clock(at: 0.35)
        let source = SampleBufferFrameSource(timebase: clock)
        defer { source.invalidate() }
        let samples = try await samples()
        // The fixture genuinely has reordered B frames.
        #expect(samples.contains { CMSampleBufferGetPresentationTimeStamp($0) != CMSampleBufferGetDecodeTimeStamp($0) })
        samples.forEach { source.submit($0) }
        let frame = try #require(source.nextFrame(hostTime: 0))
        #expect(frame.itemTime.seconds <= 0.35)
        #expect(frame.itemTime.seconds >= 0.30)
        #expect(CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_32BGRA)
        #expect(source.decodeFailure == nil)
        // Paused: the exact same picture is never warped twice.
        #expect(source.nextFrame(hostTime: 1) == nil)
        CMTimebaseSetTime(clock, time: CMTime(seconds: 0.7, preferredTimescale: 600))
        let advanced = try #require(source.nextFrame(hostTime: 2))
        #expect(advanced.itemTime > frame.itemTime)
        #expect(advanced.itemTime.seconds <= 0.7)
        #expect(advanced.itemTime.seconds >= 0.65)
    }

    /// Pictures a host decoded itself (Blu-ray MVC) arrive as 4:2:0 pixel
    /// buffers and come out as BGRA at their own time, never early.
    @Test func decodedPicturesAreConvertedNotDecoded() throws {
        let clock = try clock(at: 0.1)
        let source = SampleBufferFrameSource(timebase: clock)
        defer { source.invalidate() }
        for seconds in [0.0, 0.04, 0.08, 0.12] {
            var pixels: CVPixelBuffer?
            #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 32, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == kCVReturnSuccess)
            let image = try #require(pixels)
            let format = try CMVideoFormatDescription(imageBuffer: image)
            let timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 25),
                                            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
                                            decodeTimeStamp: .invalid)
            source.submit(try CMSampleBuffer(imageBuffer: image, formatDescription: format, sampleTiming: timing))
        }
        let frame = try #require(source.nextFrame(hostTime: 0))
        #expect(frame.itemTime.seconds == 0.08)
        #expect(CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetWidth(frame.pixelBuffer) == 64)
        #expect(source.decodeFailure == nil)
        CMTimebaseSetTime(clock, time: CMTime(seconds: 0.13, preferredTimescale: 600))
        #expect(try #require(source.nextFrame(hostTime: 1)).itemTime.seconds == 0.12)
    }

    @Test func aSeekDiscardsOldPicturesAndReprimesAtTheNewTime() async throws {
        let clock = try clock(at: 0.7)
        let source = SampleBufferFrameSource(timebase: clock)
        defer { source.invalidate() }
        let samples = try await samples()
        for sample in samples {
            // FilmVideoPlayer hides keyframe preroll from its display layer.
            // The stereo tap must still decode it to reach the sought picture.
            if CMSampleBufferGetPresentationTimeStamp(sample).seconds < 0.69,
               let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
                let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(dictionary,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            source.submit(sample)
        }
        let sought = try #require(source.nextFrame(hostTime: 0))
        #expect(sought.itemTime.seconds >= 0.69)
        #expect(sought.itemTime.seconds <= 0.7)
        source.reset()
        CMTimebaseSetTime(clock, time: CMTime(seconds: 0.05, preferredTimescale: 600))
        #expect(source.nextFrame(hostTime: 1) == nil)
        for sample in samples {
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
                let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionaryRemoveValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque())
            }
            source.submit(sample)
        }
        let frame = try #require(source.nextFrame(hostTime: 2))
        #expect(frame.itemTime.seconds >= 0)
        #expect(frame.itemTime.seconds <= 0.05)
        #expect(source.decodeFailure == nil)
    }

    @Test func stoppedSourcesIgnoreLateSubmissions() async throws {
        let source = SampleBufferFrameSource(timebase: try clock(at: 0.35))
        source.invalidate()
        let samples = try await samples()
        samples.forEach { source.submit($0) }
        #expect(source.nextFrame(hostTime: 0) == nil)
    }
}
#endif
