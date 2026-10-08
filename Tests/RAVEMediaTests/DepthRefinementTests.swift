import Foundation
import Testing
@testable import RAVEMedia

/// Studio depth refinement: the depth budget, the anchor fit, the locked
/// scale/shift and its cut reset. All of it is plain arithmetic the GPU kernels
/// only feed, so it's tested here without a device.
@Suite("Depth refinement")
struct DepthRefinementTests {
    // MARK: Depth budget

    @Test func budgetIsIdentityBetweenTheKnees() {
        let budget = DepthBudget.studio
        for y in stride(from: budget.kneeLo, through: budget.kneeHi, by: 0.05) {
            #expect(budget.apply(y) == y)
        }
    }

    @Test func budgetIsMonotoneAndBoundedEverywhere() {
        let budget = DepthBudget.studio
        var previous = budget.apply(-10)
        #expect(previous >= 0)
        for i in 1...4000 {
            let y = -10 + Float(i) * 0.006
            let value = budget.apply(y)
            #expect(value >= previous)
            #expect(value >= 0 && value <= 1)
            previous = value
        }
        // Far past the near end it plateaus just short of the window plane.
        #expect(budget.apply(5) > 0.99)
    }

    /// Slope 1 on both sides of each knee: no visible crease in depth.
    @Test func budgetIsSmoothAtTheKnees() {
        let budget = DepthBudget.studio
        let h: Float = 1e-3
        for knee in [budget.kneeLo, budget.kneeHi] {
            let below = (budget.apply(knee) - budget.apply(knee - h)) / h
            let above = (budget.apply(knee + h) - budget.apply(knee)) / h
            #expect(abs(below - 1) < 0.01)
            #expect(abs(above - 1) < 0.01)
        }
    }

    @Test func legacyBudgetClamps() {
        let budget = DepthBudget.legacy
        #expect(budget.isLegacy)
        #expect(budget.apply(-0.3) == 0)
        #expect(budget.apply(0.4) == 0.4)
        #expect(budget.apply(1.7) == 1)
    }

    // MARK: Anchor fit

    /// The fit recovers a renormalization exactly on clean data.
    @Test func fitRecoversTheRescale() {
        var sums = DepthAlignmentSums()
        let truth = DepthAffine(a: 1.6, b: -0.2)
        for i in 0..<1000 {
            let x = Float(i) / 1000
            sums.add(x: x, y: truth(x), weight: 1)
        }
        let fit = sums.fit(pixelCount: 1000, frameSpan: 1)
        #expect(fit != nil)
        #expect(abs((fit?.a ?? 0) - truth.a) < 1e-3)
        #expect(abs((fit?.b ?? 0) - truth.b) < 1e-3)
    }

    /// With jitter in both maps the slope must stay unbiased: an ordinary
    /// least-squares slope comes out low, and chained frame after frame that
    /// bias collapses the scene's depth.
    @Test func fitIsUnbiasedUnderSymmetricNoise() {
        var rng = SplitMix(seed: 7)
        var slopes: [Float] = []
        for _ in 0..<200 {
            var sums = DepthAlignmentSums()
            for _ in 0..<2000 {
                let truth = rng.unit() * 0.4 + 0.1
                sums.add(x: truth + rng.gaussian() * 0.03, y: truth + rng.gaussian() * 0.03, weight: 1)
            }
            if let fit = sums.fit(pixelCount: 2000, frameSpan: 1) { slopes.append(fit.a) }
        }
        let mean = slopes.reduce(0, +) / Float(slopes.count)
        #expect(slopes.count == 200)
        #expect(abs(mean - 1) < 0.005)
    }

    @Test func fitRefusesTooFewAnchorPixels() {
        var sums = DepthAlignmentSums()
        for i in 0..<100 {
            sums.add(x: Float(i) / 100, y: Float(i) / 100, weight: 1)
        }
        #expect(sums.fit(pixelCount: 10_000, frameSpan: 1) == nil)
    }

    @Test func fitRefusesUncorrelatedPixels() {
        var rng = SplitMix(seed: 3)
        var sums = DepthAlignmentSums()
        for _ in 0..<1000 {
            sums.add(x: rng.unit(), y: rng.unit(), weight: 1)
        }
        #expect(sums.fit(pixelCount: 1000, frameSpan: 1) == nil)
    }

