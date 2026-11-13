import CoreVideo
import Foundation
import RAVEFaceTracking
import Testing
import simd

/// The face mesh reader's arithmetic, and the solver's path for a reader
/// whose model scores the blend shapes itself.
@Suite struct FaceMeshTests {

    // MARK: - The detector's output

    @Test func theDetectorHas896AnchorsInTwoGrids() {
        #expect(FaceMesh.anchors.count == 896)
        #expect(FaceMesh.anchors[0] == SIMD2(0.5 / 16, 0.5 / 16))
        #expect(FaceMesh.anchors[1] == FaceMesh.anchors[0])
        #expect(FaceMesh.anchors[2] == SIMD2(1.5 / 16, 0.5 / 16))
        #expect(FaceMesh.anchors[512] == SIMD2(0.5 / 8, 0.5 / 8))
        #expect(FaceMesh.anchors[895] == SIMD2(7.5 / 8, 7.5 / 8))
    }

    @Test func aDetectionDecodesIntoThePicture() throws {
        // A 1000 × 500 picture sits in the 128 square at 0.128 scale, 32 down.
        let box = FaceMesh.Letterbox(width: 1000, height: 500)
        #expect(abs(box.scale - 0.128) < 1e-6)
        #expect(box.offset == SIMD2(0, 32))

        var scores = [Float](repeating: -20, count: 896)
        var regressors = [Float](repeating: 0, count: 896 * 16)
        // Anchor 600 is on the 8×8 grid: (600 − 512) / 6 = cell 14, row 1, column 6.
        let anchor = FaceMesh.anchors[600] * 128
        #expect(anchor == SIMD2(6.5 * 16, 1.5 * 16))
        scores[600] = 4
        // Off the anchor by (2, 3), 20 × 24 big; the eyes 4 either side, the left one higher.
        regressors.replaceSubrange((600 * 16)..<(600 * 16 + 8), with: [2, 3, 20, 24, -4, -6, 4, -5])
        let found = try #require(FaceMesh.detection(regressors: regressors, scores: scores, letterbox: box))
        #expect(abs(found.score - 1 / (1 + exp(-4))) < 1e-5)
        #expect(simd_distance(found.centre, SIMD2((104 + 2) / 0.128, (24 + 3 - 32) / 0.128)) < 0.01)
        #expect(simd_distance(found.size, SIMD2(20, 24) / 0.128) < 0.01)
        #expect(simd_distance(found.keypoints[0], SIMD2((104 - 4) / 0.128, (24 - 6 - 32) / 0.128)) < 0.01)

        // The square: half as big again as the box's long side, turned to the eye line.
        let region = found.region
        #expect(abs(region.side - 24 / 0.128 * 1.5) < 0.01)
        #expect(abs(region.rotation - atan2(1, 8)) < 1e-4)

        // Nothing sure enough is no face.
        scores[600] = -1
        #expect(FaceMesh.detection(regressors: regressors, scores: scores, letterbox: box) == nil)
    }

    // MARK: - The crop

    @Test func aRegionMapsThereAndBack() {
        let region = FaceMeshRegion(centre: SIMD2(700, 420), side: 512, rotation: 0.4)
        #expect(simd_distance(region.toImage(SIMD2(128, 128)), SIMD2(700, 420)) < 1e-3)
        // The crop's x axis points along the eye line, two picture pixels to one of the crop.
        #expect(simd_distance(region.toImage(SIMD2(129, 128)), SIMD2(700 + 2 * cos(0.4), 420 + 2 * sin(0.4))) < 1e-3)
        for p in [SIMD2<Float>(0, 0), SIMD2(256, 40), SIMD2(13.5, 201)] {
            #expect(simd_distance(region.toCrop(region.toImage(p)), p) < 1e-3)
        }
    }

