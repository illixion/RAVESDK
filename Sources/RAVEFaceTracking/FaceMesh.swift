import Foundation
import simd

// The second face reader's framework-free half: Google's MediaPipe Face
// Landmarker (BlazeFace detector, 478-point mesh with irises, and a model that
// scores ARKit's blend shapes from 146 of the mesh's points), run through Core
// ML by `FaceMeshReader`. What is here is the arithmetic round the three
// models, so it can be tested on the Mac with made-up numbers: the detector's
// anchors and how its output decodes, the turned square a face is cropped to,
// the mesh's points back in the picture, and the mesh as `FaceLandmarks`.
//
// Everything here is in the picture's pixels with y DOWN, as the models and
// MediaPipe work; `FaceLandmarks` is y up, and `FaceMesh.landmarks` turns it
// over.

/// Which model reads the face in a frame.
public enum FaceReader: String, CaseIterable, Sendable, Codable {
    /// Vision's `DetectFaceLandmarksRequest`: 2D outlines, measured by
    /// `FaceSolver`. It fits both eyes as one shape, so it cannot show a wink.
    case vision
    /// MediaPipe's face mesh and blend shape model through Core ML: each
    /// eye's lid on its own, and the brows from a model rather than a
    /// difference of two noisy points.
    case mesh
}

/// The square a face is cropped to for the mesh: centred on the face, turned
/// so the eye line is level, half as big again as the face.
public struct FaceMeshRegion: Sendable, Equatable {
    public var centre: SIMD2<Float>
    public var side: Float
    /// Radians, the eye line's angle in the picture (y down): the crop's x
    /// axis points this way.
    public var rotation: Float

    public init(centre: SIMD2<Float>, side: Float, rotation: Float) {
        self.centre = centre
        self.side = side
        self.rotation = rotation
    }

    /// A point of the crop (0…`size` each way) in the picture.
    public func toImage(_ p: SIMD2<Float>, size: Float = FaceMesh.meshInput) -> SIMD2<Float> {
        let c = cos(rotation), s = sin(rotation), k = side / size
        let d = (p - SIMD2(repeating: size / 2)) * k
        return centre + SIMD2(d.x * c - d.y * s, d.x * s + d.y * c)
    }

    /// A point of the picture in the crop.
    public func toCrop(_ p: SIMD2<Float>, size: Float = FaceMesh.meshInput) -> SIMD2<Float> {
        let c = cos(rotation), s = sin(rotation), k = size / max(side, 1e-4)
        let d = p - centre
        return SIMD2(d.x * c + d.y * s, -d.x * s + d.y * c) * k + SIMD2(repeating: size / 2)
    }
}

/// A face the detector found: its box and six points (the eyes, image-left
/// first, then nose, mouth and ears), in the picture's pixels.
public struct FaceMeshDetection: Sendable, Equatable {
    public var centre: SIMD2<Float>
    public var size: SIMD2<Float>
    public var keypoints: [SIMD2<Float>]
    public var score: Float

    /// The square to read the mesh from.
    public var region: FaceMeshRegion {
        FaceMesh.region(centre: centre, size: size, eyeA: keypoints[0], eyeB: keypoints[1])
    }
}

public enum FaceMesh {
    /// The detector's and the mesh model's input sizes, pixels square.
    public static let detectorInput: Float = 128
    public static let meshInput: Float = 256
    public static let pointCount = 478
    /// How much bigger than the face the crop is, as MediaPipe sets it.
    public static let regionScale: Float = 1.5

    // MARK: - The detector

    /// The centre of each of the detector's 896 anchors, in shares of its
    /// input: a 16×16 grid with two anchors a cell, then 8×8 with six
    /// (MediaPipe's SSD anchors for the short-range model: strides 8, 16, 16,
    /// 16, offset 0.5, fixed size).
    public static let anchors: [SIMD2<Float>] = {
        var out: [SIMD2<Float>] = []
        out.reserveCapacity(896)
        for (grid, count) in [(16, 2), (8, 6)] {
            for y in 0..<grid {
                for x in 0..<grid {
                    let centre = SIMD2((Float(x) + 0.5) / Float(grid), (Float(y) + 0.5) / Float(grid))
                    out.append(contentsOf: Array(repeating: centre, count: count))
                }
            }
        }
        return out
    }()