    // MARK: Scale/shift tracker

    @Test func firstFrameAndCutsStartFromTheFramesOwnRange() {
        var tracker = DepthScaleShiftTracker()
        let first = tracker.update(lo: 0.2, hi: 0.6, relative: nil, cut: false, dt: 1.0 / 30)
        #expect(abs(first(0.2)) < 1e-6)
        #expect(abs(first(0.6) - 1) < 1e-6)
        // Carry an anchored mapping for a while, then cut: back to natural.
        for _ in 0..<10 {
            _ = tracker.update(lo: 0.2, hi: 0.6, relative: DepthAffine(a: 0.9, b: 0.01), cut: false, dt: 1.0 / 30)
        }
        let afterCut = tracker.update(lo: 0, hi: 2, relative: DepthAffine(a: 0.9, b: 0.01), cut: true, dt: 1.0 / 30)
        #expect(afterCut == DepthAffine(mappingLo: 0, hi: 2))
    }

    /// A near subject arrives and the model renormalizes: the background's raw
    /// values are halved. The anchor says so, and the mapping carries it — the
    /// background keeps its shot-space depth instead of being pushed back.
    @Test func anchoredRenormalizationHoldsTheBackground() {
        var tracker = DepthScaleShiftTracker()
        let start = tracker.update(lo: 0, hi: 1, relative: nil, cut: true, dt: 0)
        let background: Float = 0.5
        let before = start(background)
        // New frame: everything old is at half its raw value, the subject at 1.
        let rescale = DepthAffine(a: 2, b: 0) // new units → previous units
        let after = tracker.update(lo: 0, hi: 1, relative: rescale, cut: false, dt: 1.0 / 30)
        #expect(abs(after(background / 2) - before) < 0.03)
        // Unanchored, the same frame would put the background at 0.25.
        let unlocked = DepthAffine(mappingLo: 0, hi: 1)
        #expect(abs(unlocked(background / 2) - before) > 0.2)
    }

    /// Relaxation is asymmetric: an overflowing frame (subject close) holds
    /// for seconds, an underfilling one (subject gone) recovers in about a
    /// third of the time.
    @Test func holdIsSlowerThanRecovery() {
        func secondsToHalfway(relative: DepthAffine) -> Double {
            var tracker = DepthScaleShiftTracker()
            _ = tracker.update(lo: 0, hi: 1, relative: nil, cut: true, dt: 0)
            // One rescale step, then static frames.
            var mapping = tracker.update(lo: 0, hi: 1, relative: relative, cut: false, dt: 1.0 / 30)
            let initialSpan = mapping(1) - mapping(0)
            var t = 1.0 / 30
            while abs(mapping(1) - mapping(0) - 1) > abs(initialSpan - 1) / 2, t < 30 {
                mapping = tracker.update(lo: 0, hi: 1, relative: .identity, cut: false, dt: 1.0 / 30)
                t += 1.0 / 30
            }
            return t
        }
        let hold = secondsToHalfway(relative: DepthAffine(a: 2, b: 0))    // span 2: overflow
        let recover = secondsToHalfway(relative: DepthAffine(a: 0.5, b: 0)) // span 0.5: underfill
        #expect(hold > 0.8)
        #expect(recover < hold / 2)
    }

    @Test func implausibleSpanIsPulledToTheBound() {
        var tracker = DepthScaleShiftTracker()
        _ = tracker.update(lo: 0, hi: 1, relative: nil, cut: true, dt: 0)
        var mapping = DepthAffine.identity
        for _ in 0..<20 {
            mapping = tracker.update(lo: 0, hi: 1, relative: DepthAffine(a: 2.5, b: 0), cut: false, dt: 1.0 / 30)
        }
        let span = mapping(1) - mapping(0)
        #expect(span <= tracker.tuning.spanBounds.upperBound + 1e-4)
    }

    // MARK: Cut detection (shared with the converter)