    /// A mesh of 478 points: a 200 × 260 face about `centre`, turned by
    /// `roll`, the image-left eye's corner at index 33 unless `mirrored`.
    func mesh(centre: SIMD2<Float> = SIMD2(640, 500), roll: Float = 0, mirrored: Bool = false) -> [SIMD3<Float>] {
        let c = cos(roll), s = sin(roll)
        func p(_ x: Float, _ y: Float, _ z: Float = 0) -> SIMD3<Float> {
            let x = mirrored ? -x : x
            return SIMD3(centre.x + x * c - y * s, centre.y + x * s + y * c, z)
        }
        // Everything else sits on the face's outline box.
        var points = (0..<478).map { i in p(i % 2 == 0 ? -100 : 100, i % 4 < 2 ? -130 : 130) }
        // The eyes (y down: −40 is above the centre), "A" on the image's left.
        for (i, x) in zip([33, 246, 161, 160, 159, 158, 157, 173, 133], stride(from: Float(-70), through: -30, by: 5)) {
            points[i] = p(x, -40 - (i == 33 || i == 133 ? 0 : 6))
        }
        for (i, x) in zip([7, 163, 144, 145, 153, 154, 155], stride(from: Float(-65), through: -35, by: 5)) { points[i] = p(x, -34) }
        for (i, x) in zip([263, 466, 388, 387, 386, 385, 384, 398, 362], stride(from: Float(70), through: 30, by: -5)) {
            points[i] = p(x, -40 - (i == 263 || i == 362 ? 0 : 6))
        }
        for (i, x) in zip([249, 390, 373, 374, 380, 381, 382], stride(from: Float(65), through: 35, by: -5)) { points[i] = p(x, -34) }
        points[468] = p(-50, -40)
        points[473] = p(50, -40)
        for (k, i) in [70, 63, 105, 66, 107, 55, 65, 52, 53, 46].enumerated() { points[i] = p(-80 + Float(k % 5) * 12, -70 + Float(k / 5) * 6) }
        for (k, i) in [300, 293, 334, 296, 336, 285, 295, 282, 283, 276].enumerated() { points[i] = p(80 - Float(k % 5) * 12, -70 + Float(k / 5) * 6) }
        for (k, i) in [168, 6, 197, 195, 5, 4, 1, 2].enumerated() { points[i] = p(0, -40 + Float(k) * 9) }
        points[98] = p(-12, 20)
        points[327] = p(12, 20)
        let outer = [61, 146, 91, 181, 84, 17, 314, 405, 321, 375, 291, 409, 270, 269, 267, 0, 37, 39, 40, 185]
        let inner = [78, 95, 88, 178, 87, 14, 317, 402, 318, 324, 308, 415, 310, 311, 312, 13, 82, 81, 80, 191]
        for (ring, half, lip) in [(outer, Float(42), Float(12)), (inner, Float(34), Float(3))] {
            for (k, i) in ring.enumerated() {
                let a = Float(k) / 20 * 2 * .pi
                points[i] = p(-half * cos(a), 70 + lip * sin(a))
            }
        }
        points[10] = p(0, -130)
        points[152] = p(0, 130)
        return points
    }

    @Test func theNextCropFollowsTheMesh() throws {
        let region = try #require(FaceMesh.region(following: mesh(roll: 0.25)))
        #expect(simd_distance(region.centre, SIMD2(640, 500)) < 0.5)
        #expect(abs(region.side - 260 * 1.5) < 0.5)
        #expect(abs(region.rotation - 0.25) < 1e-3)
    }

    @Test func theMeshModelsPointsLandInThePicture() {
        let region = FaceMeshRegion(centre: SIMD2(300, 200), side: 512, rotation: .pi / 2)
        let points = FaceMesh.imagePoints([128, 128, 0, 138, 128, -5], region: region)
        #expect(simd_distance(points[0], SIMD3(300, 200, 0)) < 1e-3)
        // Ten crop pixels along the crop's x, which points down the picture here.
        #expect(simd_distance(points[1], SIMD3(300, 220, -10)) < 1e-3)
    }

    // MARK: - The mesh as landmarks

