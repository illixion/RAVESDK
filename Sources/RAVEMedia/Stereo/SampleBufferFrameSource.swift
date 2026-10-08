#if os(visionOS) || os(macOS)
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// A clocked compressed-video tap. The host keeps its transport and audio;
/// this source only decodes pictures for the stereo pump, in DTS order, just
/// ahead of the host's playhead. Compressed samples may be prefetched, but
/// decoded frames are never an unbounded queue of future pictures.
/// All VideoToolbox work runs on the pump queue. Submission/reset can run on
/// the host actor; a generation prevents callbacks from a previous seek from
/// leaking into the new timeline. BGRA is required by PumpFrameSource.
/// A sample that already holds a picture (a host that decodes on its own,
/// such as frame-packed MVC) is converted to BGRA rather than decoded.
public final class SampleBufferFrameSource: PumpFrameSource, @unchecked Sendable {
    private let timebase: CMTimebase
    private let lock = NSLock()
    private var samples: [CMSampleBuffer] = []
    private var frames: [PumpFrame] = []
    private var generation = 0
    private var invalidated = false
    private var failure: OSStatus?
    // Accessed only by the pump queue.
    private var session: VTDecompressionSession?
    private var decoderGeneration = -1
    private var lastDelivered = CMTime.invalid
    /// The session was taken away (another app's immersive space, the app
    /// backgrounded): a new one starts at the next keyframe, since the frames
    /// in between reference pictures the old one held. Pump queue only.
    private var awaitingKeyframe = false
    /// Converts decoded samples to BGRA. Pump queue only.
    private var transfer: VTPixelTransferSession?
    private var transferPool: CVPixelBufferPool?
    private var transferPoolSize = (width: 0, height: 0)

    public init(timebase: CMTimebase) { self.timebase = timebase }

    public var decodeFailure: OSStatus? {
        lock.lock(); defer { lock.unlock() }
        return failure
    }

    public func submit(_ sample: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated else { return }
        samples.append(sample)
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        samples.removeAll()
        frames.removeAll()
        failure = nil
    }

    public func nextFrame(hostTime: CFTimeInterval) -> PumpFrame? {
        let now = CMTimebaseGetTime(timebase)
        // Enough decode-order lookahead for B-frame reordering. Future
        // pictures remain queued by PTS; none is shown before its film time.
        let decodeThrough = now.seconds + 0.1
        lock.lock()
        guard !invalidated else { lock.unlock(); return nil }
        let currentGeneration = generation
        var due: [CMSampleBuffer] = []
        while let first = samples.first {
            let dts = CMSampleBufferGetDecodeTimeStamp(first)
            let pts = CMSampleBufferGetPresentationTimeStamp(first)
            let decodeTime = dts.isValid ? dts.seconds : pts.seconds
            guard decodeTime <= decodeThrough else { break }
            due.append(samples.removeFirst())
        }
        lock.unlock()

        if decoderGeneration != currentGeneration {
            session.map { VTDecompressionSessionInvalidate($0) }
            session = nil
            decoderGeneration = currentGeneration
            lastDelivered = .invalid
            awaitingKeyframe = false
        }
        for sample in due {
            if let image = CMSampleBufferGetImageBuffer(sample) {
                if let converted = bgra(image) {
                    lock.lock()
                    if generation == currentGeneration, !invalidated {
                        frames.append(PumpFrame(pixelBuffer: converted, itemTime: CMSampleBufferGetPresentationTimeStamp(sample)))
                    }
                    lock.unlock()
                }
                continue
            }
            guard let format = CMSampleBufferGetFormatDescription(sample) else { continue }
            if awaitingKeyframe {
                guard Self.isKeyframe(sample) else { continue }
                awaitingKeyframe = false
            }
            if session == nil {
                let attributes: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                ]
                var created: VTDecompressionSession?
                let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                    formatDescription: format, decoderSpecification: nil,
                    imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                    decompressionSessionOut: &created)
                guard status == noErr, let created else {
                    // Decoding taken away right now: try again at a keyframe.
                    if status == kVTInvalidSessionErr { awaitingKeyframe = true; continue }
                    recordFailure(status, generation: currentGeneration)
                    return nil
                }
                session = created
            }
            guard let session else { continue }
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
                flags: [], infoFlagsOut: nil) { [weak self] status, _, buffer, pts, _ in
                    guard let self else { return }
                    self.lock.lock(); defer { self.lock.unlock() }
                    guard !self.invalidated, self.generation == currentGeneration else { return }
                    // A session lost mid-frame is recovered on the pump side.
                    if status == kVTInvalidSessionErr { return }
                    if status != noErr { self.failure = status; return }
                    if let buffer { self.frames.append(PumpFrame(pixelBuffer: buffer, itemTime: pts)) }
                }
            if status == kVTInvalidSessionErr {
                VTDecompressionSessionInvalidate(session)
                self.session = nil
                awaitingKeyframe = true
                RAVEMediaLog.pipeline.notice("stereo tap decoder lost; restarting at the next keyframe")
            } else if status != noErr {
                recordFailure(status, generation: currentGeneration)
            }
        }
        lock.lock(); defer { lock.unlock() }
        guard generation == currentGeneration, !invalidated else { return nil }
        frames.sort { $0.itemTime < $1.itemTime }
        let eligible = frames.last { $0.itemTime <= now }
        frames.removeAll { $0.itemTime <= now }
        guard let eligible, eligible.itemTime != lastDelivered else { return nil }
        lastDelivered = eligible.itemTime
        return eligible
    }

    /// `image` as BGRA, through a pixel transfer when it isn't already.
    private func bgra(_ image: CVPixelBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA { return image }
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        if transferPool == nil || transferPoolSize != (width, height) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            transferPool = nil
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &transferPool)
            transferPoolSize = (width, height)
        }
        if transfer == nil {
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)
        }
        guard let transferPool, let transfer else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, transferPool, &out) == kCVReturnSuccess, let out,
              VTPixelTransferSessionTransferImage(transfer, from: image, to: out) == noErr else { return nil }
        return out
    }

    private static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[CFString: Any]], let first = attachments.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    private func recordFailure(_ status: OSStatus, generation: Int) {
        lock.lock(); defer { lock.unlock() }
        if self.generation == generation { failure = status }
    }

    /// Called on the pump queue after its last tick; never races a decode.
    public func invalidate() {
        lock.lock()
        invalidated = true
        samples.removeAll()
        frames.removeAll()
        lock.unlock()
        session.map { VTDecompressionSessionInvalidate($0) }
        session = nil
        transfer.map { VTPixelTransferSessionInvalidate($0) }
        transfer = nil
    }
}
#endif
