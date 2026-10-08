/*
 RAVEMedia - GPU side of depth anchoring, and the realtime refiner built on it.

 `DepthAnchorGPU` encodes the anchor reduction (`depthAnchorReduce`: the sums a
 `DepthAlignmentSums` fit needs, the frame's min/max and its luma change) and
 folds the partials on the CPU. The converter uses it between consecutive
 refined maps; `RealtimeDepthRefiner` adds the rest of the realtime chain.

 Realtime chain per inference (two command buffers, both waited on the pump
 queue like the old stabilize pass):
   1. luma guide → joint bilateral H/V (edge refinement, replaces the plain
      gaussian) → anchor reduce against the previous frame → min/max fold →
      256-bin histogram over that range.
   2. CPU: p2/p98, cut test, anchor fit, `DepthScaleShiftTracker`.
   3. `depthAnchorApply`: shot-space depth with the motion-adaptive EMA.
 The result is unbounded shot-space depth; the warp applies the depth budget.
 */

import CoreMedia
import CoreVideo
import Metal

/// CPU mirror of the Metal `DepthAnchorReduceParams`.
struct DepthAnchorReduceParams {
    var staticLuma: Float
    var hasPrev: UInt32
    var ceiling: Float
    var ceilingSoftness: Float
}

/// CPU mirror of the Metal `DepthAnchorApplyParams`.
struct DepthAnchorApplyParams {
    var a: Float
    var b: Float
    var baseAlpha: Float
    var motionGain: Float
    var hasPrev: UInt32
    var staticLuma: Float
    var staticAlpha: Float
}

/// The previous frame's background layer, in its own units: pixels it put
/// nearer than `ceiling` don't anchor the next fit.
struct DepthAnchorCeiling {
    var ceiling: Float
    var softness: Float

    static let none = DepthAnchorCeiling(ceiling: .greatestFiniteMagnitude, softness: 1)

    /// Everything the frame's shot-space `mapping` put farther than
    /// `DepthAlignmentSums.anchorCeiling`, with an edge 0.05 of shot space wide.
    init(mapping: DepthAffine) {
        guard let inverse = mapping.inverse else {
            self = .none
            return
        }
        ceiling = inverse(DepthAlignmentSums.anchorCeiling)
        softness = 0.05 / mapping.a
    }

    init(ceiling: Float, softness: Float) {
        self.ceiling = ceiling
        self.softness = softness
    }
}

/// What one anchor reduction says about a frame.
struct DepthAnchorStats {
    var sums: DepthAlignmentSums
    /// Mean absolute luma change against the previous frame (nil without one).
    var meanLumaDelta: Float?
    var min: Float
    var max: Float
}

final class DepthAnchorGPU {
    /// Floats per threadgroup partial; matches `depthAnchorPartialStride`.
    static let partialStride = 9

    let reducePipeline: MTLComputePipelineState
    let foldPipeline: MTLComputePipelineState
    let histogramPipeline: MTLComputePipelineState
    let applyPipeline: MTLComputePipelineState
    private let device: MTLDevice
    private(set) var partials: MTLBuffer?
    private var partialsCapacity = 0

    init?(metal: RAVEMediaMetal) {
        guard let reduce = metal.computePipeline("depthAnchorReduce"),
              let fold = metal.computePipeline("depthAnchorFoldRange"),
              let histogram = metal.computePipeline("depthHistogram256Ranged"),
              let apply = metal.computePipeline("depthAnchorApply") else { return nil }
        device = metal.device
        reducePipeline = reduce
        foldPipeline = fold
        histogramPipeline = histogram
        applyPipeline = apply
    }

    static func groups(width: Int, height: Int) -> (x: Int, y: Int) {
        ((width + 15) / 16, (height + 15) / 16)
    }

