import Foundation
import simd

/// Landmarks to blend shapes, frame by frame: measured against this face at
/// rest (`neutral`), so a naturally wide mouth isn't a smile, then smoothed.
///
/// The rest face is learnt while watching: each measure's usual value over
/// the last several seconds (the eyes' upper quarter, since blinks are short;
/// the mouth's lower part, since it is mostly shut). `calibrate` takes it
/// from a moment the performer holds still instead, and that holds until
/// cleared.
public struct FaceSolver: Sendable {

    public struct Tuning: Sendable, Equatable, Codable {
        /// The picture is a mirror image (left is the face's left).
        public var mirroredImage = false
        /// Landmarks below this confidence count as no face.
        public var minimumConfidence: Float = 0.35
        /// How far shut (1 − gap ÷ rest gap) an eye starts to blink, and is
        /// fully shut.
        public var blinkStart: Float = 0.3
        public var blinkFull: Float = 0.72
        /// Gap over the rest gap, past 1, for wide open.
        public var wideRange: Float = 0.35
        /// Eyelids as a plain open / shut: an eye is shut (1) once it has closed
        /// by `binaryThreshold` (1 − gap ÷ rest gap) and open (0) otherwise,
        /// with no squints or wide eyes. For a face that has to be held wide
        /// open to read right in the analogue mapping.
        public var binaryEyelids = false
        public var binaryThreshold: Float = 0.5
        /// Each of these off leaves its shape at zero, in either mode.
        public var squintsEnabled = true
        public var wideEyesEnabled = true
        /// A brow's travel, in the vertical unit, for fully up and down.
        public var browRaise: Float = 0.07
        public var browLower: Float = 0.05
        /// Lip gap, in the vertical unit, for the jaw fully open.
        public var jawRange: Float = 0.5
        /// How far opening the jaw lowers the corners by itself, per unit of
        /// `jawOpen`: not a frown.
        public var jawCornerDrop: Float = 0.08
        /// A corner's rise, vertical unit, and spread, share of its rest
        /// spread, for a full smile.
        public var smileLift: Float = 0.1
        public var smileSpread: Float = 0.12
        public var frownDrop: Float = 0.06
        /// The mouth's narrowing, share of its rest width, for a full pucker.
        public var puckerRange: Float = 0.18
        /// The mouth's centre off the midline, eye spacings, for fully left or right.
        public var shiftRange: Float = 0.08
        /// Pupil offset to eye angle: radians per half eye width across, per
        /// vertical unit up.
        public var pupilYaw: Float = 0.7
        public var pupilPitch: Float = 4
        /// Past this turn (radians) the far eye is foreshortened out of
        /// reading; the near one speaks for both.
        public var profileYaw: Float = 0.55
        /// 1€ smoothing: Hz at rest, and how fast the cutoff rises with speed.
        public var eyeCutoff: Float = 5
        public var mouthCutoff: Float = 3
        public var browCutoff: Float = 2
        public var beta: Float = 6
        /// Seconds the reading eases out over once the face is lost.
        public var loseTime: Float = 0.35

        public init() {}
    }

    public var tuning = Tuning()
    /// A rest face measured on purpose; nil learns it.
    public var calibrated: FaceFeatures?
    /// The rest face the solver measures against now.
    public private(set) var neutral = FaceFeatures.typical
    public private(set) var reading = FaceReading()
    /// Frames seen since the rest face was last learnt from scratch.
    public var learntFrames: Int { history.count }
    public var isCalibrating: Bool { calibration != nil }

    private var history: [FaceFeatures] = []
    private let historyLimit = 300
    private var sinceRelearn = 0
    private var calibration: (remaining: Float, samples: [FaceFeatures])?
    private var filters: [FaceBlendShape: FaceOneEuro] = [:]
    private var lookFilters = (left: FaceOneEuro(minCutoff: 3, beta: 2), right: FaceOneEuro(minCutoff: 3, beta: 2))
    private var lost: Float = 1
    private var presence: Float = 0

    public init(tuning: Tuning = Tuning(), calibrated: FaceFeatures? = nil) {
        self.tuning = tuning
        self.calibrated = calibrated
        if let calibrated { neutral = calibrated }
    }

    /// Takes the rest face from the next `seconds` of frames: the performer
    /// relaxes and looks ahead meanwhile.
    public mutating func calibrate(seconds: Float = 1.5) {
        calibration = (seconds, [])
    }

