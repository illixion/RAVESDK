/*
 RAVEMedia - Studio-style depth refinement (scale/shift locking + depth budget)

 Monocular depth is relative: Depth Anything V2's output (and Apple's Core ML
 build of it, which normalizes each frame's map to its own range) has an
 arbitrary scale and shift per frame. Mapping each frame by its own range makes
 the whole scene "breathe": a subject walking up to the camera raises the
 frame's near end, the map renormalizes, and the room behind them is pushed back
 although nothing in it moved.

 Conversion studios hold the environment's depth fixed across a shot and give a
 near subject its own, compressed share of the depth budget. The pieces here do
 the same automatically, shared by the realtime path (`CoreMLDepthProvider`) and
 the pre-process converter:

 - **Anchoring** (`DepthAlignmentSums`): pixels whose image did not change since
   the last frame are taken to be the same surfaces at the same depth. A
   reduced-major-axis fit over them gives the affine that maps this frame's map
   into the previous frame's units — the model's renormalization, measured and
   undone. Motion (the subject) is excluded by the same test.
 - **Locked scale/shift** (`DepthScaleShiftTracker`): the shot-space mapping is
   carried frame to frame through those fits and only relaxes slowly toward the
   frame's own robust (p2–p98) range: slowly while the content overflows the
   budget (a subject came close: hold the room), faster while it underfills (the
   subject left: give the depth back). Scene cuts reset it.
 - **Depth budget** (`DepthBudget`): a soft-knee S-curve — linear through the
   middle, tanh toe and shoulder — so content pushed past the near end plateaus
   just short of the window plane instead of clipping, and nothing ever crosses
   it (convergence 1.0 keeps meaning "nearest possible depth on the glass").

 Layering: the anchor is fitted on the static (in practice, background) layer
 and the shoulder compresses only the near layer, so the two are decoupled by
 depth value, not by a mask; depth edges were already snapped to image edges by
 the joint bilateral, so the layer boundary follows the picture.

 Everything here is plain Swift with no GPU so it can be tested on any host;
 the GPU kernels (`depthAnchorReduce`, `depthAnchorApply`) only produce the
 sums and apply the result.
 */

import Foundation

/// User-facing switch and tuning. The realtime path reads `isEnabled` when its
/// provider is created (an engine load); cached conversions always use the
/// refined pipeline, because `DepthCacheStore.pipelineVersion` is their format.
public enum RAVEDepthRefinement {
    public static let enabledDefaultsKey = "depthRefinementEnabled"

    /// Studio refinement for realtime fake-3D. Defaults to on.
    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    /// Luma change (0–1) below which a depth-resolution pixel counts as static
    /// and anchors the fit. Sensor grain after the guide downsample measures
    /// around 0.01; a moving edge is far above 0.1.
    static let staticLumaThreshold: Float = 0.04
    /// Mean luma change across the frame that reads as a hard cut, regardless
    /// of what the depth histogram says (realtime has no lookahead to confirm).
    static let cutMeanLumaDelta: Float = 0.12
}

/// `y = a·x + b`.
public struct DepthAffine: Equatable, Sendable {
    public var a: Float
    public var b: Float

    public static let identity = DepthAffine(a: 1, b: 0)

    public init(a: Float, b: Float) {
        self.a = a
        self.b = b
    }

    /// The mapping that sends `lo` to 0 and `hi` to 1.
    public init(mappingLo lo: Float, hi: Float) {
        let span = max(hi - lo, 1e-6)
        a = 1 / span
        b = -lo / span
    }

    public func callAsFunction(_ x: Float) -> Float { a * x + b }

    /// `self(inner(x))`.
    public func after(_ inner: DepthAffine) -> DepthAffine {
        DepthAffine(a: a * inner.a, b: a * inner.b + b)
    }

    public var inverse: DepthAffine? {
        guard abs(a) > 1e-9, a.isFinite, b.isFinite else { return nil }
        return DepthAffine(a: 1 / a, b: -b / a)
    }

    public func lerp(to other: DepthAffine, _ t: Float) -> DepthAffine {
        DepthAffine(a: a + (other.a - a) * t, b: b + (other.b - b) * t)
    }

