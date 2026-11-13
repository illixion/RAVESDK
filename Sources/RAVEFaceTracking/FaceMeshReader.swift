/*
 The face mesh reader: MediaPipe's Face Landmarker through Core ML.

 Three small models, converted from Google's `face_landmarker.task` (float16,
 Apache-2.0; see ModelSource/README.md for the source, the conversion and how
 closely it matches the original): BlazeFace finds the face, the mesh model
 reads 478 points from a square crop turned to the eye line, and the blend
 shape model scores ARKit's shapes from 146 of them, each eye on its own.

 A face that was found is followed: the next frame's crop comes from this
 frame's points, so the detector only runs to find a face again. One frame at
 a time, by the tracker's own rule; this keeps the crop between frames and is
 not to be called from two threads at once.
 */

import CoreImage
import CoreML
import CoreVideo
import DebugLog
import Foundation
import ImageIO
import simd

public final class FaceMeshReader: @unchecked Sendable {

    public struct Result: Sendable {
        /// The mesh as outlines, y up, with the model's blend shape scores.
        public var landmarks: FaceLandmarks
        /// All 478 points in the (turned) picture, pixels, y down; z in the
        /// same scale, smaller nearer.
        public var points: [SIMD3<Float>]
        /// Whether the detector had to find the face this frame.
        public var detected: Bool
    }

    public enum Failure: Error, CustomStringConvertible {
        case missing(String)
        case output(String)
        case buffer

        public var description: String {
            switch self {
            case .missing(let name): "the \(name) model is not in the package's resources"
            case .output(let name): "the \(name) model gave no \(name == "FaceMesh" ? "landmarks" : "output")"
            case .buffer: "couldn't make a pixel buffer for the crop"
            }
        }
    }

    private let detector: MLModel
    private let mesh: MLModel
    private let blend: MLModel
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var detectorBuffer: CVPixelBuffer?
    private var meshBuffer: CVPixelBuffer?
    private var region: FaceMeshRegion?

    /// A mesh this sure of a face is one (the model's own score, as
    /// MediaPipe thresholds it).
    public var minimumPresence: Float = 0.5

    /// Loads the three models from the package's resources; not on the main
    /// thread. `meshUnits` is where the mesh model runs. The CPU is the
    /// default: about 2.5 ms a frame on an M2, nothing to specialise at load,
    /// and no queueing behind an app's other models on the GPU or the Neural
    /// Engine (which runs it in about 1 ms when it is free, after a second
    /// or two of loading). The detector and the blend shape model are faster
    /// on the CPU than anywhere, and stay there.
    public init(meshUnits: MLComputeUnits = .cpuOnly) throws {
        func load(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            guard let url = Bundle.module.url(forResource: name, withExtension: "mlmodelc", subdirectory: "Models") else {
                throw Failure.missing(name)
            }
            let configuration = MLModelConfiguration()
            #if targetEnvironment(simulator)
            // The simulator can't make any other inference context.
            configuration.computeUnits = .cpuOnly
            #else
            configuration.computeUnits = units
            #endif
            return try MLModel(contentsOf: url, configuration: configuration)
        }
        detector = try load("FaceDetector", .cpuOnly)
        mesh = try load("FaceMesh", meshUnits)
        blend = try load("FaceBlendshapes", .cpuOnly)
    }

    /// Forgets the face it was following: the next frame starts with the
    /// detector.
    public func reset() { region = nil }

