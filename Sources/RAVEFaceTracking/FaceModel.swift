import Foundation
import simd

// RAVEFaceTracking: a face from a camera, landmarks in, ARKit-style blend
// shape weights out. spatial-ai-character drives an avatar with it in perform
// mode; Longwave is to send it to VRChat over OSC (`VRChatFaceOSC`).
//
// visionOS gives an app no face tracking, but it gives it the wearer's Persona
// as its only camera, and the Persona's face is the system's own reading of
// the wearer's, from the cameras inside the headset: it blinks, frowns and
// talks when they do. Vision finds the landmarks in that picture; this turns
// them into the weights an avatar's shape keys take. Everything here is
// framework-free so it can be tested on the Mac with made-up faces. The capture and Vision
// half is `RAVEPersonaFaceTracker`.

/// ARKit's 52 face blend shapes, by ARKit's names, which avatars made for face
/// tracking ("Perfect Sync") carry as shape keys. Left and right are the
/// face's own, not the camera's.
public enum FaceBlendShape: String, CaseIterable, Sendable, Codable {
    case eyeBlinkLeft, eyeLookDownLeft, eyeLookInLeft, eyeLookOutLeft, eyeLookUpLeft, eyeSquintLeft, eyeWideLeft
    case eyeBlinkRight, eyeLookDownRight, eyeLookInRight, eyeLookOutRight, eyeLookUpRight, eyeSquintRight, eyeWideRight
    case jawForward, jawLeft, jawRight, jawOpen
    case mouthClose, mouthFunnel, mouthPucker, mouthLeft, mouthRight
    case mouthSmileLeft, mouthSmileRight, mouthFrownLeft, mouthFrownRight
    case mouthDimpleLeft, mouthDimpleRight, mouthStretchLeft, mouthStretchRight
    case mouthRollLower, mouthRollUpper, mouthShrugLower, mouthShrugUpper
    case mouthPressLeft, mouthPressRight, mouthLowerDownLeft, mouthLowerDownRight, mouthUpperUpLeft, mouthUpperUpRight
    case browDownLeft, browDownRight, browInnerUp, browOuterUpLeft, browOuterUpRight
    case cheekPuff, cheekSquintLeft, cheekSquintRight
    case noseSneerLeft, noseSneerRight
    case tongueOut

    /// The same shape on the other side of the face: what a mirror shows.
    /// `jawLeft` and `mouthLeft` name a direction rather than a side, and a
    /// mirror turns that round too.
    public var mirrored: FaceBlendShape {
        let name = rawValue
        if name.hasSuffix("Left") { return FaceBlendShape(rawValue: name.dropLast(4) + "Right") ?? self }
        if name.hasSuffix("Right") { return FaceBlendShape(rawValue: name.dropLast(5) + "Left") ?? self }
        return self
    }
}

/// Where each eye looks, relative to the head: radians, yaw toward the face's
/// own left, pitch up. Both zero is straight ahead.
public struct EyeLook: Sendable, Equatable {
    public var left: SIMD2<Float>
    public var right: SIMD2<Float>

    public init(left: SIMD2<Float>, right: SIMD2<Float>) {
        self.left = left
        self.right = right
    }

    public static let ahead = EyeLook(left: .zero, right: .zero)

    /// What a mirror shows: each eye takes the other's look, turned round.
    public var mirrored: EyeLook {
        EyeLook(left: SIMD2(-right.x, right.y), right: SIMD2(-left.x, left.y))
    }

    /// How far eyes turn at most: about what people turn them before the
    /// head follows.
    public static let yawLimit: Float = 0.6
    public static let pitchLimit: Float = 0.45

    public func clamped() -> EyeLook {
        func clamp(_ v: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2(max(-Self.yawLimit, min(Self.yawLimit, v.x)), max(-Self.pitchLimit, min(Self.pitchLimit, v.y)))
        }
        return EyeLook(left: clamp(left), right: clamp(right))
    }

    /// From a gaze direction in head space (-z ahead, +x the wearer's right,
    /// +y up), as eye trackers report it. With a focus distance the eyes
    /// converge on the point, each from its own side of the head.
    public static func gaze(_ direction: SIMD3<Float>, distance: Float? = nil,
                            interpupillary: Float = 0.063) -> EyeLook {
        guard simd_length(direction) > 1e-4 else { return .ahead }
        let d = simd_normalize(direction)
        func angles(_ v: SIMD3<Float>) -> SIMD2<Float> {
            let n = simd_normalize(v)
            return SIMD2(atan2(-n.x, -n.z), asin(max(-1, min(1, n.y))))
        }
        guard let distance, distance > 0.1, distance < 20 else {
            let both = angles(d)
            return EyeLook(left: both, right: both).clamped()
        }
        let point = d * distance
        let half = interpupillary / 2
        // The wearer's left eye sits at -x in head space.
        return EyeLook(left: angles(point - SIMD3(-half, 0, 0)), right: angles(point - SIMD3(half, 0, 0))).clamped()
    }

