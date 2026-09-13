/*
 RAVEMedia - Realtime depth pipeline spike.

 On-device measurements for the lookahead-buffered realtime fake-3D design.
 Three things the offline converter has and the live path lacks — a centered
 temporal window, robust (percentile) normalization, and edge-aware refinement
 — are each blocked by a number that only the hardware can supply:

 1. **Inference time per installed model.** A live tick has one frame interval
    (16.7 ms at 60, 33 ms at 30) for inference plus everything else. Which
    models fit, and with how much headroom, is the model budget.
 2. **The offline refinement chain run live.** Luma guide + joint bilateral at
    model resolution + guided ×2 upsample, plus the min/max + histogram stats
    the percentile normalization needs. Measured as GPU time per frame from
    the command buffer's own timestamps, so it is independent of CPU
    scheduling noise.
 3. **How far ahead of the display `AVPlayerItemVideoOutput` will serve
    frames.** A centered ±N window needs N frames *ahead* of the one being
    shown. If the output's decode-ahead queue reliably holds them, the pump
    can pull ahead and audio stays untouched; if not, lookahead means delaying
    video against AVPlayer's audio and compensating — a different design.

 Everything runs off the main thread (GPU waits on the main actor starve Core
 Animation — see StereoPump). Results stream back as plain text lines so the
 host app can show them on device and copy them out; they are also logged.
 */

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore
import os

public enum DepthPipelineSpike {
    /// Frames timed per model after the warm-up.
    private static let inferenceSampleFrames = 60
    /// First inferences of a freshly loaded model include ANE compilation
    /// and cache fills; they are not the steady state a tick would see.
    private static let warmupFrames = 8
    /// Frames the refinement-chain GPU timing averages over.
    private static let refineSampleFrames = 30
    /// Lookahead probe: how long to play, and how far ahead to ask.
    private static let lookaheadProbeSeconds: Double = 6
    /// The first run's maximum lead sat right at a 1 s horizon, so the cap was
    /// the measurement. 4 s is comfortably past any plausible decode queue.
    private static let lookaheadProbeHorizonSeconds: Double = 4
    /// Decode sizes (longest side) for the inference-input experiment: the
    /// pump hands Vision the full frame today; the converter decodes at ≤1036.
    /// How much of the per-frame time is Vision rescaling the input rather
    /// than the ANE decides whether a GPU pre-downscale buys real headroom.
    private static let inputSizeVariants = [1036, 518]

    /// Run every measurement against `videoURL` (a local file — the frame
    /// decode uses AVAssetReader). Lines arrive in order, on an arbitrary
    /// thread, and the whole run is complete when this returns.
    public static func run(videoURL: URL, report: @escaping @Sendable (String) -> Void) async {
        let emit: @Sendable (String) -> Void = { line in
            RAVEMediaLog.pipeline.info("[spike] \(line, privacy: .public)")
            report(line)
        }

        guard let metal = RAVEMediaMetal.shared else {
            emit("No Metal / shader library — fake-3D is unavailable on this device, nothing to measure.")
            return
        }

        let asset = AVURLAsset(url: videoURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            emit("No video track in \(videoURL.lastPathComponent).")
            return
        }
        let naturalSize = (try? await track.load(.naturalSize)) ?? .zero
        let nominalFPS = Double((try? await track.load(.nominalFrameRate)) ?? 0)
        let fps = nominalFPS > 0 ? nominalFPS : 30
        emit("Source: \(videoURL.lastPathComponent) — \(Int(naturalSize.width))×\(Int(naturalSize.height)) @ \(format(fps)) fps")
        emit("Frame budget: \(format(1000 / fps)) ms at source rate, 16.7 ms at 60 Hz.")

        let models = DepthModelStore.installedModelURLs()
        if models.isEmpty {
            emit("No depth model installed — skipping inference and refinement timings.")
        }

        // Heavy, synchronous work on a background task: every GPU wait and
        // Core ML call below blocks the calling thread. The asset is rebuilt
        // from the URL inside the task — AVAsset/AVAssetTrack aren't Sendable.
        let modelLines = await Task.detached(priority: .userInitiated) { () -> [String] in
            let asset = AVURLAsset(url: videoURL)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
                return ["Could not reload the video track for decoding."]
            }
            var lines: [String] = []
            for modelURL in models {
                lines += measureModel(modelURL: modelURL, asset: asset, track: track, naturalSize: naturalSize, metal: metal, fps: fps)
            }
            return lines
        }.value
        modelLines.forEach(emit)

