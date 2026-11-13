import CoreImage
import CoreVideo
import Foundation
import RAVEFaceTracking
import Testing
import Vision
import simd

/// The two readers side by side on pictures of your own (none are kept in the
/// repository): each eye's lid and the brows from Vision's outlines, from the
/// mesh's outlines and from the mesh's blend shape model.
///
///     FACE_DIR=/path/to/pictures swift test --filter FaceReaderComparisonTests
///
/// Each picture in the directory is read on its own. Each subdirectory is
/// read as a film of one still face (the same picture shifted a pixel or two,
/// re-compressed, with a little noise), and what it prints is how far each
/// measure wandered: its standard deviation and range over the frames.
@Suite struct FaceReaderComparisonTests {

    static let directory = ProcessInfo.processInfo.environment["FACE_DIR"]

    struct Row {
        var visionOpen: SIMD2<Float>?
        var visionBrow: SIMD4<Float>?
        var visionAngles: SIMD3<Float>?
        var meshOpen: SIMD2<Float>?
        var meshBrow: SIMD4<Float>?
        var meshAngles: SIMD3<Float>?
        var scores: [FaceBlendShape: Float]?
        var visionMs = 0.0, meshMs = 0.0
        var visionLandmarks: FaceLandmarks?
        var meshLandmarks: FaceLandmarks?
    }

    static func buffer(_ url: URL) -> CVPixelBuffer? {
        guard let image = CIImage(contentsOf: url) else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(image.extent.width), Int(image.extent.height), kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CIContext().render(image, to: buffer)
        return buffer
    }

    @available(macOS 15.0, *)
    static func read(_ url: URL, mesh: FaceMeshReader) async throws -> Row {
        let buffer = try #require(buffer(url))
        var row = Row()
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        var start = Date()
        let faces = try await DetectFaceLandmarksRequest().perform(on: buffer)
        row.visionMs = Date().timeIntervalSince(start) * 1000
        if let face = faces.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
           let landmarks = RAVEPersonaFaceTracker.landmarks(of: face, size: size),
           let f = FaceFeatures.measure(landmarks, mirroredImage: false) {
            row.visionLandmarks = landmarks
            row.visionOpen = f.eyeOpen
            row.visionBrow = SIMD4(f.browInner.x, f.browInner.y, f.browOuter.x, f.browOuter.y)
            row.visionAngles = SIMD3(landmarks.yaw, landmarks.pitch, landmarks.roll)
        }
        start = Date()
        let result = try mesh.read(buffer, orientation: .up)
        row.meshMs = Date().timeIntervalSince(start) * 1000
        if let landmarks = result?.landmarks, let f = FaceFeatures.measure(landmarks, mirroredImage: false) {
            row.meshLandmarks = landmarks
            row.meshOpen = f.eyeOpen
            row.meshBrow = SIMD4(f.browInner.x, f.browInner.y, f.browOuter.x, f.browOuter.y)
            row.meshAngles = SIMD3(landmarks.yaw, landmarks.pitch, landmarks.roll)
            row.scores = landmarks.modelShapes
        }
        return row
    }