    var isUsable: Bool { a.isFinite && b.isFinite && a > 0 }
}

/// The depth budget: a soft-knee S-curve from unbounded shot-space depth to the
/// warp's 0…1 (near = 1). Identity between the knees; above `kneeHi` a tanh
/// shoulder approaches 1 without reaching it, below `kneeLo` a tanh toe
/// approaches 0. Continuous with slope 1 at both knees, monotone everywhere.
/// Mirrored by `pseudo3DDepthBudget` in the shaders.
public struct DepthBudget: Equatable, Sendable {
    public var kneeLo: Float
    public var kneeHi: Float

    /// The old behaviour: clamp to 0…1.
    public static let legacy = DepthBudget(kneeLo: 0, kneeHi: 1)
    /// Background and midground linear; the near 30 % of the budget is the
    /// shoulder a close-up subject plateaus into. Untuned on device.
    public static let studio = DepthBudget(kneeLo: 0.08, kneeHi: 0.7)

    public init(kneeLo: Float, kneeHi: Float) {
        self.kneeLo = kneeLo
        self.kneeHi = kneeHi
    }

    public var isLegacy: Bool { kneeLo <= 0 && kneeHi >= 1 }

    /// For the shader uniform.
    public var knees: SIMD2<Float> { SIMD2(kneeLo, kneeHi) }

    public func apply(_ y: Float) -> Float {
        guard y.isFinite else { return y > 0 ? 1 : 0 }
        if y > kneeHi {
            let w = 1 - kneeHi
            return w > 0 ? kneeHi + w * tanh((y - kneeHi) / w) : min(y, 1)
        }
        if y < kneeLo {
            let w = kneeLo
            return w > 0 ? kneeLo - w * tanh((kneeLo - y) / w) : max(y, 0)
        }
        return y
    }
}

/// Weighted second-moment sums over the anchor pixels, as the GPU reduction
/// produces them (folded in Double on the CPU): x is this frame's map, y the
/// previous frame's at the same pixel.
struct DepthAlignmentSums: Equatable {
    var w: Double = 0
    var wx: Double = 0
    var wy: Double = 0
    var wxx: Double = 0
    var wyy: Double = 0
    var wxy: Double = 0

    mutating func add(x: Float, y: Float, weight: Float) {
        let w = Double(weight), x = Double(x), y = Double(y)
        self.w += w
        wx += w * x
        wy += w * y
        wxx += w * x * x
        wyy += w * y * y
        wxy += w * x * y
    }

    static func + (l: Self, r: Self) -> Self {
        Self(w: l.w + r.w, wx: l.wx + r.wx, wy: l.wy + r.wy, wxx: l.wxx + r.wxx, wyy: l.wyy + r.wyy, wxy: l.wxy + r.wxy)
    }

    /// Only the background layer anchors the fit: pixels the previous frame's
    /// mapping put farther than this in shot space, in both frames
    /// (`DepthAnchorCeiling`). A near subject — or a pixel it has just covered
    /// whose luma happens to match — sits at the frame's renormalized maximum,
    /// at or past 1, and would otherwise pin that maximum as if nothing had
    /// changed. Short of 1 so a subject only just nearer than the room is still
    /// excluded; well above the shoulder's knee so the near part of the room
    /// keeps anchoring.
    static let anchorCeiling: Float = 0.9
    /// Minimum share of the frame's pixels that must anchor the fit.
    static let minAnchorFraction: Double = 0.15
    /// Minimum correlation between the frames over the anchor pixels; below it
    /// the "static" pixels are noise (a flat wall, a fade) and say nothing.
    static let minCorrelation: Double = 0.6
    /// Anchor spread, as a fraction of the frame's robust span, below which the
    /// slope is unmeasurable.
    static let minRelativeSpread: Double = 0.04
    /// Plausible frame-to-frame rescale; anything wilder is a bad fit.
    static let slopeBounds: ClosedRange<Double> = 0.33...3