        let lookaheadLines = await measureLookahead(url: videoURL, fps: fps)
        lookaheadLines.forEach(emit)
        emit("Done.")
    }

    // MARK: - 1 + 2: inference and refinement per model

    private static func measureModel(
        modelURL: URL, asset: AVURLAsset, track: AVAssetTrack, naturalSize: CGSize, metal: RAVEMediaMetal, fps: Double
    ) -> [String] {
        let name = modelURL.deletingPathExtension().lastPathComponent
        var lines: [String] = ["", "Model: \(name)"]
        let loadStart = CACurrentMediaTime()
        guard let provider = CoreMLDepthProvider(device: metal.device, modelURL: modelURL) else {
            lines.append("  failed to load")
            return lines
        }
        lines.append("  load + compile: \(format((CACurrentMediaTime() - loadStart) * 1000)) ms")

        // Pass 1: inference only (raw map, no stabilization) — the ANE cost.
        var inferMs: [Double] = []
        var depthSize = (width: 0, height: 0)
        var refine: RefineChain?
        var refineGPUMs: [Double] = []
        var refine1xGPUMs: [Double] = []
        var statsWallMs: [Double] = []
        var frameIndex = 0
        let ok = forEachFrame(asset: asset, track: track, limit: warmupFrames + inferenceSampleFrames) { pixelBuffer in
            defer { frameIndex += 1 }
            let t0 = CACurrentMediaTime()
            guard let (raw, keepAlive) = provider.inferRawDepth(from: pixelBuffer) else { return }
            let t1 = CACurrentMediaTime()
            if frameIndex >= warmupFrames { inferMs.append((t1 - t0) * 1000) }
            depthSize = (raw.width, raw.height)

            // Refinement chain on this frame's raw depth, while the transient
            // texture is still alive.
            if refine == nil {
                refine = RefineChain(
                    metal: metal, depthWidth: raw.width, depthHeight: raw.height,
                    videoWidth: CVPixelBufferGetWidth(pixelBuffer), videoHeight: CVPixelBufferGetHeight(pixelBuffer)
                )
            }
            if let refine, frameIndex >= warmupFrames, refineGPUMs.count < refineSampleFrames {
                if let gpu = refine.timeRefine(raw: raw, video: pixelBuffer, upsample: true) { refineGPUMs.append(gpu * 1000) }
                if let gpu = refine.timeRefine(raw: raw, video: pixelBuffer, upsample: false) { refine1xGPUMs.append(gpu * 1000) }
                let s0 = CACurrentMediaTime()
                if refine.robustRange(raw: raw) != nil { statsWallMs.append((CACurrentMediaTime() - s0) * 1000) }
            }
            withExtendedLifetime(keepAlive) {}
        }
        guard ok else {
            lines.append("  could not decode the source")
            return lines
        }
        lines.append("  depth map: \(depthSize.width)×\(depthSize.height)")
        lines.append("  inference (raw, ANE): \(summary(inferMs))")

        // Pass 2: the shipping realtime call — inference + gaussian stabilize.
        var fullMs: [Double] = []
        frameIndex = 0
        _ = forEachFrame(asset: asset, track: track, limit: warmupFrames + inferenceSampleFrames) { pixelBuffer in
            defer { frameIndex += 1 }
            let t0 = CACurrentMediaTime()
            guard provider.depth(for: pixelBuffer) != nil else { return }
            if frameIndex >= warmupFrames { fullMs.append((CACurrentMediaTime() - t0) * 1000) }
        }
        lines.append("  inference + stabilize (shipping live path): \(summary(fullMs))")

        // Pass 3: raw inference again, with the frame decoded smaller before
        // Vision sees it. The difference against pass 1 is Vision's own
        // rescale cost — the part a GPU pre-downscale in the pump could remove.
        for maxDimension in inputSizeVariants where CGFloat(maxDimension) < max(naturalSize.width, naturalSize.height) {
            var sizedMs: [Double] = []
            var decodedSize = (width: 0, height: 0)
            frameIndex = 0
            _ = forEachFrame(
                asset: asset, track: track, limit: warmupFrames + inferenceSampleFrames,
                maxDimension: maxDimension, naturalSize: naturalSize
            ) { pixelBuffer in
                defer { frameIndex += 1 }
                decodedSize = (CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
                let t0 = CACurrentMediaTime()
                guard let (_, keepAlive) = provider.inferRawDepth(from: pixelBuffer) else { return }
                if frameIndex >= warmupFrames { sizedMs.append((CACurrentMediaTime() - t0) * 1000) }
                withExtendedLifetime(keepAlive) {}
            }
            lines.append("  inference (raw) with input decoded at \(decodedSize.width)×\(decodedSize.height): \(summary(sizedMs))")
        }

        lines.append("  offline refine chain, GPU time (guide + joint bilateral r12 + guided ×2 upsample r6): \(summary(refineGPUMs))")
        lines.append("  same chain without the ×2 upsample: \(summary(refine1xGPUMs))")
        lines.append("  robust range (min/max reduce + 256-bin histogram + CPU percentile), wall: \(summary(statsWallMs))")

        if let medianInfer = median(fullMs), let medianRefine = median(refineGPUMs) {
            let budget60 = 1000.0 / 60
            let budgetSource = 1000.0 / fps
            let live = medianInfer + medianRefine
            let verdict: String
            if live < budget60 * 0.8 {
                verdict = "fits 60 Hz with headroom"
            } else if live < budgetSource * 0.8 {
                verdict = "fits the source rate (\(format(fps)) fps), not 60 Hz"
            } else if live < budgetSource {
                verdict = "marginal at the source rate — no headroom for the warp"
            } else {
                verdict = "too slow for live use — pre-process only"
            }
            lines.append("  live estimate (inference+stabilize + refine): \(format(live)) ms → \(verdict)")
        }
        return lines
    }

    /// Decode frames from the start of the track as 32BGRA Metal-compatible
    /// buffers, exactly as the pump receives them, and hand each to `body`.
    /// Returns false if the reader could not be set up.
    private static func forEachFrame(
        asset: AVURLAsset, track: AVAssetTrack, limit: Int, maxDimension: Int? = nil,
        naturalSize: CGSize = .zero, body: (CVPixelBuffer) -> Void
    ) -> Bool {
        guard let reader = try? AVAssetReader(asset: asset) else { return false }
        var settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        if let maxDimension, naturalSize.width > 0, naturalSize.height > 0 {
            // Same downscale-at-decode the converter uses (aspect-preserving,
            // never upscaled, even dimensions).
            let scale = min(1, CGFloat(maxDimension) / max(naturalSize.width, naturalSize.height))
            settings[kCVPixelBufferWidthKey as String] = Int(naturalSize.width * scale) & ~1
            settings[kCVPixelBufferHeightKey as String] = Int(naturalSize.height * scale) & ~1
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        guard reader.startReading() else { return false }
        var count = 0
        while count < limit, let sample = output.copyNextSampleBuffer() {
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
                body(pixelBuffer)
                count += 1
            }
        }
        reader.cancelReading()
        return count > 0
    }

    /// The converter's `refine` and stats passes, rebuilt here so they can be
    /// timed per frame on a live-shaped input. Same kernels, same constants.
    private final class RefineChain {
        private let device: MTLDevice
        private let commandQueue: MTLCommandQueue
        private let guidePipeline: MTLComputePipelineState
        private let bilateralH: MTLComputePipelineState
        private let bilateralV: MTLComputePipelineState
        private let minMaxPipeline: MTLComputePipelineState
        private let histogramPipeline: MTLComputePipelineState
        private let textureCache: CVMetalTextureCache
        private let depthWidth: Int
        private let depthHeight: Int
        private let guideTex: MTLTexture
        private let hiGuideTex: MTLTexture
        private let scratch: MTLTexture
        private let midTex: MTLTexture
        private let hiScratch: MTLTexture
        private let hiDest: MTLTexture
        private let partials: MTLBuffer
        private let partialsCount: Int
        private let bins: MTLBuffer
        private var guideParams: DepthGuideParams

        init?(metal: RAVEMediaMetal, depthWidth: Int, depthHeight: Int, videoWidth: Int, videoHeight: Int) {
            guard let queue = metal.device.makeCommandQueue(),
                  let guide = metal.computePipeline("depthGuideLuma"),
                  let bH = metal.computePipeline("depthJointBilateralH"),
                  let bV = metal.computePipeline("depthJointBilateralV"),
                  let minMax = metal.computePipeline("depthMinMaxReduce"),
                  let histogram = metal.computePipeline("depthHistogram256") else { return nil }
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(nil, nil, metal.device, nil, &cache)
            guard let cache else { return nil }

            func makeTex(_ w: Int, _ h: Int) -> MTLTexture? {
                let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: w, height: h, mipmapped: false)
                desc.usage = [.shaderRead, .shaderWrite]
                desc.storageMode = .private
                return metal.device.makeTexture(descriptor: desc)
            }
            let hiW = depthWidth * DepthConverter.encodeUpsampleFactor
            let hiH = depthHeight * DepthConverter.encodeUpsampleFactor
            let groups = ((depthWidth + 15) / 16) * ((depthHeight + 15) / 16)
            guard let guideTex = makeTex(depthWidth, depthHeight),
                  let hiGuideTex = makeTex(hiW, hiH),
                  let scratch = makeTex(depthWidth, depthHeight),
                  let midTex = makeTex(depthWidth, depthHeight),
                  let hiScratch = makeTex(hiW, hiH),
                  let hiDest = makeTex(hiW, hiH),
                  let partials = metal.device.makeBuffer(length: groups * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared),
                  let bins = metal.device.makeBuffer(length: 256 * MemoryLayout<UInt32>.stride, options: .storageModeShared) else {
                return nil
            }
            self.device = metal.device
            self.commandQueue = queue
            self.guidePipeline = guide
            self.bilateralH = bH
            self.bilateralV = bV
            self.minMaxPipeline = minMax
            self.histogramPipeline = histogram
            self.textureCache = cache
            self.depthWidth = depthWidth
            self.depthHeight = depthHeight
            self.guideTex = guideTex
            self.hiGuideTex = hiGuideTex
            self.scratch = scratch
            self.midTex = midTex
            self.hiScratch = hiScratch
            self.hiDest = hiDest
            self.partials = partials
            self.partialsCount = groups
            self.bins = bins
            let uv = CoreMLDepthProvider.letterboxUVTransform(
                videoWidth: videoWidth, videoHeight: videoHeight, depthWidth: depthWidth, depthHeight: depthHeight
            )
            self.guideParams = DepthGuideParams(uvScale: uv.scale, uvOffset: uv.offset)
        }

        /// GPU seconds for one refinement of `raw`, from the command buffer's
        /// own GPU timestamps. Mirrors `DepthConverter.PostStage.refine`.
        func timeRefine(raw: MTLTexture, video: CVPixelBuffer, upsample: Bool) -> Double? {
            var cvVideoTexture: CVMetalTexture?
            let videoWidth = CVPixelBufferGetWidth(video)
            let videoHeight = CVPixelBufferGetHeight(video)
            guard CVMetalTextureCacheCreateTextureFromImage(
                nil, textureCache, video, nil, .bgra8Unorm, videoWidth, videoHeight, 0, &cvVideoTexture
            ) == kCVReturnSuccess, let cvVideoTexture, let videoTex = CVMetalTextureGetTexture(cvVideoTexture),
                  let cmd = commandQueue.makeCommandBuffer(),
                  let enc = cmd.makeComputeCommandEncoder() else { return nil }

            var params = DepthStabilizeParams(
                blurRadius: DepthConverter.bilateralRadius, blurSigma: DepthConverter.bilateralSigmaSpatial,
                baseAlpha: 1, motionGain: 0, hasPrev: 0, sigmaLuma: DepthConverter.bilateralSigmaLuma
            )
            var upsampleParams = DepthStabilizeParams(
                blurRadius: DepthConverter.upsampleRadius, blurSigma: DepthConverter.upsampleSigmaSpatial,
                baseAlpha: 1, motionGain: 0, hasPrev: 0, sigmaLuma: DepthConverter.bilateralSigmaLuma
            )

            enc.setComputePipelineState(guidePipeline)
            enc.setTexture(videoTex, index: 0)
            enc.setTexture(guideTex, index: 1)
            enc.setBytes(&guideParams, length: MemoryLayout<DepthGuideParams>.stride, index: 0)
            dispatch2D(enc, width: depthWidth, height: depthHeight)
            if upsample {
                enc.setTexture(hiGuideTex, index: 1)
                dispatch2D(enc, width: hiGuideTex.width, height: hiGuideTex.height)
            }

            enc.setComputePipelineState(bilateralH)
            enc.setTexture(raw, index: 0)
            enc.setTexture(guideTex, index: 1)
            enc.setTexture(scratch, index: 2)
            enc.setBytes(&params, length: MemoryLayout<DepthStabilizeParams>.stride, index: 0)
            dispatch2D(enc, width: depthWidth, height: depthHeight)

            enc.setComputePipelineState(bilateralV)
            enc.setTexture(scratch, index: 0)
            enc.setTexture(guideTex, index: 1)
            enc.setTexture(midTex, index: 2)
            enc.setBytes(&params, length: MemoryLayout<DepthStabilizeParams>.stride, index: 0)
            dispatch2D(enc, width: depthWidth, height: depthHeight)

            if upsample {
                enc.setComputePipelineState(bilateralH)
                enc.setTexture(midTex, index: 0)
                enc.setTexture(hiGuideTex, index: 1)
                enc.setTexture(hiScratch, index: 2)
                enc.setBytes(&upsampleParams, length: MemoryLayout<DepthStabilizeParams>.stride, index: 0)
                dispatch2D(enc, width: hiDest.width, height: hiDest.height)

                enc.setComputePipelineState(bilateralV)
                enc.setTexture(hiScratch, index: 0)
                enc.setTexture(hiGuideTex, index: 1)
                enc.setTexture(hiDest, index: 2)
                enc.setBytes(&upsampleParams, length: MemoryLayout<DepthStabilizeParams>.stride, index: 0)
                dispatch2D(enc, width: hiDest.width, height: hiDest.height)
            }
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            withExtendedLifetime(cvVideoTexture) {}
            guard cmd.status == .completed else { return nil }
            return cmd.gpuEndTime - cmd.gpuStartTime
        }

        /// The converter's per-frame robust range (p2–p98): GPU min/max
        /// reduce, CPU fold, GPU histogram, CPU percentile. Two round trips,
        /// which is why the caller times it as wall time.
        func robustRange(raw: MTLTexture) -> (lo: Float, hi: Float)? {
            guard let cmd = commandQueue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { return nil }
            enc.setComputePipelineState(minMaxPipeline)
            enc.setTexture(raw, index: 0)
            enc.setBuffer(partials, offset: 0, index: 0)
            dispatch2D(enc, width: raw.width, height: raw.height)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            var lo = Float.infinity, hi = -Float.infinity
            let ptr = partials.contents().bindMemory(to: SIMD2<Float>.self, capacity: partialsCount)
            for i in 0..<partialsCount {
                lo = min(lo, ptr[i].x)
                hi = max(hi, ptr[i].y)
            }
            guard lo.isFinite, hi.isFinite else { return nil }

            memset(bins.contents(), 0, 256 * MemoryLayout<UInt32>.stride)
            var hp = HistogramParams(lo: lo, invSpan: 1 / max(hi - lo, 1e-6))
            guard let cmd2 = commandQueue.makeCommandBuffer(), let enc2 = cmd2.makeComputeCommandEncoder() else { return nil }
            enc2.setComputePipelineState(histogramPipeline)
            enc2.setTexture(raw, index: 0)
            enc2.setBuffer(bins, offset: 0, index: 0)
            enc2.setBytes(&hp, length: MemoryLayout<HistogramParams>.stride, index: 1)
            dispatch2D(enc2, width: raw.width, height: raw.height)
            enc2.endEncoding()
            cmd2.commit()
            cmd2.waitUntilCompleted()
            let binPtr = bins.contents().bindMemory(to: UInt32.self, capacity: 256)
            let counts = Array(UnsafeBufferPointer(start: binPtr, count: 256))
            let total = raw.width * raw.height
            let p02 = DepthHistogram.percentile(counts, total: total, q: 0.02, lo: lo, hi: hi)
            let p98 = DepthHistogram.percentile(counts, total: total, q: 0.98, lo: lo, hi: hi)
            return (p02, p98)
        }

        /// CPU mirror of the Metal `DepthHistogramParams` (the converter keeps
        /// its own copy private to its file).
        private struct HistogramParams {
            var lo: Float
            var invSpan: Float
        }

        private func dispatch2D(_ encoder: MTLComputeCommandEncoder, width: Int, height: Int) {
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let groups = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        }
    }

    // MARK: - 3: AVPlayerItemVideoOutput decode-ahead

    /// Play the file muted through an `AVPlayer` with a video output — the
    /// engine's exact setup — and, at 60 Hz, ask the output for the newest
    /// frame up to a second *ahead* of the current item time. The display time
    /// it hands back, minus the current item time, is how far the output's
    /// decode-ahead queue extends. Pulling those frames is what a lookahead
    /// pump would do, so the measured lead is the lead such a pump would get.
    private static func measureLookahead(url: URL, fps: Double) async -> [String] {
        var lines = ["", "AVPlayerItemVideoOutput decode-ahead"]
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = true
        player.play()

        // Wait for the host-time mapping to become valid (the player is
        // actually running), bounded.
        let deadline = CACurrentMediaTime() + 8
        while CACurrentMediaTime() < deadline {
            let t = output.itemTime(forHostTime: CACurrentMediaTime())
            if t.isValid, player.rate > 0, t.seconds > 0.05 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard output.itemTime(forHostTime: CACurrentMediaTime()).isValid else {
            player.pause()
            lines.append("  player never started (no valid item time within 8 s)")
            return lines
        }

        let horizon = CMTime(seconds: lookaheadProbeHorizonSeconds, preferredTimescale: 600)
        var leads: [Double] = []
        var emptyTicks = 0
        var ticks = 0
        let end = CACurrentMediaTime() + lookaheadProbeSeconds
        while CACurrentMediaTime() < end {
            ticks += 1
            let host = CACurrentMediaTime()
            let now = output.itemTime(forHostTime: host)
            if now.isValid, output.hasNewPixelBuffer(forItemTime: now + horizon) {
                var display = CMTime.invalid
                if output.copyPixelBuffer(forItemTime: now + horizon, itemTimeForDisplay: &display) != nil, display.isValid {
                    leads.append((display - now).seconds * fps)
                }
            } else {
                emptyTicks += 1
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        player.pause()

        guard !leads.isEmpty else {
            lines.append("  the output never had a frame newer than the last vended one (\(ticks) ticks)")
            return lines
        }
        let sorted = leads.sorted()
        func share(_ threshold: Double) -> String {
            let n = leads.filter { $0 >= threshold }.count
            return "\(Int((Double(n) / Double(leads.count) * 100).rounded()))%"
        }
        lines.append("  ticks: \(ticks), frames pulled: \(leads.count), ticks with nothing new: \(emptyTicks)")
        lines.append("  lead ahead of now, in source frames: p10 \(format(percentile(sorted, 0.10))), median \(format(percentile(sorted, 0.5))), p90 \(format(percentile(sorted, 0.9))), max \(format(sorted.last ?? 0))")
        lines.append("  frames with lead ≥1: \(share(1)), ≥2: \(share(2)), ≥3: \(share(3)), ≥4: \(share(4))")
        lines.append("  median lead in seconds: \(format(percentile(sorted, 0.5) / fps)) (probe horizon \(format(lookaheadProbeHorizonSeconds)) s)")
        if (sorted.last ?? 0) >= lookaheadProbeHorizonSeconds * fps * 0.95 {
            lines.append("  note: max lead reached the probe horizon — the real queue may be deeper")
        }
        let p10 = percentile(sorted, 0.10)
        if p10 >= 2 {
            lines.append("  → the output sustains ≥2 frames of decode-ahead: a ±2 centered window can pull ahead and leave audio alone")
        } else if p10 >= 1 {
            lines.append("  → only ~1 frame of decode-ahead is reliable: a ±1 window fits; ±2 needs a presentation delay + audio compensation")
        } else {
            lines.append("  → no reliable decode-ahead: lookahead must delay presentation and compensate audio (tap delay), or decode separately")
        }
        return lines
    }

    // MARK: - Formatting

    private static func summary(_ samples: [Double]) -> String {
        guard !samples.isEmpty else { return "no samples" }
        let sorted = samples.sorted()
        return "median \(format(percentile(sorted, 0.5))) ms, p95 \(format(percentile(sorted, 0.95))) ms, max \(format(sorted.last ?? 0)) ms (n=\(samples.count))"
    }

    private static func median(_ samples: [Double]) -> Double? {
        guard !samples.isEmpty else { return nil }
        return percentile(samples.sorted(), 0.5)
    }

    /// Nearest-rank percentile over an ascending array.
    private static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * q).rounded(.up)) - 1))
        return sorted[index]
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