    /// Back to learning the rest face from scratch.
    public mutating func clearCalibration() {
        calibrated = nil
        calibration = nil
        history.removeAll()
        neutral = .typical
    }

    public mutating func reset() {
        filters.removeAll()
        lookFilters.left.reset()
        lookFilters.right.reset()
        lost = 1
        presence = 0
        reading = FaceReading()
    }

    /// One frame: `landmarks` nil (or unsure) when no face was found. Call
    /// once per new camera frame, or with nil as time passes without one.
    @discardableResult
    public mutating func solve(_ landmarks: FaceLandmarks?, deltaTime: Float) -> FaceReading {
        let dt = max(deltaTime, 1e-3)
        let features = landmarks.flatMap { l in
            l.confidence >= tuning.minimumConfidence ? FaceFeatures.measure(l, mirroredImage: tuning.mirroredImage) : nil
        }
        guard let features, let landmarks else {
            lost += dt
            presence = max(0, presence - dt / max(tuning.loseTime, 1e-3))
            var faded = reading
            let keep = presence
            faded.shapes = reading.shapes.mapValues { $0 * keep / max(reading.presence, 1e-3) }
            if presence == 0 { faded.shapes = [:] }
            faded.presence = presence
            faded.confidence = 0
            reading = faded
            return faded
        }
        if lost > 0.5 { reset() }
        lost = 0
        presence = min(1, presence + dt / 0.2)
        learn(features, deltaTime: dt)

        let yaw = landmarks.yaw
        var raw = shapes(from: steadied(features, yaw: yaw))
        // Smoothed, each part of the face at its own pace: lids are quick.
        for (shape, value) in raw {
            let cutoff: Float = switch shape {
            case .eyeBlinkLeft, .eyeBlinkRight, .eyeWideLeft, .eyeWideRight, .eyeSquintLeft, .eyeSquintRight:
                tuning.eyeCutoff
            case .browDownLeft, .browDownRight, .browInnerUp, .browOuterUpLeft, .browOuterUpRight:
                tuning.browCutoff
            default: tuning.mouthCutoff
            }
            var filter = filters[shape] ?? FaceOneEuro(minCutoff: cutoff, beta: tuning.beta)
            raw[shape] = max(0, min(1, filter.filter(SIMD3(value, 0, 0), deltaTime: dt).x))
            filters[shape] = filter
        }

        var next = FaceReading()
        next.shapes = raw
        next.presence = presence
        next.features = features
        next.headAngles = SIMD3(landmarks.yaw, landmarks.pitch, landmarks.roll)
        next.confidence = landmarks.confidence
        if let look = look(from: features, yaw: yaw) {
            let l = lookFilters.left.filter(SIMD3(look.left, 0), deltaTime: dt)
            let r = lookFilters.right.filter(SIMD3(look.right, 0), deltaTime: dt)
            next.look = EyeLook(left: SIMD2(l.x, l.y), right: SIMD2(r.x, r.y)).clamped()
        }
        reading = next
        return next
    }

    // MARK: - The rest face

    private mutating func learn(_ features: FaceFeatures, deltaTime: Float) {
        if var calibration {
            calibration.samples.append(features)
            calibration.remaining -= deltaTime
            if calibration.remaining <= 0, !calibration.samples.isEmpty {
                let measured = Self.rest(of: calibration.samples, held: true)
                calibrated = measured
                neutral = measured
                self.calibration = nil
            } else {
                self.calibration = calibration
            }
        }
        history.append(features)
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
        guard calibrated == nil else { return }
        sinceRelearn += 1
        if history.count >= 20, sinceRelearn >= 10 {
            sinceRelearn = 0
            neutral = Self.rest(of: history, held: false)
        }
    }