    static func pictures(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func f(_ v: Float?) -> String { v.map { String(format: "%.3f", $0) } ?? "  -  " }

    @available(macOS 15.0, *)
    @Test(.enabled(if: directory != nil))
    func bothReadersOnTheSamePictures() async throws {
        let root = URL(fileURLWithPath: try #require(Self.directory))
        let load = Date()
        let mesh = try FaceMeshReader()
        print("face mesh models loaded in \(Int(Date().timeIntervalSince(load) * 1000)) ms")

        print("\npicture | vision open L R | mesh outline open L R | model blink L R | model browDown L R, innerUp, outerUp L R | vision yaw pitch roll | mesh yaw pitch roll")
        for url in Self.pictures(in: root) {
            mesh.reset()
            let r = try await Self.read(url, mesh: mesh)
            let s = r.scores ?? [:]
            func a(_ v: SIMD3<Float>?) -> String { v.map { String(format: "%.2f %.2f %.2f", $0.x, $0.y, $0.z) } ?? "-" }
            print("""
            \(url.lastPathComponent) | \(Self.f(r.visionOpen?.x)) \(Self.f(r.visionOpen?.y)) | \
            \(Self.f(r.meshOpen?.x)) \(Self.f(r.meshOpen?.y)) | \(Self.f(s[.eyeBlinkLeft])) \(Self.f(s[.eyeBlinkRight])) | \
            \(Self.f(s[.browDownLeft])) \(Self.f(s[.browDownRight])) \(Self.f(s[.browInnerUp])) \
            \(Self.f(s[.browOuterUpLeft])) \(Self.f(s[.browOuterUpRight])) | \(a(r.visionAngles)) | \(a(r.meshAngles))
            """)
        }

        let films = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for film in films {
            mesh.reset()
            var rows: [Row] = []
            for url in Self.pictures(in: film) { rows.append(try await Self.read(url, mesh: mesh)) }
            guard rows.count > 2 else { continue }
            func spread(_ name: String, _ values: [Float]) {
                guard values.count > 2 else { return print("  \(name): no face") }
                let mean = values.reduce(0, +) / Float(values.count)
                let sd = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)).squareRoot()
                print(String(format: "  %@: mean %.4f  sd %.4f  range %.4f", name.padding(toLength: 34, withPad: " ", startingAt: 0),
                             mean, sd, (values.max() ?? 0) - (values.min() ?? 0)))
            }
            print("\n\(film.lastPathComponent): \(rows.count) frames of one still face")
            spread("vision brow inner L (face units)", rows.compactMap { $0.visionBrow?.x })
            spread("vision brow inner R", rows.compactMap { $0.visionBrow?.y })
            spread("vision brow outer L", rows.compactMap { $0.visionBrow?.z })
            spread("vision brow outer R", rows.compactMap { $0.visionBrow?.w })
            spread("vision eye open L", rows.compactMap { $0.visionOpen?.x })
            spread("vision eye open R", rows.compactMap { $0.visionOpen?.y })
            spread("mesh brow inner L (face units)", rows.compactMap { $0.meshBrow?.x })
            spread("mesh brow inner R", rows.compactMap { $0.meshBrow?.y })
            spread("mesh brow outer L", rows.compactMap { $0.meshBrow?.z })
            spread("mesh brow outer R", rows.compactMap { $0.meshBrow?.w })
            spread("mesh eye open L", rows.compactMap { $0.meshOpen?.x })
            spread("mesh eye open R", rows.compactMap { $0.meshOpen?.y })
            for shape in [FaceBlendShape.browDownLeft, .browDownRight, .browInnerUp, .browOuterUpLeft, .browOuterUpRight,
                          .eyeBlinkLeft, .eyeBlinkRight, .jawOpen, .mouthSmileLeft] {
                spread("model \(shape.rawValue)", rows.compactMap { $0.scores?[shape] })
            }
            // What an avatar would show: each reader's frames through a solver
            // of its own at 30 a second, three times round so the rest face is
            // learnt, the last round measured.
            var outline = FaceSolver.Tuning()
            outline.modelBrows = false
            for (name, frames, tuning) in [("vision", rows.map(\.visionLandmarks), FaceSolver.Tuning()),
                                           ("face mesh", rows.map(\.meshLandmarks), FaceSolver.Tuning()),
                                           ("face mesh, brows from its outlines", rows.map(\.meshLandmarks), outline)] {
                var solver = FaceSolver(tuning: tuning)
                var solved: [FaceReading] = []
                for round in 0..<3 {
                    for landmarks in frames {
                        let reading = solver.solve(landmarks, deltaTime: 1 / 30)
                        if round == 2 { solved.append(reading) }
                    }
                }
                print("  solved from \(name):")
                for shape in [FaceBlendShape.browDownLeft, .browDownRight, .browInnerUp, .browOuterUpLeft, .browOuterUpRight,
                              .eyeBlinkLeft, .eyeBlinkRight] {
                    spread("  \(shape.rawValue)", solved.map { $0[shape] })
                }
            }
            // The first frames carry each model's first-use cost.
            let later = rows.dropFirst(5)
            let vision = later.map(\.visionMs).reduce(0, +) / Double(later.count)
            let meshMs = later.map(\.meshMs).reduce(0, +) / Double(later.count)
            print(String(format: "  time a frame: vision %.1f ms, face mesh %.1f ms", vision, meshMs))
        }
    }
}