    @Test func cutDetectorFlagsAShapeChangeAndALumaJump() {
        var detector = DepthCutDetector()
        var a = [UInt32](repeating: 0, count: 256)
        a[10] = 100
        var b = [UInt32](repeating: 0, count: 256)
        b[200] = 100
        let sa = DepthCutDetector.shape(of: a), sb = DepthCutDetector.shape(of: b)
        let first = detector.isCut(shape: sa, lo: 0, hi: 1)
        let same = detector.isCut(shape: sa, lo: 0, hi: 1)
        let changed = detector.isCut(shape: sb, lo: 0, hi: 1)
        let steady = detector.isCut(shape: sb, lo: 0, hi: 1, lumaJump: 0.02)
        let flash = detector.isCut(shape: sb, lo: 0, hi: 1, lumaJump: 0.3)
        #expect(!first)
        #expect(!same)
        #expect(changed)
        #expect(!steady)
        #expect(flash)
    }

    // MARK: Converter timeline policy

    @Test func shotMappingResetsAtCutsAndTiesLattices() {
        // Two lattices over one shot, each anchored by identity fits, then a cut
        // into a scene with a different range.
        var frames: [DepthShotMapping.Frame] = []
        for i in 0..<20 {
            frames.append(.init(seconds: Double(i) / 60, lo: 0.1, hi: 0.9, cutBefore: false,
                                relative: i < 2 ? nil : .identity, lattice: i % 2))
        }
        for i in 20..<30 {
            frames.append(.init(seconds: Double(i) / 60, lo: 2, hi: 6, cutBefore: i == 20,
                                relative: i < 22 ? nil : .identity, lattice: i % 2))
        }
        let mapping = DepthShotMapping.map(frames)
        for i in 0..<20 {
            #expect(abs(mapping[i](0.1)) < 1e-4)
            #expect(abs(mapping[i](0.9) - 1) < 1e-4)
        }
        for i in 20..<30 {
            #expect(abs(mapping[i](2)) < 1e-4)
            #expect(abs(mapping[i](6) - 1) < 1e-4)
        }
    }

    // MARK: End to end on a synthetic shot

    /// The breathing scenario, end to end on the CPU: a static room, a subject
    /// walking up to the camera, and a model that normalizes each frame to its
    /// own min…max (as Apple's Core ML build does). The room's displayed depth
    /// should barely move with refinement and move a lot without it.
    @Test func backgroundDepthHoldsWhileASubjectApproaches() {
        let result = SyntheticShot.run()
        if ProcessInfo.processInfo.environment["DEPTH_TRACE"] != nil { print("synthetic:", result) }
        #expect(result.legacyEntryShift > 0.2)
        #expect(result.refinedEntryShift < result.legacyEntryShift / 4)
        #expect(result.refinedMaxStep < result.legacyMaxStep / 2)
        // And the subject still reads as the nearest thing in the frame.
        #expect(result.refinedSubjectFinal > result.refinedBackgroundMean + 0.2)
    }
}

/// A deterministic shot for the end-to-end test and the measurement harness.
enum SyntheticShot {
    struct Result {
        /// How far the room's displayed depth moved while the subject walked
        /// up: the breathing a viewer sees.
        var legacyEntryShift: Float
        var refinedEntryShift: Float
        /// Largest frame-to-frame move of the room's depth over the whole shot.
        /// Refined depth still eases back toward the frame's own range after
        /// the entry (the hold's slow relaxation), but never jumps.
        var legacyMaxStep: Float
        var refinedMaxStep: Float
        var legacyBackgroundStd: Float
        var refinedBackgroundStd: Float
        var refinedBackgroundMean: Float
        var refinedSubjectFinal: Float
    }