    /// The rest face from frames of it. `held`: the performer held still, so
    /// the middle of everything; otherwise, watched as they go, the eyes'
    /// upper quarter (blinks are short) and the lips' lower part (mostly shut).
    static func rest(of samples: [FaceFeatures], held: Bool) -> FaceFeatures {
        func at(_ values: [Float], _ q: Float) -> Float {
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, max(0, Int(Float(sorted.count - 1) * q + 0.5)))]
        }
        func pair(_ key: (FaceFeatures) -> SIMD2<Float>, _ q: Float) -> SIMD2<Float> {
            SIMD2(at(samples.map { key($0).x }, q), at(samples.map { key($0).y }, q))
        }
        func pupil(_ key: (FaceFeatures) -> SIMD2<Float>?) -> SIMD2<Float>? {
            let found = samples.compactMap(key)
            guard !found.isEmpty else { return nil }
            return SIMD2(at(found.map(\.x), 0.5), at(found.map(\.y), 0.5))
        }
        return FaceFeatures(
            eyeOpen: pair(\.eyeOpen, held ? 0.5 : 0.75),
            browInner: pair(\.browInner, 0.5), browOuter: pair(\.browOuter, 0.5),
            mouthOpen: at(samples.map(\.mouthOpen), held ? 0.5 : 0.15),
            mouthWidth: at(samples.map(\.mouthWidth), 0.5),
            cornerHeight: pair(\.cornerHeight, 0.5), cornerSpread: pair(\.cornerSpread, 0.5),
            mouthShift: at(samples.map(\.mouthShift), 0.5),
            leftPupil: pupil(\.leftPupil), rightPupil: pupil(\.rightPupil))
    }

    // MARK: - Measures to shapes

    /// Turned far enough that one eye is foreshortened, the near eye's
    /// measures stand for both (people seldom wink, they often turn).
    private func steadied(_ f: FaceFeatures, yaw: Float) -> FaceFeatures {
        guard abs(yaw) > tuning.profileYaw else { return f }
        var f = f
        // Vision's yaw is the face turned toward the image's right for +.
        // In an ordinary camera the image's right is the face's left, so
        // turned that way the face's left eye is the far one.
        let farIsLeft = (yaw > 0) != tuning.mirroredImage
        let ratio = farIsLeft ? f.eyeOpen.y / max(neutral.eyeOpen.y, 1e-4) : f.eyeOpen.x / max(neutral.eyeOpen.x, 1e-4)
        if farIsLeft {
            f.eyeOpen.x = ratio * neutral.eyeOpen.x
            f.browInner.x = neutral.browInner.x + (f.browInner.y - neutral.browInner.y)
            f.browOuter.x = neutral.browOuter.x + (f.browOuter.y - neutral.browOuter.y)
        } else {
            f.eyeOpen.y = ratio * neutral.eyeOpen.y
            f.browInner.y = neutral.browInner.y + (f.browInner.x - neutral.browInner.x)
            f.browOuter.y = neutral.browOuter.y + (f.browOuter.x - neutral.browOuter.x)
        }
        return f
    }

    func shapes(from f: FaceFeatures) -> [FaceBlendShape: Float] {
        let t = tuning, n = neutral
        func unit(_ v: Float) -> Float { max(0, min(1, v)) }
        func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
            let u = unit((x - a) / max(b - a, 1e-4))
            return u * u * (3 - 2 * u)
        }
        var out: [FaceBlendShape: Float] = [:]

        // Eyes.
        let sides: [(open: Float, rest: Float, blink: FaceBlendShape, squint: FaceBlendShape, wide: FaceBlendShape)] = [
            (f.eyeOpen.x, n.eyeOpen.x, .eyeBlinkLeft, .eyeSquintLeft, .eyeWideLeft),
            (f.eyeOpen.y, n.eyeOpen.y, .eyeBlinkRight, .eyeSquintRight, .eyeWideRight),
        ]
        for side in sides {
            let ratio = side.open / max(side.rest, 1e-4)
            let closure = 1 - ratio
            if t.binaryEyelids {
                out[side.blink] = closure >= t.binaryThreshold ? 1 : 0
                out[side.squint] = 0
                out[side.wide] = 0
                continue
            }
            let blink = smoothstep(t.blinkStart, t.blinkFull, closure)
            out[side.blink] = blink
            out[side.squint] = t.squintsEnabled ? unit(closure / max(t.blinkStart, 1e-4)) * (1 - blink) : 0
            out[side.wide] = t.wideEyesEnabled ? unit((ratio - 1) / t.wideRange) : 0
        }

        // Brows.
        let inner = f.browInner - n.browInner, outer = f.browOuter - n.browOuter
        out[.browInnerUp] = unit((inner.x + inner.y) / 2 / t.browRaise)
        out[.browOuterUpLeft] = unit(outer.x / t.browRaise)
        out[.browOuterUpRight] = unit(outer.y / t.browRaise)
        out[.browDownLeft] = unit(-(inner.x * 0.6 + outer.x * 0.4) / t.browLower)
        out[.browDownRight] = unit(-(inner.y * 0.6 + outer.y * 0.4) / t.browLower)

        // Jaw and lips.
        let jaw = unit((f.mouthOpen - n.mouthOpen) / t.jawRange)
        out[.jawOpen] = jaw
        let narrowing = (n.mouthWidth - f.mouthWidth) / max(n.mouthWidth, 1e-4)
        let round = unit(narrowing / t.puckerRange)
        let funnel = min(round, unit(jaw * 2.5))
        out[.mouthFunnel] = funnel
        out[.mouthPucker] = round * (1 - unit(jaw * 2.5))
        let corners: [(height: Float, rest: Float, spread: Float, restSpread: Float,
                       smile: FaceBlendShape, frown: FaceBlendShape, stretch: FaceBlendShape,
                       cheek: FaceBlendShape, squint: FaceBlendShape)] = [
            (f.cornerHeight.x, n.cornerHeight.x, f.cornerSpread.x, n.cornerSpread.x,
             .mouthSmileLeft, .mouthFrownLeft, .mouthStretchLeft, .cheekSquintLeft, .eyeSquintLeft),
            (f.cornerHeight.y, n.cornerHeight.y, f.cornerSpread.y, n.cornerSpread.y,
             .mouthSmileRight, .mouthFrownRight, .mouthStretchRight, .cheekSquintRight, .eyeSquintRight),
        ]
        for c in corners {
            let lift = c.height - c.rest + jaw * t.jawCornerDrop
            let spread = (c.spread - c.restSpread) / max(c.restSpread, 1e-4)
            let smile = unit(max(0, lift) / t.smileLift * 0.7 + max(0, spread) / t.smileSpread * 0.5)
            out[c.smile] = smile
            out[c.frown] = unit(-lift / t.frownDrop) * (1 - smile)
            out[c.stretch] = unit(spread / t.smileSpread) * unit(1 - max(0, lift) / t.smileLift)
            out[c.cheek] = smile * 0.6
            // A smile narrows the eyes from below.
            out[c.squint] = max(out[c.squint] ?? 0, smile * 0.4)
        }
        let shift = f.mouthShift - n.mouthShift
        out[.mouthLeft] = unit(shift / t.shiftRange)
        out[.mouthRight] = unit(-shift / t.shiftRange)
        return out
    }

    /// Where the pupils say the eyes look, against where they sat at rest.
    private func look(from f: FaceFeatures, yaw: Float) -> EyeLook? {
        guard let left = f.leftPupil, let right = f.rightPupil else { return nil }
        let t = tuning
        func angles(_ p: SIMD2<Float>, _ rest: SIMD2<Float>?) -> SIMD2<Float> {
            let d = p - (rest ?? .zero)
            return SIMD2(d.x * t.pupilYaw, d.y * t.pupilPitch)
        }
        var l = angles(left, neutral.leftPupil), r = angles(right, neutral.rightPupil)
        if abs(yaw) > t.profileYaw {
            let farIsLeft = (yaw > 0) != t.mirroredImage
            if farIsLeft { l = r } else { r = l }
        }
        return EyeLook(left: l, right: r).clamped()
    }
}

/// The 1€ filter (Casiez, Roussel and Vogel, 2012), for face weights: a
/// low-pass whose cutoff rises with speed, so a still face stops shimmering
/// and a quick blink still lands. RAVEEngine's `OneEuroFilter` is the same
/// filter; the two packages never depend on each other, so it is repeated here.
struct FaceOneEuro: Sendable {
    var minCutoff: Float
    var beta: Float
    var derivativeCutoff: Float = 1
    private var value: SIMD3<Float>?
    private var derivative = SIMD3<Float>.zero

    init(minCutoff: Float = 1.2, beta: Float = 8) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    mutating func reset() { value = nil; derivative = .zero }

    mutating func filter(_ x: SIMD3<Float>, deltaTime: Float) -> SIMD3<Float> {
        guard let previous = value, deltaTime > 0 else {
            value = x
            return x
        }
        func alpha(_ cutoff: Float) -> Float {
            let tau = 1 / (2 * .pi * cutoff)
            return 1 / (1 + tau / deltaTime)
        }
        derivative += alpha(derivativeCutoff) * ((x - previous) / deltaTime - derivative)
        let next = previous + alpha(minCutoff + beta * simd_length(derivative)) * (x - previous)
        value = next
        return next
    }
}