    @Test func meshLandmarksGoByWhereAPartIsInThePicture() throws {
        let l = try #require(FaceMesh.landmarks(mesh(), height: 1000, confidence: 0.9))
        // y is up in landmarks: the eyes at 500 − 40 down are at 540 up.
        #expect(l.imageLeftEye.allSatisfy { $0.x < 640 && $0.y > 530 })
        #expect(l.imageRightEye.allSatisfy { $0.x > 640 })
        #expect(l.imageLeftBrow.allSatisfy { $0.x < 640 })
        #expect(l.imageLeftPupil == SIMD2(590, 540))
        #expect(l.imageRightPupil == SIMD2(690, 540))
        let features = try #require(FaceFeatures.measure(l, mirroredImage: false))
        #expect(features.eyeOpen.x > 0.05 && abs(features.eyeOpen.x - features.eyeOpen.y) < 1e-3)
        #expect(features.browInner.x > 0.2)

        // Read from a mirror image the mesh's "A" side is on the image's
        // right; the landmarks' sides are still the picture's.
        let m = try #require(FaceMesh.landmarks(mesh(mirrored: true), height: 1000, confidence: 0.9))
        #expect(m.imageLeftEye.allSatisfy { $0.x < 640 })
        #expect(m.imageLeftPupil == SIMD2(590, 540))
    }

    @Test func headAnglesFollowVisionsSenses() {
        // Tilted clockwise as seen: the image-right eye lower.
        #expect(abs(FaceMesh.headAngles(mesh(roll: 0.3)).z - 0.3) < 1e-3)
        // Turned toward the image's right: that side is further away.
        var turned = mesh()
        turned[263].z = 40
        turned[33].z = -40
        #expect(FaceMesh.headAngles(turned).x > 0.4)
        // Tipped back: the chin nearer than the forehead.
        var tipped = mesh()
        tipped[152].z = -60
        tipped[10].z = 60
        #expect(FaceMesh.headAngles(tipped).y < -0.3)
    }

    // MARK: - The blend shape model's ends

    @Test func theBlendShapeModelsInputsAndOutputsLineUp() {
        #expect(FaceMesh.blendShapeInputs.count == 146)
        #expect(Set(FaceMesh.blendShapeInputs).count == 146)
        #expect(FaceMesh.blendShapeInputs.allSatisfy { $0 < 478 })
        #expect(FaceMesh.blendShapeOutputs.count == 52)
        #expect(FaceMesh.blendShapeOutputs[0] == nil)
        #expect(FaceMesh.blendShapeOutputs[9] == .eyeBlinkLeft)
        #expect(FaceMesh.blendShapeOutputs[10] == .eyeBlinkRight)
        #expect(FaceMesh.blendShapeOutputs[25] == .jawOpen)
        // Every ARKit shape but the tongue, once each.
        let shapes = FaceMesh.blendShapeOutputs.compactMap { $0 }
        #expect(Set(shapes) == Set(FaceBlendShape.allCases).subtracting([.tongueOut]))

        var scores = [Float](repeating: 0, count: 52)
        scores[9] = 0.7
        #expect(FaceMesh.blendShapes(scores)[.eyeBlinkLeft] == 0.7)
        #expect(FaceMesh.blendShapes(scores)[.eyeBlinkRight] == 0)

        // The points go in about their own middle.
        let input = FaceMesh.blendShapeInput(mesh(centre: SIMD2(1500, 900)))
        #expect(input.count == 292)
        let xs = stride(from: 0, to: 292, by: 2).map { input[$0] }
        #expect(abs(xs.reduce(0, +)) < 0.05)
        #expect(xs.allSatisfy { abs($0) <= 201 })
    }

    // MARK: - The solver, from a model's scores

    /// A resting face's scores, as the model gives them: nothing is quite 0.
    static let rest: [FaceBlendShape: Float] = [
        .eyeBlinkLeft: 0.08, .eyeBlinkRight: 0.08, .eyeSquintLeft: 0.2, .eyeSquintRight: 0.2,
        .browDownLeft: 0.1, .browDownRight: 0.1, .browInnerUp: 0.05, .jawOpen: 0.02,
        .mouthSmileLeft: 0.03, .mouthSmileRight: 0.03, .eyeLookInLeft: 0.3,
    ]

    func landmarks(_ scores: [FaceBlendShape: Float], mirrored: Bool = false) -> FaceLandmarks {
        var face = SyntheticFace()
        face.mirrored = mirrored
        var l = face.landmarks()
        l.modelShapes = Self.rest.merging(scores) { $1 }
        return l
    }

    func calibrated(tuning: FaceSolver.Tuning = .init(), mirrored: Bool = false) -> FaceSolver {
        var solver = FaceSolver(tuning: tuning)
        solver.calibrate(seconds: 0.5)
        for _ in 0..<40 { solver.solve(landmarks([:], mirrored: mirrored), deltaTime: 1 / 30) }
        return solver
    }