    /// The look as ARKit's eye shapes. "In" is toward the nose: for the left
    /// eye that is a look to the face's right.
    public var shapes: [FaceBlendShape: Float] {
        func unit(_ v: Float, _ limit: Float) -> Float { max(0, min(1, v / limit)) }
        return [
            .eyeLookOutLeft: unit(left.x, Self.yawLimit), .eyeLookInLeft: unit(-left.x, Self.yawLimit),
            .eyeLookUpLeft: unit(left.y, Self.pitchLimit), .eyeLookDownLeft: unit(-left.y, Self.pitchLimit),
            .eyeLookInRight: unit(right.x, Self.yawLimit), .eyeLookOutRight: unit(-right.x, Self.yawLimit),
            .eyeLookUpRight: unit(right.y, Self.pitchLimit), .eyeLookDownRight: unit(-right.y, Self.pitchLimit),
        ]
    }
}

/// One face's landmarks in one camera frame, in image pixels with y up, as
/// Vision reports them: its `leftEye` is the eye on the image's left, whoever's
/// eye that is.
public struct FaceLandmarks: Sendable, Equatable {
    public var imageLeftEye: [SIMD2<Float>]
    public var imageRightEye: [SIMD2<Float>]
    public var imageLeftBrow: [SIMD2<Float>]
    public var imageRightBrow: [SIMD2<Float>]
    public var imageLeftPupil: SIMD2<Float>?
    public var imageRightPupil: SIMD2<Float>?
    public var outerLips: [SIMD2<Float>]
    public var innerLips: [SIMD2<Float>]
    public var nose: [SIMD2<Float>]
    /// The face's turn in the picture, radians, as Vision estimates it.
    public var yaw: Float
    public var pitch: Float
    public var roll: Float
    /// 0…1.
    public var confidence: Float

    public init(imageLeftEye: [SIMD2<Float>], imageRightEye: [SIMD2<Float>], imageLeftBrow: [SIMD2<Float>],
                imageRightBrow: [SIMD2<Float>], imageLeftPupil: SIMD2<Float>?, imageRightPupil: SIMD2<Float>?,
                outerLips: [SIMD2<Float>], innerLips: [SIMD2<Float>], nose: [SIMD2<Float>],
                yaw: Float = 0, pitch: Float = 0, roll: Float = 0, confidence: Float = 1) {
        self.imageLeftEye = imageLeftEye
        self.imageRightEye = imageRightEye
        self.imageLeftBrow = imageLeftBrow
        self.imageRightBrow = imageRightBrow
        self.imageLeftPupil = imageLeftPupil
        self.imageRightPupil = imageRightPupil
        self.outerLips = outerLips
        self.innerLips = innerLips
        self.nose = nose
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.confidence = confidence
    }

    /// Every point, for drawing.
    public var allPoints: [SIMD2<Float>] {
        imageLeftEye + imageRightEye + imageLeftBrow + imageRightBrow + outerLips + innerLips + nose
            + [imageLeftPupil, imageRightPupil].compactMap { $0 }
    }
}

/// What the landmarks measure, in the face's own frame: the eye line is
/// horizontal, distances across are in eye spacings (the distance between the
/// eyes' centres) and distances up and down in the eye line's height above
/// the base of the nose. Both units shrink with the face as it turns or tilts
/// away, so their ratios hold. Pairs are (left, right), the face's own.
public struct FaceFeatures: Sendable, Equatable, Codable {
    /// Each eye's lid gap.
    public var eyeOpen: SIMD2<Float>
    /// Each brow's inner and outer end above the eye line.
    public var browInner: SIMD2<Float>
    public var browOuter: SIMD2<Float>
    /// The gap between the lips.
    public var mouthOpen: Float
    /// Corner to corner.
    public var mouthWidth: Float
    /// Each corner's height above the eye line (negative: it is below).
    public var cornerHeight: SIMD2<Float>
    /// Each corner's distance from the face's midline.
    public var cornerSpread: SIMD2<Float>
    /// The mouth's centre off the nose's midline, toward the face's left.
    public var mouthShift: Float
    /// Each pupil off its eye's centre: across in half eye widths (toward the
    /// face's left), up in the vertical unit. Nil when Vision gave none.
    public var leftPupil: SIMD2<Float>?
    public var rightPupil: SIMD2<Float>?