    /// How a picture sits in the detector's square input: scaled to fit,
    /// centred, the rest black.
    public struct Letterbox: Sendable, Equatable {
        public var scale: Float
        public var offset: SIMD2<Float>

        public init(width: Float, height: Float, size: Float = FaceMesh.detectorInput) {
            scale = size / max(width, height, 1)
            offset = SIMD2((size - width * scale) / 2, (size - height * scale) / 2)
        }

        public func toImage(_ p: SIMD2<Float>) -> SIMD2<Float> { (p - offset) / scale }
    }

    /// The best face in the detector's output, or nil when none scores
    /// `minimumScore`. `regressors` is 896 rows of 16 (box centre and size,
    /// then six points, in input pixels off the anchor) and `scores` 896
    /// logits.
    public static func detection(regressors: [Float], scores: [Float], letterbox: Letterbox,
                                 minimumScore: Float = 0.5) -> FaceMeshDetection? {
        guard scores.count == anchors.count, regressors.count == anchors.count * 16 else { return nil }
        var best = 0
        for i in 1..<scores.count where scores[i] > scores[best] { best = i }
        let score = 1 / (1 + exp(-max(-100, min(100, scores[best]))))
        guard score >= minimumScore else { return nil }
        let anchor = anchors[best] * detectorInput
        let r = regressors[(best * 16)..<(best * 16 + 16)]
        let base = r.startIndex
        let centre = letterbox.toImage(SIMD2(r[base], r[base + 1]) + anchor)
        let size = SIMD2(r[base + 2], r[base + 3]) / letterbox.scale
        let points = (0..<6).map { k in
            letterbox.toImage(SIMD2(r[base + 4 + 2 * k], r[base + 5 + 2 * k]) + anchor)
        }
        return FaceMeshDetection(centre: centre, size: size, keypoints: points, score: score)
    }

    // MARK: - The crop

    /// The square round a box, turned to the line from `eyeA` to `eyeB`
    /// (image-left eye first).
    public static func region(centre: SIMD2<Float>, size: SIMD2<Float>, eyeA: SIMD2<Float>,
                              eyeB: SIMD2<Float>) -> FaceMeshRegion {
        FaceMeshRegion(centre: centre, side: max(size.x, size.y) * regionScale,
                       rotation: atan2(eyeB.y - eyeA.y, eyeB.x - eyeA.x))
    }

    /// The square for the next frame, from this frame's mesh: the points'
    /// box in the face's own turn (the line between the eyes' outer corners),
    /// so a face that is followed needs no detector.
    public static func region(following points: [SIMD3<Float>]) -> FaceMeshRegion? {
        guard points.count >= pointCount else { return nil }
        let a = points[33], b = points[263]
        let rotation = atan2(b.y - a.y, b.x - a.x)
        let c = cos(rotation), s = sin(rotation)
        var low = SIMD2<Float>(repeating: .greatestFiniteMagnitude), high = -low
        for p in points {
            // Into the face's frame: turned back by `rotation`.
            let q = SIMD2(p.x * c + p.y * s, -p.x * s + p.y * c)
            low = simd_min(low, q)
            high = simd_max(high, q)
        }
        let mid = (low + high) / 2, extent = high - low
        guard extent.x > 2, extent.y > 2 else { return nil }
        return FaceMeshRegion(centre: SIMD2(mid.x * c - mid.y * s, mid.x * s + mid.y * c),
                              side: max(extent.x, extent.y) * regionScale, rotation: rotation)
    }

    /// The mesh model's points (478 × x, y, z in crop pixels) in the picture.
    /// z keeps the crop's scale: smaller is nearer the camera.
    public static func imagePoints(_ raw: [Float], region: FaceMeshRegion) -> [SIMD3<Float>] {
        let count = raw.count / 3
        let k = region.side / meshInput
        return (0..<count).map { i in
            let p = region.toImage(SIMD2(raw[i * 3], raw[i * 3 + 1]))
            return SIMD3(p.x, p.y, raw[i * 3 + 2] * k)
        }
    }

