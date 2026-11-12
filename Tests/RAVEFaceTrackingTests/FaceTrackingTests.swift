import RAVEFaceTracking
import Foundation
import Testing
import simd

/// A made-up face laid out as Vision's revision 4 reports one (6-point eyes
/// and brows, 14-point outer lips, 6-point inner lips, a 10-point nose), in an
/// ordinary camera's picture: the face's left on the image's right. Every
/// measure is in the solver's units (eye spacings across, the eye line's
/// height over the nose's base up and down).
struct SyntheticFace {
    var eyeOpen = SIMD2<Float>(0.12, 0.12)      // the face's (left, right)
    var browRaise = SIMD2<Float>(0, 0)           // vertical units, both ends
    var browInnerRaise: Float = 0
    var mouthOpen: Float = 0.03
    var mouthWidth: Float = 0.83
    var cornerLift = SIMD2<Float>(0, 0)
    var pupil = SIMD2<Float>(0, 0)               // half eye widths toward the face's left, vertical units up
    var roll: Float = 0
    var scale: Float = 66                        // pixels per eye spacing
    var offset = SIMD2<Float>(900, 500)
    var vertical: Float = 53                     // pixels: eye line to nose base, unscaled by `scale`
    var mirrored = false

    func landmarks(confidence: Float = 0.9) -> FaceLandmarks {
        let unitX = scale, unitY = vertical * scale / 66
        // The face's left is +x in the picture unless it is a mirror image.
        let flip: Float = mirrored ? -1 : 1
        func p(_ x: Float, _ y: Float) -> SIMD2<Float> {
            let local = SIMD2(x * unitX * flip, y * unitY)
            let c = cos(roll), s = sin(roll)
            return offset + SIMD2(local.x * c - local.y * s, local.x * s + local.y * c)
        }
        // `side` +1 is the face's left.
        func eye(_ side: Float, _ open: Float) -> [SIMD2<Float>] {
            let cx = 0.5 * side, half: Float = 0.2
            return [p(cx - half, 0), p(cx - 0.08, open / 2), p(cx + 0.08, open / 2), p(cx + half, 0),
                    p(cx + 0.08, -open / 2), p(cx - 0.08, -open / 2)]
        }
        func brow(_ side: Float) -> [SIMD2<Float>] {
            let base: Float = 0.28 + (side > 0 ? browRaise.x : browRaise.y)
            let inner = base + browInnerRaise
            // Outer end, middle and inner end (toward the midline), each a
            // top and a bottom point.
            let outerX = 0.8 * side, middleX = 0.5 * side, innerX = 0.2 * side
            return [p(outerX, base + 0.02), p(middleX, (base + inner) / 2 + 0.04), p(innerX, inner + 0.02),
                    p(innerX, inner - 0.02), p(middleX, (base + inner) / 2 - 0.02), p(outerX, base - 0.02)]
        }
        let left = eye(1, eyeOpen.x), right = eye(-1, eyeOpen.y)
        let half = mouthWidth / 2
        let mouthY: Float = -1.35
        // An opening jaw pulls the corners down a little with it, as a real one does.
        let drop = max(0, mouthOpen - 0.03) / 0.5 * 0.08
        let cornerL = p(half, mouthY + cornerLift.x - drop), cornerR = p(-half, mouthY + cornerLift.y - drop)
        var outer: [SIMD2<Float>] = [cornerR]
        for x in stride(from: -half * 0.7, through: half * 0.7, by: half * 0.35) { outer.append(p(x, mouthY + 0.12 + mouthOpen / 2)) }
        outer.append(cornerL)
        for x in stride(from: half * 0.7, through: -half * 0.7, by: -half * 0.35) { outer.append(p(x, mouthY - 0.12 - mouthOpen / 2)) }
        let inner = [p(-0.15, mouthY + mouthOpen / 2), p(0, mouthY + mouthOpen / 2), p(0.15, mouthY + mouthOpen / 2),
                     p(0.15, mouthY - mouthOpen / 2), p(0, mouthY - mouthOpen / 2), p(-0.15, mouthY - mouthOpen / 2)]
        let nose = [p(0, -0.3), p(-0.1, -0.5), p(-0.15, -0.8), p(-0.12, -0.95), p(-0.05, -0.98), p(0, -1.0),
                    p(0.05, -0.98), p(0.12, -0.95), p(0.15, -0.8), p(0.1, -0.5)]
        func pupilAt(_ side: Float) -> SIMD2<Float> { p(0.5 * side + pupil.x * 0.2, pupil.y) }
        // Vision's names follow the picture: its left eye is the one on the image's left.
        let leftIsImageRight = !mirrored
        return FaceLandmarks(
            imageLeftEye: leftIsImageRight ? right : left, imageRightEye: leftIsImageRight ? left : right,
            imageLeftBrow: leftIsImageRight ? brow(-1) : brow(1), imageRightBrow: leftIsImageRight ? brow(1) : brow(-1),
            imageLeftPupil: leftIsImageRight ? pupilAt(-1) : pupilAt(1),
            imageRightPupil: leftIsImageRight ? pupilAt(1) : pupilAt(-1),
            outerLips: outer, innerLips: inner, nose: nose, confidence: confidence)
    }
}

