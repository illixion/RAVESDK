import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// One decoded frame on its way to the warp.
public struct PumpFrame {
    public let pixelBuffer: CVPixelBuffer
    /// Presentation time on the *source's* own timeline — what a cached depth
    /// source matches its baked depth against, and what a realtime source uses
    /// to decide whether a held map may be reused. Not the renderer timeline.
    public let itemTime: CMTime

    public init(pixelBuffer: CVPixelBuffer, itemTime: CMTime) {
        self.pixelBuffer = pixelBuffer
        self.itemTime = itemTime
    }
}

/// Where `StereoPump` gets frames. Called only on the pump queue (including
/// `invalidate`, from the stop-drain block), at the pump's tick rate.
///
/// The two implementations differ in kind, which is why this is a protocol and
/// not a parameter: a pull source is asked for the frame matching *now* and
/// answers nil when nothing new has decoded, while a push source hands over
/// whatever its decoder most recently deposited. Both must return nil rather
/// than repeat a frame the pump has already seen — a tick that re-warps the
/// same frame costs a full GPU pass and enqueues a duplicate.
///
/// **Frames must be `kCVPixelFormatType_32BGRA` and Metal-compatible.** The pump
/// binds plane 0 as one `.bgra8Unorm` texture, so a 4:2:0 buffer does not fail —
/// it renders, with each texel eating four luma bytes, which comes out as four
/// side-by-side greyscale copies of the frame at a quarter width each. Configure
/// `AVPlayerItemVideoOutput` or the `VTDecompressionSession` accordingly;
/// `makeTexture` logs the format once if it sees anything else.
public protocol PumpFrameSource: AnyObject, Sendable {
    /// The newest not-yet-delivered frame, or nil if none is ready.
    /// - Parameter hostTime: the pump's `CACurrentMediaTime()` for this tick, so
    ///   a source driven by a host-synchronised clock (AVPlayer) can map it onto
    ///   its own timeline. Push sources ignore it.
    func nextFrame(hostTime: CFTimeInterval) -> PumpFrame?
    /// Release decode resources; the pump is shutting down.
    func invalidate()
}

/// Pulls from an `AVPlayerItemVideoOutput` — the original Spatial Stash path,
/// where AVPlayer stays the clock, the audio source and the transport, and only
/// pixels are diverted.
public final class AVPlayerFrameSource: PumpFrameSource, @unchecked Sendable {
    private let output: AVPlayerItemVideoOutput

    public init(output: AVPlayerItemVideoOutput) {
        self.output = output
    }

    public func nextFrame(hostTime: CFTimeInterval) -> PumpFrame? {
        let itemTime = output.itemTime(forHostTime: hostTime)
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else {
            return nil
        }
        return PumpFrame(pixelBuffer: buffer, itemTime: itemTime)
    }

    public func invalidate() {}
}