    // MARK: - The blend shape model

    /// The 146 mesh points the blend shape model reads, in its order
    /// (MediaPipe's `kLandmarksSubsetIdxs`).
    public static let blendShapeInputs: [Int] = [
        0, 1, 4, 5, 6, 7, 8, 10, 13, 14, 17, 21, 33, 37, 39,
        40, 46, 52, 53, 54, 55, 58, 61, 63, 65, 66, 67, 70, 78, 80,
        81, 82, 84, 87, 88, 91, 93, 95, 103, 105, 107, 109, 127, 132, 133,
        136, 144, 145, 146, 148, 149, 150, 152, 153, 154, 155, 157, 158, 159, 160,
        161, 162, 163, 168, 172, 173, 176, 178, 181, 185, 191, 195, 197, 234, 246,
        249, 251, 263, 267, 269, 270, 276, 282, 283, 284, 285, 288, 291, 293, 295,
        296, 297, 300, 308, 310, 311, 312, 314, 317, 318, 321, 323, 324, 332, 334,
        336, 338, 356, 361, 362, 365, 373, 374, 375, 377, 378, 379, 380, 381, 382,
        384, 385, 386, 387, 388, 389, 390, 397, 398, 400, 402, 405, 409, 415, 454,
        466, 468, 469, 470, 471, 472, 473, 474, 475, 476, 477,
    ]

    /// The blend shape model's 52 outputs in its order. The first is its
    /// "neutral" score, which is no shape; it has no `tongueOut`.
    public static let blendShapeOutputs: [FaceBlendShape?] = [
        nil, .browDownLeft, .browDownRight, .browInnerUp, .browOuterUpLeft, .browOuterUpRight,
        .cheekPuff, .cheekSquintLeft, .cheekSquintRight, .eyeBlinkLeft, .eyeBlinkRight,
        .eyeLookDownLeft, .eyeLookDownRight, .eyeLookInLeft, .eyeLookInRight, .eyeLookOutLeft, .eyeLookOutRight,
        .eyeLookUpLeft, .eyeLookUpRight, .eyeSquintLeft, .eyeSquintRight, .eyeWideLeft, .eyeWideRight,
        .jawForward, .jawLeft, .jawOpen, .jawRight, .mouthClose, .mouthDimpleLeft, .mouthDimpleRight,
        .mouthFrownLeft, .mouthFrownRight, .mouthFunnel, .mouthLeft, .mouthLowerDownLeft, .mouthLowerDownRight,
        .mouthPressLeft, .mouthPressRight, .mouthPucker, .mouthRight, .mouthRollLower, .mouthRollUpper,
        .mouthShrugLower, .mouthShrugUpper, .mouthSmileLeft, .mouthSmileRight, .mouthStretchLeft, .mouthStretchRight,
        .mouthUpperUpLeft, .mouthUpperUpRight, .noseSneerLeft, .noseSneerRight,
    ]

    /// The points the blend shape model takes, as it takes them: x and y of
    /// each, 146 pairs. The model centres and scales them itself, but in
    /// half precision a coordinate of a thousand pixels has lost its
    /// fractions before it gets there, so they go in about their own middle.
    public static func blendShapeInput(_ points: [SIMD3<Float>]) -> [Float] {
        guard points.count >= pointCount else { return [] }
        // Off the first point before summing, so the sum keeps its fractions too.
        let first = SIMD2(points[blendShapeInputs[0]].x, points[blendShapeInputs[0]].y)
        var mean = SIMD2<Float>.zero
        for i in blendShapeInputs { mean += SIMD2(points[i].x, points[i].y) - first }
        mean /= Float(blendShapeInputs.count)
        var out: [Float] = []
        out.reserveCapacity(blendShapeInputs.count * 2)
        for i in blendShapeInputs {
            out.append(points[i].x - first.x - mean.x)
            out.append(points[i].y - first.y - mean.y)
        }
        return out
    }