    public init(eyeOpen: SIMD2<Float>, browInner: SIMD2<Float>, browOuter: SIMD2<Float>, mouthOpen: Float,
                mouthWidth: Float, cornerHeight: SIMD2<Float>, cornerSpread: SIMD2<Float>, mouthShift: Float,
                leftPupil: SIMD2<Float>? = nil, rightPupil: SIMD2<Float>? = nil) {
        self.eyeOpen = eyeOpen
        self.browInner = browInner
        self.browOuter = browOuter
        self.mouthOpen = mouthOpen
        self.mouthWidth = mouthWidth
        self.cornerHeight = cornerHeight
        self.cornerSpread = cornerSpread
        self.mouthShift = mouthShift
        self.leftPupil = leftPupil
        self.rightPupil = rightPupil
    }

    /// A relaxed face, from Vision's landmarks on two portraits: what the
    /// solver assumes until it has watched this face for a while.
    public static let typical = FaceFeatures(
        eyeOpen: SIMD2(repeating: 0.12), browInner: SIMD2(repeating: 0.28), browOuter: SIMD2(repeating: 0.28),
        mouthOpen: 0.03, mouthWidth: 0.83, cornerHeight: SIMD2(repeating: -1.35),
        cornerSpread: SIMD2(repeating: 0.415), mouthShift: 0,
        leftPupil: .zero, rightPupil: .zero)