    func settle(_ solver: inout FaceSolver, _ scores: [FaceBlendShape: Float], mirrored: Bool = false) -> FaceReading {
        var reading = FaceReading()
        for _ in 0..<30 { reading = solver.solve(landmarks(scores, mirrored: mirrored), deltaTime: 1 / 30) }
        return reading
    }

    @Test func aRestingFacesScoresAreNeutral() {
        var solver = calibrated()
        #expect(solver.modelNeutral[.eyeSquintLeft] == 0.2)
        let reading = settle(&solver, [:])
        #expect(reading.presence == 1)
        #expect(reading.shapes.values.allSatisfy { $0 < 0.02 }, "\(reading.shapes.filter { $0.value >= 0.02 })")
        // Where the eyes look is `look`'s to say, not a shape's.
        #expect(reading.shapes[.eyeLookInLeft] == nil)
    }

    /// The point of the second reader: one eye shut is one eye shut, and it
    /// is the wearer's own eye, whichever way round the picture is.
    @Test func aWinkIsTheWearersOwnEye() {
        // An ordinary picture: the model's "left" is the face's own left.
        var solver = calibrated()
        let reading = settle(&solver, [.eyeBlinkLeft: 0.7])
        #expect(reading[.eyeBlinkLeft] > 0.9)
        #expect(reading[.eyeBlinkRight] < 0.05)

        // A mirror image: the model, taking it for an ordinary picture, calls
        // the wearer's left eye the right one.
        var tuning = FaceSolver.Tuning()
        tuning.mirroredImage = true
        var mirrored = calibrated(tuning: tuning, mirrored: true)
        let seen = settle(&mirrored, [.eyeBlinkRight: 0.7], mirrored: true)
        #expect(seen[.eyeBlinkLeft] > 0.9)
        #expect(seen[.eyeBlinkRight] < 0.05)
        // And a brow with it.
        let brow = settle(&mirrored, [.browDownRight: 0.8], mirrored: true)
        #expect(brow[.browDownLeft] > 0.6)
        #expect(brow[.browDownRight] < 0.05)
    }

    @Test func aBlinkShutsBothEyesAndIsNoSquint() {
        var solver = calibrated()
        let reading = settle(&solver, [.eyeBlinkLeft: 0.72, .eyeBlinkRight: 0.65, .eyeSquintLeft: 0.8, .eyeSquintRight: 0.8])
        #expect(reading[.eyeBlinkLeft] > 0.95)
        #expect(reading[.eyeBlinkRight] > 0.95)
        #expect(reading[.eyeSquintLeft] < 0.05)
        // Half way there is half shut.
        let half = settle(&solver, [.eyeBlinkLeft: 0.36, .eyeBlinkRight: 0.36])
        #expect(half[.eyeBlinkLeft] > 0.3 && half[.eyeBlinkLeft] < 0.7)
    }

    @Test func scoresNearRestStayAtRestAndTheRestScale() {
        var solver = calibrated()
        let near = settle(&solver, [.browDownLeft: 0.12, .browInnerUp: 0.07])
        #expect(near[.browDownLeft] == 0)
        #expect(near[.browInnerUp] == 0)
        let far = settle(&solver, [.browDownLeft: 0.9, .jawOpen: 0.5, .mouthSmileLeft: 0.95])
        #expect(far[.browDownLeft] > 0.7)
        #expect(far[.jawOpen] > 0.4 && far[.jawOpen] < 0.6)
        #expect(far[.mouthSmileLeft] > 0.85)
        #expect(far[.mouthSmileRight] < 0.02)
    }

    @Test func binaryEyelidsAndTheSwitchesHoldForScoresToo() {
        var tuning = FaceSolver.Tuning()
        tuning.binaryEyelids = true
        var solver = calibrated(tuning: tuning)
        let reading = settle(&solver, [.eyeBlinkLeft: 0.5, .eyeBlinkRight: 0.2, .eyeSquintRight: 0.7])
        #expect(reading[.eyeBlinkLeft] > 0.99)
        #expect(reading[.eyeBlinkRight] == 0)
        #expect(reading[.eyeSquintRight] == 0)

        var plain = FaceSolver.Tuning()
        plain.squintsEnabled = false
        var other = calibrated(tuning: plain)
        #expect(settle(&other, [.eyeSquintLeft: 0.9])[.eyeSquintLeft] == 0)
    }

