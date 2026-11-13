/*
 RAVEFaceTracking - the Persona's face, read by Vision or by a face mesh.

 visionOS gives an app no face tracking, but the one camera it offers is the
 wearer's Persona, whose face is the system's own live reading of theirs from
 the cameras inside the headset. This captures it (`RAVEPersonaCamera`, the
 native frame), finds the face's landmarks on the device with Vision's
 `DetectFaceLandmarksRequest`, and keeps the newest for a caller to solve
 (`FaceSolver`) once per frame of its own. `reader` picks the model: Vision,
 or MediaPipe's face mesh and blend shapes through Core ML (`FaceMeshReader`),
 which tells a wink from a blink where Vision cannot.

 One frame at a time: a frame that arrives while the last is still being read
 is dropped, never queued, so the reading is never behind. A file (a picture
 or a movie) can stand in for the camera, for the simulator, which has no
 Persona.

 **The Persona is drawn as seen from one of the app's windows.** Which one,
 and how a caller keeps it in front of the face, is the app's business
 (spatial-ai-character opens a transparent window of its own in front of the
 wearer first; see its docs/face-tracking.md).

 The camera is device-exclusive across processes: a WebKit page or another
 capture session holding it interrupts this one.
 */

import AVFoundation
import CoreImage
import CoreML
import DebugLog
import Foundation
import ImageIO
import RAVECamera
import Vision
import simd

public enum RAVEFaceTrackingLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.illixion.ravefacetracking"
    public static let tracker = DebugLogger(subsystem: subsystem, category: "FaceTracking")
}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, visionOS 2.0, *)
public final class RAVEPersonaFaceTracker: @unchecked Sendable {

    public struct Latest: Sendable {
        /// Counts results; a repeat means nothing new.
        public var sequence: Int
        /// Nil when the frame had no face.
        public var landmarks: FaceLandmarks?
        /// The model that read this frame.
        public var reader: FaceReader = .vision
        /// The frame's capture time, host clock seconds.
        public var capturedAt: Double
    }

    public enum Change: Equatable, Sendable {
        case running
        case interrupted(String)
        case resumed
        case failed(String)
        case stopped
    }

    public struct FormatSize: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public struct Stats: Sendable {
        public var captured = 0
        public var processed = 0
        public var dropped = 0
        public var faces = 0
        public var lastMilliseconds: Double = 0
        public var averageMilliseconds: Double = 0
        public var capturedRate: Double = 0
        public var processedRate: Double = 0
        public var size = ""
        public var device = ""
        public var formats: [String] = []
        public var activeFormat = ""
        public var orientation = "up"
        /// The reader asked for, and the one that read the last frame (they
        /// differ when the face mesh's models couldn't be loaded).
        public var reader = FaceReader.vision.rawValue
        public var activeReader = FaceReader.vision.rawValue
        public var lastError: String?

        public var dictionary: [String: Any] {
            func r(_ v: Double) -> Double { (v * 10).rounded() / 10 }
            return [
                "captured": captured, "processed": processed, "dropped": dropped, "facesFound": faces,
                "visionMs": r(lastMilliseconds), "visionMsAverage": r(averageMilliseconds),
                "capturedFps": r(capturedRate), "processedFps": r(processedRate),
                "size": size, "device": device, "formats": formats, "activeFormat": activeFormat,
                "orientation": orientation, "reader": reader, "activeReader": activeReader,
                "lastError": lastError as Any,
            ]
        }
    }

    /// Capture started, paused, resumed, failed or stopped. Any queue.
    public var onState: (@Sendable (Change) -> Void)? {
        get { lock.withLock { _onState } }
        set { lock.withLock { _onState = newValue } }
    }
    /// The capture size to ask the camera for, nil for its own. Read when
    /// capture starts.
    public var preferredFormat: FormatSize? {
        get { lock.withLock { _preferredFormat } }
        set { lock.withLock { _preferredFormat = newValue } }
    }
    /// How the picture is turned, for Vision.
    public var orientation: CGImagePropertyOrientation {
        get { lock.withLock { _orientation } }
        set { lock.withLock { _orientation = newValue; stats_.orientation = Self.name(newValue) } }
    }