@Suite struct FaceTrackingTests {

    /// A solver that has learnt `rest` as the face at rest.
    func calibrated(_ rest: SyntheticFace = SyntheticFace(), tuning: FaceSolver.Tuning = .init()) -> FaceSolver {
        var solver = FaceSolver(tuning: tuning)
        solver.calibrate(seconds: 0.5)
        for _ in 0..<40 { solver.solve(rest.landmarks(), deltaTime: 1 / 30) }
        return solver
    }

    /// Runs `face` long enough for the smoothing to settle.
    func settle(_ solver: inout FaceSolver, _ face: SyntheticFace, frames: Int = 30) -> FaceReading {
        var reading = FaceReading()
        for _ in 0..<frames { reading = solver.solve(face.landmarks(), deltaTime: 1 / 30) }
        return reading
    }

    @Test func measuresARestingFaceWhereverItIs() throws {
        let plain = try #require(FaceFeatures.measure(SyntheticFace().landmarks(), mirroredImage: false))
        var moved = SyntheticFace()
        moved.roll = 0.3
        moved.scale = 140
        moved.offset = SIMD2(300, 1200)
        let tilted = try #require(FaceFeatures.measure(moved.landmarks(), mirroredImage: false))
        for (a, b) in [(plain.eyeOpen.x, tilted.eyeOpen.x), (plain.mouthWidth, tilted.mouthWidth),
                       (plain.cornerHeight.x, tilted.cornerHeight.x), (plain.browOuter.y, tilted.browOuter.y)] {
            #expect(abs(a - b) < 0.01, "\(a) vs \(b)")
        }
        #expect(abs(plain.eyeOpen.x - 0.12) < 0.01)
        #expect(abs(plain.mouthWidth - 0.83) < 0.01)
        #expect(abs(plain.cornerHeight.x + 1.35) < 0.02)
        #expect(abs(plain.browOuter.x - 0.28) < 0.04)
    }

    @Test func theFacesLeftEyeIsOnTheImagesRight() throws {
        var wink = SyntheticFace()
        wink.eyeOpen = SIMD2(0.01, 0.12)   // the face's left shut
        var solver = calibrated()
        let reading = settle(&solver, wink)
        #expect(reading[.eyeBlinkLeft] > 0.9)
        #expect(reading[.eyeBlinkRight] < 0.1)

        // The same wink in a mirror image, read as one.
        var mirrorTuning = FaceSolver.Tuning()
        mirrorTuning.mirroredImage = true
        var restMirrored = SyntheticFace()
        restMirrored.mirrored = true
        var mirrored = calibrated(restMirrored, tuning: mirrorTuning)
        wink.mirrored = true
        let seen = settle(&mirrored, wink)
        #expect(seen[.eyeBlinkLeft] > 0.9)
        #expect(seen[.eyeBlinkRight] < 0.1)
    }

    @Test func aRestingFaceIsNeutral() {
        var solver = calibrated()
        let reading = settle(&solver, SyntheticFace())
        for (shape, value) in reading.shapes {
            #expect(value < 0.1, "\(shape) \(value)")
        }
        #expect(reading.presence == 1)
    }