    @Test func aWinkHeldForALongWhileStaysAWink() {
        // Learning the rest face as it goes, with no calibration: fifteen
        // seconds of one eye shut must not become the face at rest.
        var solver = FaceSolver()
        for _ in 0..<60 { solver.solve(landmarks([:]), deltaTime: 1 / 30) }
        var reading = FaceReading()
        for _ in 0..<450 { reading = solver.solve(landmarks([.eyeBlinkLeft: 0.7]), deltaTime: 1 / 30) }
        #expect(reading[.eyeBlinkLeft] > 0.9)
        #expect(reading[.eyeBlinkRight] < 0.05)
    }

    @Test func browsCanComeFromTheOutlinesInstead() {
        var tuning = FaceSolver.Tuning()
        tuning.modelBrows = false
        var solver = FaceSolver(tuning: tuning)
        solver.calibrate(seconds: 0.5)
        for _ in 0..<40 { solver.solve(landmarks([:]), deltaTime: 1 / 30) }
        // The model says the brows are down, the outlines that they are up.
        var raised = SyntheticFace()
        raised.browRaise = SIMD2(0.1, 0.1)
        var l = raised.landmarks()
        l.modelShapes = Self.rest.merging([.browDownLeft: 0.9, .eyeBlinkLeft: 0.7]) { $1 }
        var reading = FaceReading()
        for _ in 0..<40 { reading = solver.solve(l, deltaTime: 1 / 30) }
        #expect(reading[.browDownLeft] < 0.05)
        #expect(reading[.browOuterUpLeft] > 0.9)
        // The lids are still the model's.
        #expect(reading[.eyeBlinkLeft] > 0.9)
    }

    @Test func theRestScoresAreLearntWithoutBeingTold() {
        var solver = FaceSolver()
        // Mostly at rest, a blink now and then.
        for frame in 0..<120 {
            let blinking = frame % 30 < 3
            solver.solve(landmarks(blinking ? [.eyeBlinkLeft: 0.7, .eyeBlinkRight: 0.7] : [:]), deltaTime: 1 / 30)
        }
        #expect(abs((solver.modelNeutral[.eyeBlinkLeft] ?? 1) - 0.08) < 0.01)
        #expect(solver.calibratedModelShapes == nil)
        solver.clearCalibration()
        #expect(solver.modelNeutral.isEmpty)
    }

    @Test func landmarksWithoutScoresAreStillMeasured() {
        // Vision's landmarks carry no scores: the outlines are measured as before.
        var solver = FaceSolver()
        solver.calibrate(seconds: 0.5)
        for _ in 0..<40 { solver.solve(SyntheticFace().landmarks(), deltaTime: 1 / 30) }
        var wink = SyntheticFace()
        wink.eyeOpen = SIMD2(0.01, 0.12)
        var reading = FaceReading()
        for _ in 0..<30 { reading = solver.solve(wink.landmarks(), deltaTime: 1 / 30) }
        #expect(reading[.eyeBlinkLeft] > 0.9)
        #expect(solver.modelNeutral.isEmpty)
    }

    // MARK: - The models themselves

    /// The three models are in the package's resources, load, and run: a
    /// black picture has no face.
    @Test func theBundledModelsLoadAndFindNoFaceInABlackPicture() throws {
        let reader = try FaceMeshReader()
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let black = try #require(buffer)
        CVPixelBufferLockBaseAddress(black, [])
        memset(CVPixelBufferGetBaseAddress(black), 0, CVPixelBufferGetDataSize(black))
        CVPixelBufferUnlockBaseAddress(black, [])
        #expect(try reader.read(black, orientation: .up) == nil)
    }

    @available(macOS 15.0, *)
    @Test func theTrackersReaderIsVisionUntilAsked() {
        let tracker = RAVEPersonaFaceTracker()
        #expect(tracker.reader == .vision)
        tracker.reader = .mesh
        #expect(tracker.reader == .mesh)
        #expect(tracker.stats().reader == "mesh")
        // Nothing has been read yet.
        #expect(tracker.activeReader == .vision)
    }
}
