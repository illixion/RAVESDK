/*
 RAVEMedia - StereoTestPatternPump (diagnostic).

 Bypasses decode and warp entirely so the windowed-stereo plumbing can be
 proven on its own. Enabled by `Pseudo3DDiagnostics.useStaticTestPattern`.
 */

#if os(visionOS)

import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore

/// Feeds the renderer a static stereo test pattern — a bright vertical bar with
/// horizontal disparity over a dark background, so it should appear to float in
/// front of the window when stereo delivery works. Buffer construction mirrors
/// Apple's "Rendering stereoscopic video with RealityKit" sample exactly (420v
/// from a `CVMutablePixelBuffer.Pool` merged with `recommendedPixelBufferAttributes`,
/// `CMTaggedBufferGroupFormatDescription`, pull-model enqueue) to validate the
/// windowed-stereo plumbing without our decode/warp in the loop.
/// `@unchecked Sendable`: all state is touched only on `queue`.
public final class StereoTestPatternPump: @unchecked Sendable {
    private let videoRenderer: AVSampleBufferVideoRenderer
    private let queue = DispatchQueue(label: "com.illixion.ravemedia.stereo-testpattern", qos: .userInteractive)
    private let width = 1280
    private let height = 720
    /// Half-frame disparity of the bar between eyes (px). Bigger = more depth.
    private let barShift = 16
    private var pool: CVMutablePixelBuffer.Pool?
    private var frameIndex: Int64 = 0
    private var running = false

    public init(videoRenderer: AVSampleBufferVideoRenderer) {
        self.videoRenderer = videoRenderer
    }

    public func start() {
        let eyeSize = CVImageSize(width: width, height: height)
        let defaultAttributes = CVPixelBufferCreationAttributes(
            pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            size: eyeSize
        )
        let recommended = videoRenderer.recommendedPixelBufferAttributes
        guard let merged = CVPixelBufferAttributes(merging: [CVPixelBufferAttributes(defaultAttributes), recommended]),
              let creation = CVPixelBufferCreationAttributes(merged),
              let pool = try? CVMutablePixelBuffer.Pool(pixelBufferAttributes: creation) else {
            return
        }
        self.pool = pool
        running = true
        videoRenderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            self?.pump()
        }
    }

    public func stop() {
        running = false
        videoRenderer.stopRequestingMediaData()
        pool = nil
    }

    private func pump() {
        guard running, let pool else { return }
        while running, videoRenderer.isReadyForMoreMediaData {
            guard enqueueFrame(pool: pool) else { break }
            frameIndex += 1
        }
    }

    private func enqueueFrame(pool: CVMutablePixelBuffer.Pool) -> Bool {
        // Left eye sees the bar shifted right, right eye shifted left → crossed
        // disparity → bar floats in front of the background.
        guard let left = makeEyeBuffer(pool: pool, barShift: barShift),
              let right = makeEyeBuffer(pool: pool, barShift: -barShift) else { return false }
        let leftTags: [CMTag] = [.videoLayerID(0), .stereoView(.leftEye), .mediaType(.video)]
        let rightTags: [CMTag] = [.videoLayerID(1), .stereoView(.rightEye), .mediaType(.video)]
        let tagged: [CMTaggedDynamicBuffer] = [
            CMTaggedDynamicBuffer(tags: leftTags, content: .pixelBuffer(CVReadOnlyPixelBuffer(left))),
            CMTaggedDynamicBuffer(tags: rightTags, content: .pixelBuffer(CVReadOnlyPixelBuffer(right)))
        ]
        let pts = CMTime(value: frameIndex, timescale: 30)
        let sample = CMReadySampleBuffer(
            taggedBuffers: tagged,
            formatDescription: CMTaggedBufferGroupFormatDescription(taggedBuffers: tagged),
            presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: 30)
        )
        sample.withUnsafeSampleBuffer { videoRenderer.enqueue($0) }
        return true
    }

    /// Fills a fresh 420v buffer: dark background (Y=40), a bright vertical bar
    /// (Y=200) centered at `width/2 + barShift`, neutral chroma (grayscale).
    private func makeEyeBuffer(pool: CVMutablePixelBuffer.Pool, barShift: Int) -> CVMutablePixelBuffer? {
        guard let pb = try? pool.makeMutablePixelBuffer() else { return nil }
        pb.withUnsafeBuffer { cv in
            CVPixelBufferLockBaseAddress(cv, [])
            defer { CVPixelBufferUnlockBaseAddress(cv, []) }

            let w = CVPixelBufferGetWidthOfPlane(cv, 0)
            let h = CVPixelBufferGetHeightOfPlane(cv, 0)
            let cx = w / 2 + barShift
            let barHalf = max(8, w / 14)
            if let yBase = CVPixelBufferGetBaseAddressOfPlane(cv, 0) {
                let y = yBase.assumingMemoryBound(to: UInt8.self)
                let bpr = CVPixelBufferGetBytesPerRowOfPlane(cv, 0)
                for row in 0..<h {
                    let r = y + row * bpr
                    for col in 0..<w {
                        r[col] = abs(col - cx) < barHalf ? 200 : 40
                    }
                }
            }
            // Neutral chroma (Cb=Cr=128) → grayscale.
            if let cBase = CVPixelBufferGetBaseAddressOfPlane(cv, 1) {
                let bpr = CVPixelBufferGetBytesPerRowOfPlane(cv, 1)
                let ch = CVPixelBufferGetHeightOfPlane(cv, 1)
                memset(cBase, 128, bpr * ch)
            }
        }
        return pb
    }
}

#endif