    /// One frame. Nil when it shows no face.
    public func read(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) throws -> Result? {
        var image = CIImage(cvPixelBuffer: buffer)
        if orientation != .up { image = image.oriented(orientation) }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let width = Float(image.extent.width), height = Float(image.extent.height)
        guard width >= 16, height >= 16 else { return nil }

        var detected = false
        if region == nil {
            guard let found = try detect(image, width: width, height: height) else { return nil }
            region = found.region
            detected = true
        }
        guard var points = try meshPoints(image, height: height) else {
            region = nil
            return nil
        }
        if detected, let closer = FaceMesh.region(following: points.points) {
            // The detector's box is rough; the mesh's own is what the
            // following frames will use, so the first reads from it too.
            region = closer
            if let again = try meshPoints(image, height: height) { points = again }
        }
        guard points.presence >= minimumPresence else {
            region = nil
            return nil
        }
        region = FaceMesh.region(following: points.points)

        let input = FaceMesh.blendShapeInput(points.points)
        let array = try MLMultiArray(shape: [1, 146, 2], dataType: .float32)
        array.withUnsafeMutableBufferPointer(ofType: Float.self) { pointer, _ in
            for (i, v) in input.enumerated() where i < pointer.count { pointer[i] = v }
        }
        let scored = try blend.prediction(from: MLDictionaryFeatureProvider(dictionary: ["points": array]))
        guard let scores = Self.floats(scored, "blendshapes") else { throw Failure.output("FaceBlendshapes") }

        guard var landmarks = FaceMesh.landmarks(points.points, height: height, confidence: points.presence) else {
            return nil
        }
        landmarks.modelShapes = FaceMesh.blendShapes(scores)
        return Result(landmarks: landmarks, points: points.points, detected: detected)
    }

    // MARK: - The models

    private func detect(_ image: CIImage, width: Float, height: Float) throws -> FaceMeshDetection? {
        let size = FaceMesh.detectorInput
        let box = FaceMesh.Letterbox(width: width, height: height)
        // CoreImage's y is up: the picture's top margin is the buffer's.
        let placed = image
            .transformed(by: CGAffineTransform(scaleX: CGFloat(box.scale), y: CGFloat(box.scale)))
            .transformed(by: CGAffineTransform(translationX: CGFloat(box.offset.x), y: CGFloat(box.offset.y)))
        let target = try Self.buffer(&detectorBuffer, Int(size))
        render(placed, to: target, size: size)
        let out = try detector.prediction(from: MLDictionaryFeatureProvider(
            dictionary: ["image": MLFeatureValue(pixelBuffer: target)]))
        guard let regressors = Self.floats(out, "regressors"), let scores = Self.floats(out, "scores") else {
            throw Failure.output("FaceDetector")
        }
        return FaceMesh.detection(regressors: regressors, scores: scores, letterbox: box)
    }

    private func meshPoints(_ image: CIImage, height: Float) throws -> (points: [SIMD3<Float>], presence: Float)? {
        guard let region else { return nil }
        let size = FaceMesh.meshInput
        // Picture (CoreImage, y up) → picture (y down) → crop (y down) → the
        // crop's buffer (CoreImage, y up).
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height))
        let k = CGFloat(size / max(region.side, 1e-3))
        let toCrop = CGAffineTransform(translationX: CGFloat(-region.centre.x), y: CGFloat(-region.centre.y))
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(-region.rotation)))
            .concatenating(CGAffineTransform(scaleX: k, y: k))
            .concatenating(CGAffineTransform(translationX: CGFloat(size / 2), y: CGFloat(size / 2)))
        let unflip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(size))
        let cropped = image.transformed(by: flip.concatenating(toCrop).concatenating(unflip))
        let target = try Self.buffer(&meshBuffer, Int(size))
        render(cropped, to: target, size: size)
        let out = try mesh.prediction(from: MLDictionaryFeatureProvider(
            dictionary: ["image": MLFeatureValue(pixelBuffer: target)]))
        guard let raw = Self.floats(out, "landmarks"), raw.count >= FaceMesh.pointCount * 3,
              let presence = Self.floats(out, "presence")?.first else { throw Failure.output("FaceMesh") }
        guard raw.allSatisfy(\.isFinite) else { return nil }
        return (FaceMesh.imagePoints(raw, region: region), 1 / (1 + exp(-presence)))
    }

    private func render(_ image: CIImage, to buffer: CVPixelBuffer, size: Float) {
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
        // Over black: what the picture doesn't cover is the models' padding.
        let framed = image.composited(over: CIImage(color: .black).cropped(to: bounds))
        context.render(framed, to: buffer, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    private static func buffer(_ kept: inout CVPixelBuffer?, _ size: Int) throws -> CVPixelBuffer {
        if let kept { return kept }
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
        guard let made else { throw Failure.buffer }
        kept = made
        return made
    }

    private static func floats(_ features: MLFeatureProvider, _ name: String) -> [Float]? {
        guard let array = features.featureValue(for: name)?.multiArrayValue else { return nil }
        return MLShapedArray<Float>(converting: array).scalars
    }
}