    @Test func anOpenMouthOpensTheJaw() {
        var solver = calibrated()
        var face = SyntheticFace()
        face.mouthOpen = 0.35
        let reading = settle(&solver, face)
        #expect(reading[.jawOpen] > 0.55)
    }

    @Test func aSmileLiftsAndSpreadsTheCorners() {
        var solver = calibrated()
        var face = SyntheticFace()
        face.cornerLift = SIMD2(0.12, 0.12)
        face.mouthWidth = 0.95
        let reading = settle(&solver, face)
        #expect(reading[.mouthSmileLeft] > 0.6)
        #expect(reading[.mouthSmileRight] > 0.6)
        #expect(reading[.mouthFrownLeft] < 0.05)
    }

    @Test func aOneSidedSmileStaysOnItsSide() {
        var solver = calibrated()
        var face = SyntheticFace()
        face.cornerLift = SIMD2(0.12, 0)
        let reading = settle(&solver, face)
        #expect(reading[.mouthSmileLeft] > 0.5)
        #expect(reading[.mouthSmileRight] < 0.2)
    }

    @Test func droppedCornersFrown() {
        var solver = calibrated()
        var face = SyntheticFace()
        face.cornerLift = SIMD2(-0.08, -0.08)
        let reading = settle(&solver, face)
        #expect(reading[.mouthFrownLeft] > 0.7)
        #expect(reading[.mouthSmileLeft] < 0.05)
    }

    @Test func aNarrowMouthPuckers() {
        var solver = calibrated()
        var face = SyntheticFace()
        face.mouthWidth = 0.62
        let reading = settle(&solver, face)
        #expect(reading[.mouthPucker] > 0.7)
    }

    @Test func browsGoUpAndDown() {
        var solver = calibrated()
        var up = SyntheticFace()
        up.browRaise = SIMD2(0.08, 0.08)
        up.browInnerRaise = 0.0
        var reading = settle(&solver, up)
        #expect(reading[.browOuterUpLeft] > 0.7)
        #expect(reading[.browOuterUpRight] > 0.7)
        #expect(reading[.browDownLeft] < 0.05)

        var down = SyntheticFace()
        down.browRaise = SIMD2(-0.06, -0.06)
        reading = settle(&solver, down, frames: 40)
        #expect(reading[.browDownLeft] > 0.7)
        #expect(reading[.browOuterUpLeft] < 0.05)
    }

    @Test func aBrowWanderingNearRestStaysAtRest() {
        // A Persona's brows drift about 0.02 either way on a still face.
        var solver = calibrated()
        for drift in [Float(0.018), -0.018] {
            var face = SyntheticFace()
            face.browRaise = SIMD2(drift, drift)
            let reading = settle(&solver, face, frames: 40)
            #expect(reading[.browOuterUpLeft] < 0.02)
            #expect(reading[.browInnerUp] < 0.02)
            #expect(reading[.browDownLeft] < 0.02)
            #expect(reading[.browDownRight] < 0.02)
        }
    }

    @Test func wideEyesAndBlinks() {
        var solver = calibrated()
        var wide = SyntheticFace()
        wide.eyeOpen = SIMD2(0.17, 0.17)
        var reading = settle(&solver, wide)
        #expect(reading[.eyeWideLeft] > 0.8)
        #expect(reading[.eyeBlinkLeft] < 0.05)
        var shut = SyntheticFace()
        shut.eyeOpen = SIMD2(0.0, 0.0)
        reading = settle(&solver, shut, frames: 10)
        #expect(reading[.eyeBlinkLeft] > 0.95)
        #expect(reading[.eyeBlinkRight] > 0.95)
    }

    @Test func aBlinkIsQuick() {
        // A blink lasts about a tenth of a second: three frames shut must
        // read as well shut, not be smoothed away.
        var solver = calibrated()
        var shut = SyntheticFace()
        shut.eyeOpen = SIMD2(0.0, 0.0)
        var deepest: Float = 0
        for _ in 0..<3 { deepest = max(deepest, solver.solve(shut.landmarks(), deltaTime: 1 / 30)[.eyeBlinkLeft]) }
        #expect(deepest > 0.6, "\(deepest)")
    }