    /// Measures `landmarks`. `mirroredImage` says the picture is a mirror
    /// image, its left the face's left; an ordinary camera's is not, so the
    /// face's left eye is the one on the image's right. Nil when a part the
    /// measures need is missing or degenerate.
    public static func measure(_ landmarks: FaceLandmarks, mirroredImage: Bool) -> FaceFeatures? {
        let l = landmarks
        guard l.imageLeftEye.count >= 4, l.imageRightEye.count >= 4, l.outerLips.count >= 4,
              l.nose.count >= 3 else { return nil }
        let leftCentre = centre(l.imageLeftEye), rightCentre = centre(l.imageRightEye)
        let across = rightCentre - leftCentre
        let spacing = simd_length(across)
        guard spacing > 1 else { return nil }
        // The face's frame: x along the eye line toward the image's right, y up.
        let ex = across / spacing
        let ey = SIMD2(-ex.y, ex.x)
        let origin = (leftCentre + rightCentre) / 2
        func local(_ p: SIMD2<Float>) -> SIMD2<Float> {
            let d = p - origin
            return SIMD2(simd_dot(d, ex) / spacing, simd_dot(d, ey))
        }
        let nose = l.nose.map(local)
        let noseBase = nose.map(\.y).min() ?? 0
        let vertical = -noseBase
        guard vertical > spacing * 0.15 else { return nil }
        // Both coordinates in their units: x in spacings, y in the vertical one.
        func face(_ p: SIMD2<Float>) -> SIMD2<Float> {
            let q = local(p)
            return SIMD2(q.x, q.y / vertical)
        }
        let midline = nose.map(\.x).reduce(0, +) / Float(nose.count)

        // An eye: its corners are the points furthest across, the lids the
        // rest above and below the line between them.
        func eye(_ points: [SIMD2<Float>]) -> (open: Float, centre: SIMD2<Float>, halfWidth: Float) {
            let p = points.map(face)
            let a = p.min { $0.x < $1.x }!, b = p.max { $0.x < $1.x }!
            let width = max(b.x - a.x, 1e-4)
            func line(_ x: Float) -> Float { a.y + (b.y - a.y) * (x - a.x) / width }
            var upper: [Float] = [], lower: [Float] = []
            for q in p where q != a && q != b {
                let off = q.y - line(q.x)
                if off >= 0 { upper.append(off) } else { lower.append(off) }
            }
            let up = upper.isEmpty ? 0 : upper.reduce(0, +) / Float(upper.count)
            let down = lower.isEmpty ? 0 : lower.reduce(0, +) / Float(lower.count)
            return (max(0, up - down), (a + b) / 2, width / 2)
        }
        let imageLeft = eye(l.imageLeftEye), imageRight = eye(l.imageRightEye)

        // A brow: inner end nearest the midline, outer furthest, two points each.
        func brow(_ points: [SIMD2<Float>], eyeCentre: SIMD2<Float>) -> (inner: Float, outer: Float)? {
            guard points.count >= 2 else { return nil }
            let p = points.map(face).sorted { abs($0.x - midline) < abs($1.x - midline) }
            let n = min(2, p.count)
            let inner = p.prefix(n).map(\.y).reduce(0, +) / Float(n) - eyeCentre.y
            let outer = p.suffix(n).map(\.y).reduce(0, +) / Float(n) - eyeCentre.y
            return (inner, outer)
        }
        let typical = FaceFeatures.typical
        let leftBrow = brow(l.imageLeftBrow, eyeCentre: imageLeft.centre)
            ?? (typical.browInner.x, typical.browOuter.x)
        let rightBrow = brow(l.imageRightBrow, eyeCentre: imageRight.centre)
            ?? (typical.browInner.y, typical.browOuter.y)

        // The mouth.
        let outer = l.outerLips.map(face)
        let cornerA = outer.min { $0.x < $1.x }!, cornerB = outer.max { $0.x < $1.x }!
        let mouthWidth = cornerB.x - cornerA.x
        var mouthOpen: Float = 0
        if l.innerLips.count >= 3 {
            let inner = l.innerLips.map(face)
            func line(_ x: Float) -> Float {
                cornerA.y + (cornerB.y - cornerA.y) * (x - cornerA.x) / max(mouthWidth, 1e-4)
            }
            // The inner lips' upper edge against their lower one, across the
            // middle of the mouth, where the gap is.
            let middle = inner.filter { abs($0.x - (cornerA.x + cornerB.x) / 2) < mouthWidth * 0.3 }
            let points = middle.count >= 2 ? middle : inner
            let offs = points.map { $0.y - line($0.x) }
            mouthOpen = max(0, (offs.max() ?? 0) - (offs.min() ?? 0))
        }

        func pupil(_ p: SIMD2<Float>?, _ eye: (open: Float, centre: SIMD2<Float>, halfWidth: Float)) -> SIMD2<Float>? {
            guard let p else { return nil }
            let q = face(p) - eye.centre
            return SIMD2(q.x / max(eye.halfWidth, 1e-4), q.y)
        }
        let leftPupil = pupil(l.imageLeftPupil, imageLeft), rightPupil = pupil(l.imageRightPupil, imageRight)

        // Into the face's own sides. An ordinary camera shows the face's left
        // on the image's right, and its left is then +x.
        let flip: Float = mirroredImage ? -1 : 1
        let shift = ((cornerA.x + cornerB.x) / 2 - midline) * flip
        func spread(_ c: SIMD2<Float>) -> Float { abs(c.x - midline) }
        func sided(_ p: SIMD2<Float>?) -> SIMD2<Float>? { p.map { SIMD2($0.x * flip, $0.y) } }
        if mirroredImage {
            return FaceFeatures(
                eyeOpen: SIMD2(imageLeft.open, imageRight.open),
                browInner: SIMD2(leftBrow.inner, rightBrow.inner), browOuter: SIMD2(leftBrow.outer, rightBrow.outer),
                mouthOpen: mouthOpen, mouthWidth: mouthWidth,
                cornerHeight: SIMD2(cornerA.y, cornerB.y), cornerSpread: SIMD2(spread(cornerA), spread(cornerB)),
                mouthShift: shift, leftPupil: sided(leftPupil), rightPupil: sided(rightPupil))
        }
        return FaceFeatures(
            eyeOpen: SIMD2(imageRight.open, imageLeft.open),
            browInner: SIMD2(rightBrow.inner, leftBrow.inner), browOuter: SIMD2(rightBrow.outer, leftBrow.outer),
            mouthOpen: mouthOpen, mouthWidth: mouthWidth,
            cornerHeight: SIMD2(cornerB.y, cornerA.y), cornerSpread: SIMD2(spread(cornerB), spread(cornerA)),
            mouthShift: shift, leftPupil: sided(rightPupil), rightPupil: sided(leftPupil))
    }

    private static func centre(_ points: [SIMD2<Float>]) -> SIMD2<Float> {
        // The corners' midpoint: an eye's contour bunches its points round
        // the lids, so their mean drifts with how open it is.
        let a = points.min { $0.x < $1.x }!, b = points.max { $0.x < $1.x }!
        return (a + b) / 2
    }
}

/// One frame's face: the blend shape weights, where the pupils say the eyes
/// look, and how sure the reading is.
public struct FaceReading: Sendable, Equatable {
    /// Only the shapes the solver measures; the rest are zero.
    public var shapes: [FaceBlendShape: Float] = [:]
    /// From the pupils, when Vision found them. Coarse: an eye tracker's gaze
    /// is better wherever there is one.
    public var look: EyeLook?
    /// 1 while the face is seen, easing to 0 over a short while after it is
    /// lost: how much of this reading to use over what stands in for it.
    public var presence: Float = 0
    public var features: FaceFeatures?
    /// The face's turn in the picture (yaw, pitch, roll), radians.
    public var headAngles: SIMD3<Float> = .zero
    public var confidence: Float = 0

    public init() {}

    public subscript(_ shape: FaceBlendShape) -> Float { shapes[shape] ?? 0 }
}