    /// The affine `r` with `y ≈ r(x)`: this frame's units → the previous
    /// frame's. Reduced major axis rather than least squares, because both maps
    /// carry the same kind of jitter: an ordinary regression's slope is diluted
    /// by noise in x, and chained frame after frame that bias compounds into a
    /// steady collapse of depth. Nil when the anchor can't be trusted.
    func fit(pixelCount: Int, frameSpan: Float) -> DepthAffine? {
        guard pixelCount > 0, w >= Self.minAnchorFraction * Double(pixelCount) else { return nil }
        let mx = wx / w, my = wy / w
        let vx = wxx / w - mx * mx
        let vy = wyy / w - my * my
        let cov = wxy / w - mx * my
        let minSpread = Self.minRelativeSpread * Double(max(frameSpan, 1e-6))
        guard vx > minSpread * minSpread, vy > 0, cov > 0 else { return nil }
        guard cov / (vx.squareRoot() * vy.squareRoot()) >= Self.minCorrelation else { return nil }
        let a = (vy / vx).squareRoot()
        guard Self.slopeBounds.contains(a) else { return nil }
        let b = my - a * mx
        let affine = DepthAffine(a: Float(a), b: Float(b))
        return affine.isUsable ? affine : nil
    }
}

/// The temporally locked scale/shift from a frame's map to shot space.
public struct DepthScaleShiftTracker: Sendable {
    public struct Tuning: Sendable, Equatable {
        /// Relaxation time constant toward the frame's own range while the
        /// frame overflows the budget (a near subject arrived): long, so the
        /// environment holds its depth.
        public var holdSeconds: Double = 3
        /// …while the frame underfills it (the subject left, the scene got
        /// shallower): shorter, so the depth comes back.
        public var recoverSeconds: Double = 0.6
        /// …when no anchor could be fitted (camera move, everything changed):
        /// shorter, since nothing is known about the renormalization — but not
        /// so short that one failed fit mid-shot reads as a depth jump.
        public var unanchoredSeconds: Double = 0.5
        /// Span the frame's robust range may occupy in shot space before the
        /// mapping is pulled back toward the frame's own: a guard against a run
        /// of bad fits, wide enough for a subject walking from across the room
        /// to arm's length (inverse depth ×5) to be held.
        public var spanBounds: ClosedRange<Float> = 0.35...8
        public init() {}
    }

    public var tuning: Tuning
    public private(set) var state: DepthAffine?

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    public mutating func reset() { state = nil }

    /// One frame. `lo`/`hi` are the frame's robust range in its own units,
    /// `relative` maps this frame's units into the previous frame's (nil: no
    /// anchor), `dt` is the time since the previous frame.
    public mutating func update(lo: Float, hi: Float, relative: DepthAffine?, cut: Bool, dt: Double) -> DepthAffine {
        let natural = DepthAffine(mappingLo: lo, hi: hi)
        guard let previous = state, !cut, previous.isUsable else {
            state = natural
            return natural
        }
        let carried = relative.map { previous.after($0) } ?? previous
        let span = carried(hi) - carried(lo)
        let tau: Double
        if relative == nil {
            tau = tuning.unanchoredSeconds
        } else {
            tau = span > 1 ? tuning.holdSeconds : tuning.recoverSeconds
        }
        let step = Float(1 - exp(-max(dt, 0) / max(tau, 1e-3)))
        var next = carried.lerp(to: natural, step)
        let nextSpan = next(hi) - next(lo)
        if !next.isUsable || !nextSpan.isFinite {
            next = natural
        } else if !tuning.spanBounds.contains(nextSpan) {
            // Pull back just far enough to land on the bound.
            let target = min(max(nextSpan, tuning.spanBounds.lowerBound), tuning.spanBounds.upperBound)
            let t = (target - nextSpan) / (1 - nextSpan)
            next = next.lerp(to: natural, min(max(t, 0), 1))
        }
        state = next
        return next
    }
}

/// Scene-cut detection on per-frame depth statistics, shared by the converter
/// (where it truncates the temporal window and resets the tracker) and the
/// realtime path (tracker reset). `shape` is the frame's normalized 256-bin
/// depth histogram over its own min…max.
struct DepthCutDetector {
    static let shapeDistance: Float = 0.5
    static let rangeRatioBounds: ClosedRange<Float> = 0.6...1.667
    static let rangeLoJump: Float = 0.35

    private var prevShape: [Float]?
    private var prevLo: Float = 0
    private var prevHi: Float = 1