    @Test func learnsTheRestFaceWithoutBeingTold() {
        // Eyes naturally wider than the typical face's: watched a while, they
        // stop reading as wide.
        var solver = FaceSolver()
        var face = SyntheticFace()
        face.eyeOpen = SIMD2(0.16, 0.16)
        face.mouthWidth = 0.92
        let first = solver.solve(face.landmarks(), deltaTime: 1 / 30)
        #expect(first[.eyeWideLeft] > 0.5)
        let later = settle(&solver, face, frames: 120)
        #expect(later[.eyeWideLeft] < 0.1, "\(later[.eyeWideLeft])")
        #expect(later[.mouthSmileLeft] < 0.15, "\(later[.mouthSmileLeft])")
    }

    @Test func aLostFaceFadesOut() {
        var solver = calibrated()
        var face = SyntheticFace()
        face.mouthOpen = 0.3
        _ = settle(&solver, face)
        var reading = solver.solve(nil, deltaTime: 0.1)
        #expect(reading.presence > 0.5)
        #expect(reading[.jawOpen] > 0.2)
        for _ in 0..<5 { reading = solver.solve(nil, deltaTime: 0.1) }
        #expect(reading.presence == 0)
        #expect(reading.shapes.isEmpty)
        // An unsure face counts as none.
        reading = solver.solve(face.landmarks(confidence: 0.1), deltaTime: 0.1)
        #expect(reading.presence == 0)
    }

    @Test func pupilsSayWhereTheEyesLook() throws {
        var solver = calibrated()
        var face = SyntheticFace()
        face.pupil = SIMD2(0.5, 0)    // toward the face's left
        let reading = settle(&solver, face)
        let look = try #require(reading.look)
        #expect(look.left.x > 0.2)
        #expect(look.right.x > 0.2)
    }

    @Test func clearingTheCalibrationLearnsAgain() {
        var solver = calibrated()
        #expect(solver.calibrated != nil)
        solver.clearCalibration()
        #expect(solver.calibrated == nil)
        #expect(solver.neutral == .typical)
    }
}

@Suite struct EyeLookTests {

    @Test func gazeToTheWearersLeftIsAPositiveYaw() {
        let look = EyeLook.gaze(simd_normalize(SIMD3<Float>(-0.3, 0, -1)))
        #expect(look.left.x > 0.25)
        #expect(abs(look.left.x - look.right.x) < 1e-5)
        let up = EyeLook.gaze(simd_normalize(SIMD3<Float>(0, 0.3, -1)))
        #expect(up.left.y > 0.25)
    }

    @Test func nearPointsConverge() {
        let look = EyeLook.gaze(SIMD3(0, 0, -1), distance: 0.4)
        // Each eye turns toward the nose: the left to the face's right.
        #expect(look.left.x < -0.05)
        #expect(look.right.x > 0.05)
        #expect(look.shapes[.eyeLookInLeft] ?? 0 > 0.05)
        #expect(look.shapes[.eyeLookInRight] ?? 0 > 0.05)
        #expect(look.shapes[.eyeLookOutLeft] ?? 0 == 0)
    }

    @Test func aMirrorSwapsTheEyesAndTurnsThemRound() {
        let look = EyeLook(left: SIMD2(0.3, 0.1), right: SIMD2(0.2, 0.1))
        let seen = look.mirrored
        #expect(seen.left == SIMD2(-0.2, 0.1))
        #expect(seen.right == SIMD2(-0.3, 0.1))
        #expect(FaceBlendShape.eyeBlinkLeft.mirrored == .eyeBlinkRight)
        #expect(FaceBlendShape.mouthLeft.mirrored == .mouthRight)
        #expect(FaceBlendShape.jawOpen.mirrored == .jawOpen)
        #expect(FaceBlendShape.allCases.count == 52)
    }

    @Test func limitsHold() {
        let look = EyeLook.gaze(SIMD3(-1, 0, 0))
        #expect(look.left.x == EyeLook.yawLimit)
    }
}

