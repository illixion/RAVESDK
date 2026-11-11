import Foundation
import RAVEFaceTracking
import Testing

/// Real Vision on the Mac, through the tracker's file path and the solver:
/// the check that Vision's landmarks measure as the made-up faces do. Opt in
/// with a portrait of your own (none is kept in the repository):
///
///     FACE_IMAGE=/path/to/portrait.jpg swift test --filter PersonaFaceTrackerTests
@Suite struct PersonaFaceTrackerTests {

    @available(macOS 15.0, *)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FACE_IMAGE"] != nil))
    func readsARealFace() async throws {
        let url = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["FACE_IMAGE"]))
        let tracker = RAVEPersonaFaceTracker()
        let changes = Changes()
        tracker.onState = { change in changes.add("\(change)") }
        await tracker.startFile(url)
        defer { tracker.stop() }
        var solver = FaceSolver()
        var reading = FaceReading()
        var sequence = 0
        for _ in 0..<300 {
            try await Task.sleep(for: .milliseconds(33))
            guard let latest = tracker.latest, latest.sequence != sequence else { continue }
            sequence = latest.sequence
            reading = solver.solve(latest.landmarks, deltaTime: 1 / 30)
        }
        let stats = tracker.stats()
        print("vision \(stats.averageMilliseconds) ms, faces \(stats.faces)/\(stats.processed) of \(stats.captured), \(stats.device) \(stats.activeFormat), error \(stats.lastError ?? "none")")
        print("changes", changes.all)
        let features = try #require(reading.features, "no face found")
        print("features", features)
        print("changes", changes.all)
        print("shapes", reading.shapes.filter { $0.value > 0.05 })
        #expect(reading.presence == 1)
        // A relaxed portrait measures near the typical face.
        #expect(abs(features.eyeOpen.x - FaceFeatures.typical.eyeOpen.x) < 0.08)
        #expect(abs(features.mouthWidth - FaceFeatures.typical.mouthWidth) < 0.25)
        #expect(features.cornerHeight.x < -0.8 && features.cornerHeight.x > -2)
        #expect(features.browOuter.x > 0.05 && features.browOuter.x < 0.7)
    }
}

final class Changes: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ s: String) { lock.withLock { list.append(s) } }
    var all: [String] { lock.withLock { list } }
}