    /// Which model reads the face. Switch it any time: the next frame uses
    /// it. The face mesh's models load on its first frame (a moment, off the
    /// main thread); if they can't be loaded the tracker says so in
    /// `stats().lastError`, keeps reading with Vision, and `activeReader`
    /// stays `.vision`. Setting `.mesh` again tries once more.
    ///
    /// The two readers measure a face a little differently, so a solver's
    /// learnt or calibrated rest face from one does not fit the other:
    /// `FaceSolver.clearCalibration()` after switching.
    public var reader: FaceReader {
        get { lock.withLock { _reader } }
        set {
            lock.withLock {
                _reader = newValue
                meshFailed = false
                meshNeedsReset = true
                stats_.reader = newValue.rawValue
            }
        }
    }
    /// The model that read the last frame.
    public var activeReader: FaceReader { lock.withLock { _activeReader } }

    private let lock = NSLock()
    private var _reader = FaceReader.vision
    private var _activeReader = FaceReader.vision
    private var meshReader: FaceMeshReader?
    private var meshFailed = false
    private var meshNeedsReset = false
    private var _onState: (@Sendable (Change) -> Void)?
    private var _preferredFormat: FormatSize?
    private var _orientation: CGImagePropertyOrientation = .up
    private var camera: RAVEPersonaCamera?
    private var fileTimer: DispatchSourceTimer?
    private let fileQueue = DispatchQueue(label: "com.illixion.ravefacetracking.file")
    private var busy = false
    private var sequence = 0
    private var _latest: Latest?
    private var lastBuffer: CVPixelBuffer?
    private var lastLandmarks: FaceLandmarks?
    private var stats_ = Stats()
    private var capturedTimes: [Double] = []
    private var processedTimes: [Double] = []
    private var generation = 0

    public init() {}

    #if targetEnvironment(simulator)
    /// Which landmark model the simulator runs; settable to find one it can.
    public var simulatorRevision: DetectFaceLandmarksRequest.Revision? = nil
    #endif

    public var latest: Latest? { lock.withLock { _latest } }
    /// The last frame's landmarks, for a readout.
    public var lastFaceLandmarks: FaceLandmarks? { lock.withLock { lastLandmarks } }
    public var isCapturing: Bool { lock.withLock { camera != nil || fileTimer != nil } }

    public func stats() -> Stats {
        lock.withLock {
            let now = CACurrentMediaTime()
            var s = stats_
            func rate(_ times: [Double]) -> Double { Double(times.filter { now - $0 < 2 }.count) / 2 }
            s.capturedRate = rate(capturedTimes)
            s.processedRate = rate(processedTimes)
            return s
        }
    }

    private func say(_ change: Change) {
        let handler = lock.withLock { _onState }
        handler?(change)
    }

    // MARK: - The Persona camera