    /// Encode the reduction of `depth` against `depthPrev` (nil: first frame
    /// after a reset — only min/max are meaningful). All four textures share
    /// the depth map's size. `background` is the previous frame's background
    /// layer: its anchor ceiling and the softness of that edge, in its units.
    func encodeReduce(
        _ enc: MTLComputeCommandEncoder,
        depth: MTLTexture, depthPrev: MTLTexture?, guide: MTLTexture, guidePrev: MTLTexture?,
        background: DepthAnchorCeiling
    ) -> Bool {
        let g = Self.groups(width: depth.width, height: depth.height)
        let needed = g.x * g.y
        if partials == nil || partialsCapacity < needed {
            partials = device.makeBuffer(length: needed * Self.partialStride * MemoryLayout<Float>.stride, options: .storageModeShared)
            partialsCapacity = needed
        }
        guard let partials else { return false }
        var params = DepthAnchorReduceParams(
            staticLuma: RAVEDepthRefinement.staticLumaThreshold,
            hasPrev: depthPrev != nil && guidePrev != nil ? 1 : 0,
            ceiling: background.ceiling,
            ceilingSoftness: max(background.softness, 1e-6)
        )
        enc.setComputePipelineState(reducePipeline)
        enc.setTexture(depth, index: 0)
        enc.setTexture(depthPrev ?? depth, index: 1)
        enc.setTexture(guide, index: 2)
        enc.setTexture(guidePrev ?? guide, index: 3)
        enc.setBuffer(partials, offset: 0, index: 0)
        enc.setBytes(&params, length: MemoryLayout<DepthAnchorReduceParams>.stride, index: 1)
        enc.dispatchThreadgroups(MTLSize(width: g.x, height: g.y, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        return true
    }

    /// Fold the partials of the last reduction over a `width`×`height` map.
    /// Call after the command buffer completed.
    func readStats(width: Int, height: Int, hadPrev: Bool) -> DepthAnchorStats? {
        guard let partials else { return nil }
        let g = Self.groups(width: width, height: height)
        let count = g.x * g.y
        let ptr = partials.contents().bindMemory(to: Float.self, capacity: count * Self.partialStride)
        var sums = DepthAlignmentSums()
        var luma: Double = 0
        var lo = Float.infinity
        var hi = -Float.infinity
        for i in 0..<count {
            let p = ptr + i * Self.partialStride
            sums = sums + DepthAlignmentSums(
                w: Double(p[0]), wx: Double(p[1]), wy: Double(p[2]),
                wxx: Double(p[3]), wyy: Double(p[4]), wxy: Double(p[5])
            )
            luma += Double(p[6])
            lo = Swift.min(lo, p[7])
            hi = Swift.max(hi, p[8])
        }
        guard lo.isFinite, hi.isFinite else { return nil }
        let pixels = Double(max(width * height, 1))
        return DepthAnchorStats(
            sums: sums,
            meanLumaDelta: hadPrev ? Float(luma / pixels) : nil,
            min: lo, max: hi
        )
    }
}

/// Realtime refinement state for one `CoreMLDepthProvider`. Pump queue only.
final class RealtimeDepthRefiner {
    /// Joint bilateral at model resolution: wide enough to band-limit the
    /// DINOv2 patch ripple for the warp grid (the old gaussian's job, r6/σ3),
    /// while the luma term keeps depth edges on image edges.
    static let bilateralRadius: Int32 = 8
    static let bilateralSigmaSpatial: Float = 4
    static let bilateralSigmaLuma: Float = 0.06
    /// The refined map is handed to the warp at this multiple of model
    /// resolution, joint-bilaterally upsampled against a guide at that
    /// resolution (the converter's `encodeUpsampleFactor` and kernel, for the
    /// same reason). The bilateral snaps depth edges into hard steps, and at 1×
    /// the depth texel lattice (~3.7 px at 1080p) is what quantizes the warped
    /// silhouette: the warp's bilinear read of each row's step lands it on a
    /// texel boundary, so smooth edges stairstep, worst on near subjects.
    /// The gaussian this replaced hid the lattice by smearing every edge into a
    /// ramp several texels wide. Anchoring and the EMA stay at model resolution.
    static let upsampleFactor = 2
    static let upsampleRadius: Int32 = 6
    static let upsampleSigmaSpatial: Float = 3
    /// Temporal EMA on shot-space depth where the image moved (as the old
    /// stabilizer's)…
    static let emaBaseAlpha: Float = 0.35
    static let emaMotionGain: Float = 4
    /// …and where it didn't: a static surface's depth is held, converging on
    /// a new estimate with a time constant of about 1.3 s at ~25 Hz inference.
    static let emaStaticAlpha: Float = 0.03
    /// Frame-time jump that counts as a seek and restarts the lock.
    static let seekGapSeconds = 0.5

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let anchor: DepthAnchorGPU
    private let guidePipeline: MTLComputePipelineState
    private let bilateralH: MTLComputePipelineState
    private let bilateralV: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private let bins: MTLBuffer
    private let range: MTLBuffer

    private var width = 0
    private var height = 0
    private var guides: [MTLTexture] = []
    private var maps: [MTLTexture] = []      // refined model-unit depth
    private var outputs: [MTLTexture] = []   // shot-space depth (EMA'd)
    private var scratch: MTLTexture?
    private var hiGuide: MTLTexture?
    private var hiScratch: MTLTexture?
    private var hiOutputs: [MTLTexture] = [] // upsampled outputs, handed to the warp
    private var current = 0
    private var hasPrev = false
    private var lastSeconds = -Double.infinity

    private var tracker = DepthScaleShiftTracker()
    private var background = DepthAnchorCeiling.none
    private var cuts = DepthCutDetector()

    /// Last frame's numbers, for diagnostics and tests.
    private(set) var lastMapping = DepthAffine.identity
    private(set) var lastAnchored = false
    private(set) var lastCut = false

    private let signposter = RAVEMediaLog.signposter

    init?(device: MTLDevice, commandQueue: MTLCommandQueue, textureCache: CVMetalTextureCache) {
        guard let metal = RAVEMediaMetal.shared,
              let anchor = DepthAnchorGPU(metal: metal),
              let guide = metal.computePipeline("depthGuideLuma"),
              let h = metal.computePipeline("depthJointBilateralH"),
              let v = metal.computePipeline("depthJointBilateralV"),
              let bins = device.makeBuffer(length: DepthHistogram.binCount * MemoryLayout<UInt32>.stride, options: .storageModeShared),
              let range = device.makeBuffer(length: MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)
        else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        self.anchor = anchor
        self.guidePipeline = guide
        self.bilateralH = h
        self.bilateralV = v
        self.textureCache = textureCache
        self.bins = bins
        self.range = range
    }

    /// Forget the lock (seek, new video). The next frame starts from its own range.
    func reset() {
        hasPrev = false
        background = .none
        tracker.reset()
        cuts.reset()
        lastSeconds = -.infinity
    }

    /// Refine `raw` (model output for `frame`) into shot-space depth. The
    /// returned texture stays valid until the call after next.
    func refine(raw: MTLTexture, frame: CVPixelBuffer, frameSeconds: Double) -> MTLTexture? {
        guard ensureTextures(width: raw.width, height: raw.height),
              let videoTex = videoTexture(frame),
              let scratch, let hiGuide, let hiScratch else { return nil }
        var dt = frameSeconds - lastSeconds
        if !frameSeconds.isFinite || !dt.isFinite || dt < 0 || dt > Self.seekGapSeconds {
            if lastSeconds.isFinite { reset() }
            dt = 1.0 / 30
        }
        lastSeconds = frameSeconds.isFinite ? frameSeconds : -.infinity
        let cur = current, prev = 1 - current
        let usePrev = hasPrev

        // 1. Guide, edge-aware refine, anchor sums, range, histogram.
        let refineState = signposter.beginInterval("depth-refine")
        guard let cmd = commandQueue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else { return nil }
        blit.fill(buffer: bins, range: 0..<bins.length, value: 0)
        blit.endEncoding()
        guard let enc = cmd.makeComputeCommandEncoder() else { return nil }
        let uv = CoreMLDepthProvider.letterboxUVTransform(
            videoWidth: CVPixelBufferGetWidth(frame), videoHeight: CVPixelBufferGetHeight(frame),
            depthWidth: width, depthHeight: height
        )
        var guideParams = DepthGuideParams(uvScale: uv.scale, uvOffset: uv.offset)
        var bilateral = DepthStabilizeParams(
            blurRadius: Self.bilateralRadius, blurSigma: Self.bilateralSigmaSpatial,
            baseAlpha: 1, motionGain: 0, hasPrev: 0, sigmaLuma: Self.bilateralSigmaLuma
        )
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)

        enc.setComputePipelineState(guidePipeline)
        enc.setTexture(videoTex.texture, index: 0)
        enc.setTexture(guides[cur], index: 1)
        enc.setBytes(&guideParams, length: MemoryLayout<DepthGuideParams>.stride, index: 0)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)

        enc.setComputePipelineState(bilateralH)
        enc.setTexture(raw, index: 0)
        enc.setTexture(guides[cur], index: 1)
        enc.setTexture(scratch, index: 2)
        enc.setBytes(&bilateral, length: MemoryLayout<DepthStabilizeParams>.stride, index: 0)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)

