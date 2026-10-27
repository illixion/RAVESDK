/*
 RAVEMedia - Still Depth Estimator

 Runs the real-time depth model over still pictures, one at a time: gallery
 thumbnails ("3D Depth"), AI 3D photos and slideshow pictures, in any app.
 Scrolling is what usually decides the load, so the queue is built for flicks
 rather than throughput:

 - Newest request first. The picture the user just stopped on is the one they
   are looking at; what scrolled in a second ago is likely gone already.
 - A cancelled request (its cell scrolled away) is dropped before it ever
   reaches the model, so a fast flick costs no inference at all.
 - One inference in flight, at utility priority, on a single provider: the
   ANE is shared with any fake-3D video playing in another window.
 - The model is released after a short idle, since a gallery that is only
   being looked at needs none of its memory.

 Thumbnail jobs use the real-time model role. `photoQuality` jobs use the
 pre-process role when available and retain floating-point normalized depth.
 Both go through the same serialized queue and idle model release.
 */

import CoreGraphics
import DebugTrace
import Foundation
import Metal
import VergenceApple

@MainActor
public final class RAVEStillDepthEstimator {
    public static let shared = RAVEStillDepthEstimator()

    /// Main-actor confined; `@unchecked` only so the cancellation handler can
    /// carry it back onto the main actor.
    private final class Job: @unchecked Sendable {
        let image: CGImage
        let photoQuality: Bool
        var continuation: CheckedContinuation<StillDepthMap?, Never>?
        init(image: CGImage, photoQuality: Bool) { self.image = image; self.photoQuality = photoQuality }

        func finish(_ map: StillDepthMap?) {
            continuation?.resume(returning: map)
            continuation = nil
        }
    }

    private var pending: [Job] = []
    private var running = false
    private let worker = Worker()
    private var modelCheck: (available: Bool, at: Date)?

    private init() {}

    /// Whether a depth model is installed. Cached briefly: every cell asks on
    /// appear, and the answer only changes when the user installs or deletes
    /// a model in Settings.
    public var isModelAvailable: Bool {
        if let modelCheck, Date().timeIntervalSince(modelCheck.at) < 5 { return modelCheck.available }
        let available = CoreMLDepthProvider.hasAvailableModel(role: .realtime)
        modelCheck = (available, Date())
        return available
    }

    /// Depth for `image`, or nil when there is no model, inference failed, or
    /// the calling task was cancelled while waiting its turn.
    public func depth(for image: CGImage, photoQuality: Bool = false) async -> StillDepthMap? {
        let job = Job(image: image, photoQuality: photoQuality)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                job.continuation = continuation
                pending.append(job)
                pump()
            }
        } onCancel: {
            Task { @MainActor in self.cancel(job) }
        }
    }

    private func cancel(_ job: Job) {
        guard let index = pending.firstIndex(where: { $0 === job }) else { return }
        pending.remove(at: index)
        job.finish(nil)
    }

    private func pump() {
        guard !running, let job = pending.popLast() else { return }
        running = true
        let image = job.image
        Task {
            let map = await worker.infer(image, photoQuality: job.photoQuality)
            job.finish(map)
            running = false
            pump()
        }
    }

    /// Owns the provider. Touched only on `queue`.
    private final class Worker: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.illixion.rave.stillDepth", qos: .utility)
        private var provider: CoreMLDepthProvider?
        private var modelName: String?
        private var generation = 0
        /// Long enough to span a pause between flicks; short enough that a
        /// gallery left on screen doesn't keep a model resident.
        private static let idleRelease: TimeInterval = 20

        func infer(_ image: CGImage, photoQuality: Bool) async -> StillDepthMap? {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: self.inferOnQueue(image, photoQuality: photoQuality))
                }
            }
        }

        private func inferOnQueue(_ image: CGImage, photoQuality: Bool) -> StillDepthMap? {
            generation += 1
            let mine = generation
            defer {
                queue.asyncAfter(deadline: .now() + Self.idleRelease) { [weak self] in
                    guard let self, self.generation == mine, self.provider != nil else { return }
                    self.provider = nil
                    self.modelName = nil
                    RAVEMediaLog.stills.debug("Still depth model released after idle")
                }
            }
            // Follow the Settings choice: a model swap takes effect on the
            // next thumbnail instead of needing a relaunch.
            let role: DepthModelRole = photoQuality && CoreMLDepthProvider.hasAvailableModel(role: .preprocess) ? .preprocess : .realtime
            guard let name = CoreMLDepthProvider.resolvedModelName(role: role) else {
                provider = nil
                modelName = nil
                return nil
            }
            if provider == nil || modelName != name {
                guard let device = MTLCreateSystemDefaultDevice() else { return nil }
                provider = nil
                let start = Date()
                provider = CoreMLDepthProvider(device: device, role: role)
                modelName = name
                RAVEMediaLog.stills.info("Still depth model loaded in \(Int(Date().timeIntervalSince(start) * 1000), privacy: .public) ms")
            }
            guard let provider else { return nil }
            let start = Date()
            let map = provider.stillDepth(for: image, preservePrecision: photoQuality)
            RAVEMediaLog.stills.debug("Still depth \(image.width, privacy: .public)x\(image.height, privacy: .public) in \(Int(Date().timeIntervalSince(start) * 1000), privacy: .public) ms")
            return map
        }
    }
}