    static func run(frames: Int = 90, entryFrames: Int = 12, seed: UInt64 = 11) -> Result {
        let w = 96, h = 64
        var rng = SplitMix(seed: seed)
        // True inverse depth of the room: a floor-to-wall gradient, 0.2…0.6,
        // plus static texture in the image.
        var room = [Float](repeating: 0, count: w * h)
        var roomLuma = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                room[y * w + x] = 0.2 + 0.4 * Float(y) / Float(h - 1)
                roomLuma[y * w + x] = rng.unit()
            }
        }
        var tracker = DepthScaleShiftTracker()
        var prevMap: [Float]?
        var prevLuma: [Float]?
        var prevCeiling = DepthAnchorCeiling.none
        var legacy: [Float] = []
        var refined: [Float] = []
        var subjectFinal: Float = 0
        // A background patch the subject never covers (a strip at mid height on
        // the left); its mean is what the viewer reads as "the wall".
        let probe = ((h / 2 - 4)..<(h / 2 + 4)).flatMap { y in (2..<14).map { y * w + $0 } }
        func patch(_ v: [Float]) -> Float { probe.map { v[$0] }.reduce(0, +) / Float(probe.count) }

        for f in 0..<frames {
            // The subject walks up within `entryFrames` (~0.4 s), then stays.
            let t = min(Float(f) / Float(entryFrames), 1)
            let radius = 6 + 20 * t
            let subjectDepth = 0.7 + 2.3 * t // inverse depth: from midground to very close
            var depth = room
            var luma = roomLuma
            for y in 0..<h {
                for x in 0..<w {
                    let dx = Float(x - w / 2), dy = Float(y - h / 2)
                    if dx * dx + dy * dy < radius * radius {
                        depth[y * w + x] = subjectDepth
                        luma[y * w + x] = 0.5 + 0.5 * sin(Float(f) * 0.7 + Float(x)) // moving texture
                    }
                }
            }
            // The model: per-frame min-max normalization plus jitter.
            let lo = depth.min()!, hi = depth.max()!
            let map = depth.map { ($0 - lo) / (hi - lo) + rng.gaussian() * 0.01 }

            // Legacy: per-frame normalized, clamped.
            legacy.append(DepthBudget.legacy.apply(patch(map)))

            // Refined: robust range, anchor fit on static pixels, tracker, budget.
            let sorted = map.sorted()
            let p02 = sorted[Int(Float(sorted.count) * 0.02)]
            let p98 = sorted[Int(Float(sorted.count) * 0.98)]
            var relative: DepthAffine?
            if let prevMap, let prevLuma {
                var sums = DepthAlignmentSums()
                for i in 0..<map.count {
                    let dl = abs(luma[i] - prevLuma[i])
                    let weight = max(0, 1 - dl / RAVEDepthRefinement.staticLumaThreshold)
                        * min(max((prevCeiling.ceiling - max(map[i], prevMap[i])) / prevCeiling.softness, 0), 1)
                    sums.add(x: map[i], y: prevMap[i], weight: weight)
                }
                relative = sums.fit(pixelCount: map.count, frameSpan: p98 - p02)
            }
            let mapping = tracker.update(lo: p02, hi: p98, relative: relative, cut: prevMap == nil, dt: 1.0 / 30)
            refined.append(DepthBudget.studio.apply(mapping(patch(map))))
            if ProcessInfo.processInfo.environment["DEPTH_TRACE"] != nil {
                print("f\(f) anchored=\(relative != nil) rel=\(String(describing: relative)) map=\(mapping) legacy=\(legacy.last!) refined=\(refined.last!) p02=\(p02) p98=\(p98)")
            }
            subjectFinal = DepthBudget.studio.apply(mapping(map[(h / 2) * w + w / 2]))
            prevMap = map
            prevLuma = luma
            prevCeiling = DepthAnchorCeiling(mapping: mapping)
        }
        func std(_ v: [Float]) -> Float {
            let m = v.reduce(0, +) / Float(v.count)
            return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Float(v.count)).squareRoot()
        }
        let window = 0..<min(frames, entryFrames + 2)
        func shift(_ v: [Float]) -> Float { window.map { abs(v[$0] - v[0]) }.max() ?? 0 }
        func maxStep(_ v: [Float]) -> Float { (1..<v.count).map { abs(v[$0] - v[$0 - 1]) }.max() ?? 0 }
        return Result(
            legacyEntryShift: shift(legacy),
            refinedEntryShift: shift(refined),
            legacyMaxStep: maxStep(legacy),
            refinedMaxStep: maxStep(refined),
            legacyBackgroundStd: std(legacy),
            refinedBackgroundStd: std(refined),
            refinedBackgroundMean: refined.reduce(0, +) / Float(refined.count),
            refinedSubjectFinal: subjectFinal
        )
    }
}

/// Small deterministic generator for the tests.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
    mutating func gaussian() -> Float {
        let u1 = max(unit(), 1e-7), u2 = unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