    /// The model's 52 scores by shape, for an ordinary picture: the model
    /// names sides as ARKit does for a face seen by a camera, so its "left"
    /// is the face's own left, on the image's right. `FaceSolver` swaps them
    /// for a mirror image.
    public static func blendShapes(_ scores: [Float]) -> [FaceBlendShape: Float] {
        var out: [FaceBlendShape: Float] = [:]
        for (i, shape) in blendShapeOutputs.enumerated() where i < scores.count {
            if let shape { out[shape] = scores[i] }
        }
        return out
    }

    // MARK: - The mesh as landmarks

    // The mesh's points by part. "A" is the side on the image's left in an
    // ordinary picture (the face's own right), "B" the image's right.
    static let eyeA = [33, 246, 161, 160, 159, 158, 157, 173, 133, 155, 154, 153, 145, 144, 163, 7]
    static let eyeB = [263, 466, 388, 387, 386, 385, 384, 398, 362, 382, 381, 380, 374, 373, 390, 249]
    static let browA = [70, 63, 105, 66, 107, 55, 65, 52, 53, 46]
    static let browB = [300, 293, 334, 296, 336, 285, 295, 282, 283, 276]
    static let irisA = 468, irisB = 473
    static let outerLips = [61, 146, 91, 181, 84, 17, 314, 405, 321, 375, 291, 409, 270, 269, 267, 0, 37, 39, 40, 185]
    static let innerLips = [78, 95, 88, 178, 87, 14, 317, 402, 318, 324, 308, 415, 310, 311, 312, 13, 82, 81, 80, 191]
    static let nose = [168, 6, 197, 195, 5, 4, 1, 2, 98, 327]

    /// The mesh as the outlines `FaceSolver` measures, in a picture `height`
    /// pixels tall, y up. Sides go by where a part is in the picture, as
    /// Vision's do; a mesh read from a mirror image has its "A" side on the
    /// image's right, so each part is placed by its position, not its index.
    public static func landmarks(_ points: [SIMD3<Float>], height: Float, confidence: Float) -> FaceLandmarks? {
        guard points.count >= pointCount else { return nil }
        func at(_ i: Int) -> SIMD2<Float> { SIMD2(points[i].x, height - points[i].y) }
        func part(_ indices: [Int]) -> [SIMD2<Float>] { indices.map(at) }
        let aIsLeft = points[33].x <= points[263].x
        let angles = headAngles(points)
        return FaceLandmarks(
            imageLeftEye: part(aIsLeft ? eyeA : eyeB), imageRightEye: part(aIsLeft ? eyeB : eyeA),
            imageLeftBrow: part(aIsLeft ? browA : browB), imageRightBrow: part(aIsLeft ? browB : browA),
            imageLeftPupil: at(aIsLeft ? irisA : irisB), imageRightPupil: at(aIsLeft ? irisB : irisA),
            outerLips: part(outerLips), innerLips: part(innerLips), nose: part(nose),
            yaw: angles.x, pitch: angles.y, roll: angles.z, confidence: confidence)
    }

    /// The face's turn from the mesh's depth, in Vision's senses (checked
    /// against Vision on turned and tilted portraits, macOS 27): yaw positive
    /// toward the image's right, roll positive clockwise as seen, pitch
    /// negative with the head tipped back.
    public static func headAngles(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
        guard points.count >= pointCount else { return .zero }
        // Across the face, image-left to image-right, whichever side that is.
        var a = points[33], b = points[263]
        if a.x > b.x { swap(&a, &b) }
        let across = b - a
        let top = points[10], chin = points[152]
        let down = chin - top
        let yaw = atan2(across.z, max(abs(across.x), 1e-4))
        let roll = atan2(across.y, max(abs(across.x), 1e-4))
        let pitch = atan2(down.z, max(simd_length(SIMD2(down.x, down.y)), 1e-4))
        return SIMD3(yaw, pitch, roll)
    }
}