    /// Asks for camera access if never asked, then starts capturing.
    public func startCamera() {
        stop()
        let generation = lock.withLock { self.generation += 1; return self.generation }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            runCamera(generation)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted { self.runCamera(generation) } else { self.say(.failed("Camera access was denied")) }
            }
        default:
            say(.failed("Camera access is off for this app: allow it in Settings › Privacy › Camera"))
        }
    }

    private func runCamera(_ generation: Int) {
        guard lock.withLock({ self.generation == generation }) else { return }
        guard let device = RAVEPersonaCamera.availableCameras().first else {
            say(.failed("No camera (the simulator has no Persona: use a file)"))
            return
        }
        let camera = RAVEPersonaCamera()
        do {
            try camera.configure(camera: device)
        } catch {
            say(.failed(error.localizedDescription))
            return
        }
        let formats = device.formats.map(Self.describe)
        var active = Self.describe(device.activeFormat)
        if let wanted = preferredFormat {
            let match = device.formats.min { Self.distance($0, wanted) < Self.distance($1, wanted) }
            if let match, Self.distance(match, wanted) == 0 {
                do {
                    try device.lockForConfiguration()
                    device.activeFormat = match
                    device.unlockForConfiguration()
                    active = Self.describe(match)
                } catch {
                    lock.withLock { stats_.lastError = "format: \(error.localizedDescription)" }
                }
            } else {
                lock.withLock { stats_.lastError = "no \(wanted.width)x\(wanted.height) format; using the camera's own" }
            }
        }
        RAVEFaceTrackingLog.tracker.info("""
        Face tracking from \(device.localizedName, privacy: .public), \(active, privacy: .public) \
        (offers \(formats.joined(separator: ", "), privacy: .public))
        """)
        lock.withLock {
            stats_.device = device.localizedName
            stats_.formats = formats
            stats_.activeFormat = active
        }
        camera.onVideoSample = { [weak self] sample in
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
            self?.take(buffer, at: CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
        camera.onInterruptionBegan = { [weak self] why in self?.say(.interrupted(why)) }
        camera.onInterruptionEnded = { [weak self] in self?.say(.resumed) }
        camera.onRuntimeError = { [weak self] why in self?.say(.failed("The camera failed: \(why)")) }
        let keep = lock.withLock { () -> Bool in
            guard self.generation == generation else { return false }
            self.camera = camera
            return true
        }
        guard keep else { return }
        camera.start()
        say(.running)
    }

    private static func describe(_ format: AVCaptureDevice.Format) -> String {
        let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        return "\(d.width)x\(d.height)@\(Int(fps))"
    }

    private static func distance(_ format: AVCaptureDevice.Format, _ wanted: FormatSize) -> Int {
        let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return abs(Int(d.width) - wanted.width) + abs(Int(d.height) - wanted.height)
    }

    // MARK: - A file instead

    /// Loops a picture, or up to 20 s of a movie, at 30 frames a second, as
    /// if it were the camera.
    public func startFile(_ url: URL) async {
        stop()
        let generation = lock.withLock { self.generation += 1; return self.generation }
        let frames = await Self.frames(of: url)
        guard lock.withLock({ self.generation == generation }) else { return }
        guard !frames.isEmpty else {
            say(.failed("Couldn't read \(url.lastPathComponent) as a picture or a movie"))
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: fileQueue)
        nonisolated(unsafe) let looped = frames
        nonisolated(unsafe) var index = 0
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            self?.take(looped[index % looped.count], at: CACurrentMediaTime())
            index += 1
        }
        lock.withLock {
            stats_.device = "file \(url.lastPathComponent)"
            stats_.formats = []
            stats_.activeFormat = "\(frames.count) frame(s)"
            fileTimer = timer
        }
        timer.resume()
        say(.running)
    }

    private static func frames(of url: URL) async -> [CVPixelBuffer] {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           CGImageSourceGetCount(source) > 0, CGImageSourceGetType(source) != nil,
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
           let buffer = pixelBuffer(from: CIImage(cgImage: image)) {
            return [buffer]
        }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        guard reader.startReading() else { return [] }
        var buffers: [CVPixelBuffer] = []
        while buffers.count < 600, let sample = output.copyNextSampleBuffer() {
            if let buffer = CMSampleBufferGetImageBuffer(sample) { buffers.append(buffer) }
        }
        return buffers
    }

    private static func pixelBuffer(from image: CIImage) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(image.extent.width), Int(image.extent.height), kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CIContext().render(image, to: buffer)
        return buffer
    }

    /// Stops capturing and forgets the last result.
    public func stop() {
        let (camera, timer) = lock.withLock { () -> (RAVEPersonaCamera?, DispatchSourceTimer?) in
            generation += 1
            defer {
                self.camera = nil; self.fileTimer = nil; _latest = nil; lastBuffer = nil; lastLandmarks = nil
                meshNeedsReset = true
            }
            return (self.camera, self.fileTimer)
        }
        camera?.stop()
        timer?.cancel()
        if camera != nil || timer != nil { say(.stopped) }
    }

    // MARK: - Reading a frame

    private func take(_ buffer: CVPixelBuffer, at time: Double) {
        let now = CACurrentMediaTime()
        let go = lock.withLock { () -> Bool in
            stats_.captured += 1
            capturedTimes.append(now)
            if capturedTimes.count > 120 { capturedTimes.removeFirst(capturedTimes.count - 120) }
            stats_.size = "\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))"
            guard !busy else {
                stats_.dropped += 1
                return false
            }
            busy = true
            return true
        }
        guard go else { return }
        nonisolated(unsafe) let frame = buffer
        let orientation = self.orientation
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.read(frame, orientation: orientation, capturedAt: time)
        }
    }

    private func read(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, capturedAt: Double) async {
        let start = CACurrentMediaTime()
        var landmarks: FaceLandmarks?
        var failure: String?
        var used = FaceReader.vision
        if let mesh = meshForThisFrame() {
            used = .mesh
            do {
                landmarks = try mesh.read(buffer, orientation: orientation)?.landmarks
            } catch {
                failure = "face mesh: \(error)"
            }
        } else {
            (landmarks, failure) = await visionLandmarks(buffer, orientation: orientation)
        }
        let now = CACurrentMediaTime()
        let elapsed = (now - start) * 1000
        lock.withLock {
            busy = false
            sequence += 1
            _latest = Latest(sequence: sequence, landmarks: landmarks, reader: used, capturedAt: capturedAt)
            _activeReader = used
            stats_.activeReader = used.rawValue
            lastBuffer = buffer
            lastLandmarks = landmarks
            stats_.processed += 1
            if landmarks != nil { stats_.faces += 1 }
            if let failure { stats_.lastError = failure }
            stats_.lastMilliseconds = elapsed
            stats_.averageMilliseconds = stats_.averageMilliseconds == 0 ? elapsed : stats_.averageMilliseconds * 0.9 + elapsed * 0.1
            processedTimes.append(now)
            if processedTimes.count > 120 { processedTimes.removeFirst(processedTimes.count - 120) }
        }
    }

    /// The face mesh reader when it is the one asked for and its models
    /// load; nil for Vision. Loads them on first use, on the reading task.
    private func meshForThisFrame() -> FaceMeshReader? {
        let (wanted, failed, existing, reset) = lock.withLock { () -> (Bool, Bool, FaceMeshReader?, Bool) in
            defer { meshNeedsReset = false }
            return (_reader == .mesh, meshFailed, meshReader, meshNeedsReset)
        }
        guard wanted, !failed else { return nil }
        if let existing {
            if reset { existing.reset() }
            return existing
        }
        let start = CACurrentMediaTime()
        do {
            let made = try FaceMeshReader()
            let ms = Int((CACurrentMediaTime() - start) * 1000)
            RAVEFaceTrackingLog.tracker.info("Face mesh models loaded in \(ms, privacy: .public) ms")
            lock.withLock { meshReader = made }
            return made
        } catch {
            // The error is one of Core ML's or `FaceMeshReader.Failure`: no user data in it.
            RAVEFaceTrackingLog.tracker.error(
                "Face mesh models failed to load, reading with Vision instead: \(String(describing: error), privacy: .public)")
            lock.withLock {
                meshFailed = true
                stats_.lastError = "face mesh models failed to load (\(error)); reading with Vision"
            }
            return nil
        }
    }

    // MARK: - Vision

    private func visionLandmarks(_ buffer: CVPixelBuffer,
                                 orientation: CGImagePropertyOrientation) async -> (FaceLandmarks?, String?) {
        var landmarks: FaceLandmarks?
        var failure: String?
        do {
            #if targetEnvironment(simulator)
            var request = DetectFaceLandmarksRequest(simulatorRevision)
            // The simulator can't make Vision's default inference context
            // ("Could not create inference context"); the CPU it can.
            if let cpu = MLComputeDevice.allComputeDevices.first(where: { if case .cpu = $0 { true } else { false } }) {
                request.setComputeDevice(cpu, for: .main)
                request.setComputeDevice(cpu, for: .postProcessing)
            }
            #else
            let request = DetectFaceLandmarksRequest()
            #endif
            #if targetEnvironment(simulator)
            // Faces found first, on the CPU too: the landmark request's own
            // detection is what can't get a context there.
            var rectangles = DetectFaceRectanglesRequest()
            if let cpu = MLComputeDevice.allComputeDevices.first(where: { if case .cpu = $0 { true } else { false } }) {
                rectangles.setComputeDevice(cpu, for: .main)
            }
            request.inputFaceObservations = try await rectangles.perform(on: buffer, orientation: orientation)
            #endif
            let faces = try await request.perform(on: buffer, orientation: orientation)
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            // Turned a quarter, the picture Vision read is the other way round.
            let turned = [.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
            let size = turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
            // The biggest face is the wearer's.
            if let face = faces.max(by: { $0.boundingBox.width < $1.boundingBox.width }) {
                landmarks = Self.landmarks(of: face, size: size)
                // Points off the picture are no face. The visionOS
                // simulator's CPU model gives coordinates around 10¹².
                if let found = landmarks, !Self.inside(found, size) {
                    landmarks = nil
                    failure = "landmarks off the picture"
                }
            }
        } catch {
            failure = error.localizedDescription
            #if targetEnvironment(simulator)
            failure! += " (revision \(simulatorRevision.map { "\($0)" } ?? "default"), devices \(MLComputeDevice.allComputeDevices))"
            #endif
        }
        return (landmarks, failure)
    }

    static func inside(_ landmarks: FaceLandmarks, _ size: CGSize) -> Bool {
        let w = Float(size.width), h = Float(size.height)
        return landmarks.allPoints.allSatisfy { p in
            p.x.isFinite && p.y.isFinite && p.x > -w * 0.25 && p.x < w * 1.25 && p.y > -h * 0.25 && p.y < h * 1.25
        }
    }

    /// Vision's observation as `FaceLandmarks`, in pixels of a picture of
    /// `size`, y up.
    public static func landmarks(of face: FaceObservation, size: CGSize) -> FaceLandmarks? {
        guard let l = face.landmarks else { return nil }
        func points(_ region: FaceObservation.Landmarks2D.Region) -> [SIMD2<Float>] {
            region.pointsInImageCoordinates(size, origin: .lowerLeft).map { SIMD2(Float($0.x), Float($0.y)) }
        }
        func radians(_ angle: Measurement<UnitAngle>) -> Float { Float(angle.converted(to: .radians).value) }
        return FaceLandmarks(
            imageLeftEye: points(l.leftEye), imageRightEye: points(l.rightEye),
            imageLeftBrow: points(l.leftEyebrow), imageRightBrow: points(l.rightEyebrow),
            imageLeftPupil: points(l.leftPupil).first, imageRightPupil: points(l.rightPupil).first,
            outerLips: points(l.outerLips), innerLips: points(l.innerLips), nose: points(l.nose),
            yaw: radians(face.yaw), pitch: radians(face.pitch), roll: radians(face.roll),
            confidence: face.confidence)
    }

    /// The last frame Vision read, its landmarks drawn on it, as JPEG. It is
    /// the wearer's face: serve it only behind a screen-capture consent.
    public func lastFrameJPEG() -> Data? {
        let (buffer, landmarks) = lock.withLock { (lastBuffer, lastLandmarks) }
        guard let buffer else { return nil }
        var image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if let landmarks {
            let dot = CIImage(color: CIColor(red: 0, green: 1, blue: 0.6)).cropped(to: CGRect(x: -3, y: -3, width: 6, height: 6))
            for p in landmarks.allPoints {
                image = dot.transformed(by: CGAffineTransform(translationX: CGFloat(p.x), y: CGFloat(p.y)))
                    .composited(over: image)
            }
        }
        return CIContext().jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
    }

    public static func name(_ o: CGImagePropertyOrientation) -> String {
        switch o {
        case .up: "up"
        case .down: "down"
        case .left: "left"
        case .right: "right"
        case .upMirrored: "upMirrored"
        case .downMirrored: "downMirrored"
        case .leftMirrored: "leftMirrored"
        case .rightMirrored: "rightMirrored"
        @unknown default: "?"
        }
    }

    public static func orientation(named name: String) -> CGImagePropertyOrientation? {
        [CGImagePropertyOrientation.up, .down, .left, .right, .upMirrored, .downMirrored, .leftMirrored, .rightMirrored]
            .first { Self.name($0) == name }
    }
}