        enc.setComputePipelineState(bilateralV)
        enc.setTexture(scratch, index: 0)
        enc.setTexture(guides[cur], index: 1)
        enc.setTexture(maps[cur], index: 2)
        enc.setBytes(&bilateral, length: MemoryLayout<DepthStabilizeParams>.stride, index: 0)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)

        guard anchor.encodeReduce(
            enc, depth: maps[cur], depthPrev: usePrev ? maps[prev] : nil,
            guide: guides[cur], guidePrev: usePrev ? guides[prev] : nil,
            background: background
        ), let partials = anchor.partials else {
            enc.endEncoding()
            return nil
        }
        var partialCount = UInt32(groups.width * groups.height)
        enc.setComputePipelineState(anchor.foldPipeline)
        enc.setBuffer(partials, offset: 0, index: 0)
        enc.setBytes(&partialCount, length: MemoryLayout<UInt32>.stride, index: 1)
        enc.setBuffer(range, offset: 0, index: 2)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))

        enc.setComputePipelineState(anchor.histogramPipeline)
        enc.setTexture(maps[cur], index: 0)
        enc.setBuffer(bins, offset: 0, index: 0)
        enc.setBuffer(range, offset: 0, index: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        signposter.endInterval("depth-refine", refineState)
        guard cmd.status == .completed,
              let stats = anchor.readStats(width: width, height: height, hadPrev: usePrev) else { return nil }

        // 2. Robust range, cut, anchor fit, locked mapping.
        let counts = Array(UnsafeBufferPointer(
            start: bins.contents().bindMemory(to: UInt32.self, capacity: DepthHistogram.binCount),
            count: DepthHistogram.binCount
        ))
        let total = width * height
        let p02 = DepthHistogram.percentile(counts, total: total, q: 0.02, lo: stats.min, hi: stats.max)
        var p98 = DepthHistogram.percentile(counts, total: total, q: 0.98, lo: stats.min, hi: stats.max)
        if p98 - p02 < 1e-6 { p98 = p02 + 1 }
        let cut = cuts.isCut(shape: DepthCutDetector.shape(of: counts), lo: p02, hi: p98, lumaJump: stats.meanLumaDelta)
        let relative = usePrev && !cut ? stats.sums.fit(pixelCount: total, frameSpan: p98 - p02) : nil
        let mapping = tracker.update(lo: p02, hi: p98, relative: relative, cut: cut || !usePrev, dt: dt)
        lastMapping = mapping
        background = DepthAnchorCeiling(mapping: mapping)
        lastAnchored = relative != nil
        lastCut = cut

        // 3. Shot-space depth + temporal EMA (restarted at a cut).
        guard let applyCmd = commandQueue.makeCommandBuffer(),
              let applyEnc = applyCmd.makeComputeCommandEncoder() else { return nil }
        var apply = DepthAnchorApplyParams(
            a: mapping.a, b: mapping.b,
            baseAlpha: Self.emaBaseAlpha, motionGain: Self.emaMotionGain,
            hasPrev: usePrev && !cut ? 1 : 0,
            staticLuma: RAVEDepthRefinement.staticLumaThreshold,
            staticAlpha: Self.emaStaticAlpha
        )
        applyEnc.setComputePipelineState(anchor.applyPipeline)
        applyEnc.setTexture(maps[cur], index: 0)
        applyEnc.setTexture(outputs[prev], index: 1)
        applyEnc.setTexture(outputs[cur], index: 2)
        applyEnc.setTexture(guides[cur], index: 3)
        applyEnc.setTexture(guides[usePrev ? prev : cur], index: 4)
        applyEnc.setBytes(&apply, length: MemoryLayout<DepthAnchorApplyParams>.stride, index: 0)
        applyEnc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)

        // 4. Guided ×upsampleFactor upsample for the warp: the normalized-UV
        // reads of the coarse map are a bilinear lift, and the hi-res guide's
        // luma term pins each edge to the image edge between depth texels.
        let hiGroups = MTLSize(width: (hiGuide.width + 15) / 16, height: (hiGuide.height + 15) / 16, depth: 1)
        var upsample = DepthStabilizeParams(
            blurRadius: Self.upsampleRadius, blurSigma: Self.upsampleSigmaSpatial,
            baseAlpha: 1, motionGain: 0, hasPrev: 0, sigmaLuma: Self.bilateralSigmaLuma
        )
        applyEnc.setComputePipelineState(guidePipeline)
        applyEnc.setTexture(videoTex.texture, index: 0)
        applyEnc.setTexture(hiGuide, index: 1)
        applyEnc.setBytes(&guideParams, length: MemoryLayout<DepthGuideParams>.stride, index: 0)
        applyEnc.dispatchThreadgroups(hiGroups, threadsPerThreadgroup: tg)

        applyEnc.setComputePipelineState(bilateralH)
        applyEnc.setTexture(outputs[cur], index: 0)
        applyEnc.setTexture(hiGuide, index: 1)
        applyEnc.setTexture(hiScratch, index: 2)
        applyEnc.setBytes(&upsample, length: MemoryLayout<DepthStabilizeParams>.stride, index: 0)
        applyEnc.dispatchThreadgroups(hiGroups, threadsPerThreadgroup: tg)

        applyEnc.setComputePipelineState(bilateralV)
        applyEnc.setTexture(hiScratch, index: 0)
        applyEnc.setTexture(hiGuide, index: 1)
        applyEnc.setTexture(hiOutputs[cur], index: 2)
        applyEnc.setBytes(&upsample, length: MemoryLayout<DepthStabilizeParams>.stride, index: 0)
        applyEnc.dispatchThreadgroups(hiGroups, threadsPerThreadgroup: tg)
        applyEnc.endEncoding()
        applyCmd.commit()
        applyCmd.waitUntilCompleted()
        withExtendedLifetime(videoTex.keepAlive) {}
        guard applyCmd.status == .completed else { return nil }

        hasPrev = true
        current = prev
        return hiOutputs[cur]
    }

    private func ensureTextures(width: Int, height: Int) -> Bool {
        if width == self.width, height == self.height, scratch != nil { return true }
        func make(_ factor: Int = 1) -> MTLTexture? {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r16Float, width: width * factor, height: height * factor, mipmapped: false
            )
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = .private
            return device.makeTexture(descriptor: desc)
        }
        // Half precision throughout, as the stabilizer was: the bilateral
        // samples its input with a linear filter, which 32-bit float textures
        // don't guarantee.
        guard let g0 = make(), let g1 = make(), let m0 = make(), let m1 = make(),
              let o0 = make(), let o1 = make(), let s = make(),
              let hg = make(Self.upsampleFactor), let hs = make(Self.upsampleFactor),
              let h0 = make(Self.upsampleFactor), let h1 = make(Self.upsampleFactor) else { return false }
        guides = [g0, g1]
        maps = [m0, m1]
        outputs = [o0, o1]
        scratch = s
        hiGuide = hg
        hiScratch = hs
        hiOutputs = [h0, h1]
        self.width = width
        self.height = height
        current = 0
        reset()
        return true
    }

    private func videoTexture(_ frame: CVPixelBuffer) -> (texture: MTLTexture, keepAlive: [Any])? {
        var cvTexture: CVMetalTexture?
        guard CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA,
              CVMetalTextureCacheCreateTextureFromImage(
                nil, textureCache, frame, nil, .bgra8Unorm,
                CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame), 0, &cvTexture
              ) == kCVReturnSuccess,
              let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return (texture, [cvTexture, frame])
    }
}