    mutating func reset() { prevShape = nil }

    /// Whether a cut lies between the previous frame and this one. `lumaJump`
    /// is the mean absolute luma change, when the caller has it.
    mutating func isCut(shape: [Float], lo: Float, hi: Float, lumaJump: Float? = nil) -> Bool {
        defer {
            prevShape = shape
            prevLo = lo
            prevHi = hi
        }
        guard let prev = prevShape, prev.count == shape.count else { return false }
        if let lumaJump, lumaJump > RAVEDepthRefinement.cutMeanLumaDelta { return true }
        let shapeDist = 0.5 * zip(shape, prev).reduce(Float(0)) { $0 + abs($1.0 - $1.1) }
        let prevSpan = max(prevHi - prevLo, 1e-6)
        let ratio = (hi - lo) / prevSpan
        let loJump = abs(lo - prevLo) / prevSpan
        return shapeDist > Self.shapeDistance
            || !Self.rangeRatioBounds.contains(ratio)
            || loJump > Self.rangeLoJump
    }

    static func shape(of bins: [UInt32]) -> [Float] {
        let total = bins.reduce(0) { $0 + Int($1) }
        guard total > 0 else { return Array(repeating: 0, count: bins.count) }
        return bins.map { Float($0) / Float(total) }
    }
}

/// The converter's per-frame mapping policy, over a whole (merged) timeline:
/// one `DepthScaleShiftTracker` per half-rate lattice (the anchor fits chain
/// within a lattice), all reset at a cut; then each frame's robust range in
/// shot space is smoothed with a small centered window within its segment and
/// the frame's affine re-derived from it. The window both trims fit jitter and
/// ties a two-pass conversion's even and odd lattices together, which would
/// otherwise shimmer against each other at the frame rate.
enum DepthShotMapping {
    static let smoothingWeights: [Float] = [1, 2, 1]

    struct Frame {
        var seconds: Double
        var lo: Float
        var hi: Float
        var cutBefore: Bool
        var relative: DepthAffine?
        var lattice: Int
    }

    /// Raw units → shot space for every frame of a merged timeline.
    static func map(_ frames: [Frame]) -> [DepthAffine] {
        let n = frames.count
        guard n > 0 else { return [] }
        var trackers: [Int: DepthScaleShiftTracker] = [:]
        var lastSeconds: [Int: Double] = [:]
        var locked = [DepthAffine](repeating: .identity, count: n)
        for i in 0..<n {
            let f = frames[i]
            if f.cutBefore {
                // A cut resets every lattice: both sit on the same shot.
                for key in trackers.keys { trackers[key]?.reset() }
            }
            var tracker = trackers[f.lattice] ?? DepthScaleShiftTracker()
            let fresh = tracker.state == nil
            let dt = lastSeconds[f.lattice].map { f.seconds - $0 } ?? 0
            locked[i] = tracker.update(
                lo: f.lo, hi: f.hi, relative: fresh ? nil : f.relative,
                cut: fresh, dt: dt.isFinite ? max(dt, 0) : 0
            )
            trackers[f.lattice] = tracker
            lastSeconds[f.lattice] = f.seconds
        }

        // Smooth the shot-space range within each segment, then map each
        // frame's own lo/hi onto it.
        var segmentStart = 0
        var result = locked
        let weights = smoothingWeights
        let radius = weights.count / 2
        for i in 0...n where i == n || (i > 0 && frames[i].cutBefore) {
            let range = segmentStart..<i
            for k in range {
                var lo: Float = 0, hi: Float = 0, wsum: Float = 0
                for (o, w) in weights.enumerated() {
                    let j = k - radius + o
                    guard range.contains(j) else { continue }
                    lo += w * locked[j](frames[j].lo)
                    hi += w * locked[j](frames[j].hi)
                    wsum += w
                }
                lo /= wsum
                hi /= wsum
                let span = max(frames[k].hi - frames[k].lo, 1e-6)
                let a = (hi - lo) / span
                let candidate = DepthAffine(a: a, b: lo - a * frames[k].lo)
                result[k] = candidate.isUsable ? candidate : locked[k]
            }
            segmentStart = i
        }
        return result
    }
}
