/*
 RAVEVoiceEngine — one microphone and one output per process, with Apple's
 voice processing between them.

 Why one engine. Voice processing (`setVoiceProcessingEnabled`: echo
 cancellation, noise suppression, AGC) cancels only what plays through the
 *same* I/O unit. Two engines in one process (a call's playback in one, the
 character's speech in another, a microphone tap in a third) each hear the
 others as room sound, and two engines that each read `inputNode` are two
 captures fighting over one microphone. Under Nexus every module is in one
 process, so everything that captures or plays voice goes through this engine:
 Raven's call bridge (a relocated call's remote audio out, the wearer's voice in),
 the character's speech out, and its mouth, dictation and stream program in.

 Measured on visionOS 27 (2026-11-13) and the reason this exists:
 - The headset's plain microphone mode does not cancel anything. Loud sounds,
   music and a TV in the room come through it, and a call's far end hears its
   own voice back from the speakers.
 - Voice processing does not turn other apps' audio down: Longwave plays
   alongside WebKit's audio in Raven with it on.
 - `AVAudioSession.prefersEchoCancelledInput` (system-wide echo cancellation)
   is iOS 18.2+ only and does not exist on visionOS, so one shared engine is
   the only way to cancel more than one source.

 Shape:
 - **Outputs** hand over their nodes and a `connect` closure that wires them
   in the engine it is given. The engine can be replaced (releasing the
   microphone needs a fresh engine, see `rebuild`), so a client never keeps
   the engine; its nodes move to each new one, and `onRestart` tells it that
   anything it had scheduled (and any tap on its nodes) is gone.
 - **Captures** subscribe to the processed microphone in one of two ways: a
   realtime sink (every IO buffer on the render thread, a few milliseconds,
   no allocation allowed: a mouth that follows syllables) or a buffer tap
   (~100 ms `AVAudioPCMBuffer`s on the tap thread: dictation, a call's PCM
   wire). Both are fed from one input; the first capture brings voice
   processing up and the last one takes the microphone down.
 - **The session** is moved only as far as needed and never back:
   `.playAndRecord` + `.mixWithOthers` once anything captures (Longwave's
   configuration; it measured that switching between playback and
   playAndRecord pauses other apps on visionOS, so the category stays), and
   `.playback` + `.mixWithOthers` for output alone when the current category
   cannot play. Options already set are kept and `.mixWithOthers` is added.

 Starting capture stops and restarts the engine (voice processing can only be
 switched with the engine stopped), so an output's queued audio is dropped at
 that moment; `onRestart` is how the client finds out.
 */

#if os(visionOS) || os(iOS) || os(macOS)
import AVFoundation
import DebugLog
import Foundation

/// A realtime consumer of the processed microphone: mono samples of one IO
/// buffer, at the capture format's sample rate. Runs on the render thread;
/// it must not allocate, lock for long, or touch the main actor.
public typealias RAVEVoiceRealtimeSink = @Sendable (_ samples: UnsafePointer<Float>, _ count: Int) -> Void

/// A buffered consumer of the processed microphone, on the tap's thread.
public typealias RAVEVoiceBufferSink = @Sendable (_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) -> Void

public enum RAVEVoiceEngineError: Error, Sendable {
    case microphonePermissionDenied
    case noMicrophone
    case engineFailed(String)
}

public enum RAVEVoiceLog {
    public static let engine = DebugLogger(subsystem: "com.illixion.rave", category: "VoiceEngine")
}

@MainActor
public final class RAVEVoiceEngine {
    public static let shared = RAVEVoiceEngine()

    /// Posted on the main thread when capture starts or stops.
    public static let captureDidChange = Notification.Name("RAVEVoiceEngine.captureDidChange")

    /// The engine as it is now. Read it for timing (`outputNode.presentationLatency`,
    /// a node's `lastRenderTime`), never keep it: it is replaced when the
    /// microphone is released.
    public private(set) var engine = AVAudioEngine()
    public private(set) var isRunning = false
    /// Whether the microphone is open (any capture subscriber).
    public var isCapturing: Bool { !captures.isEmpty }
    /// Whether voice processing is on for the current capture. False when the
    /// platform refused it; capture then runs plain.
    public private(set) var voiceProcessing = false
    /// The processed microphone's format while capturing.
    public private(set) var captureFormat: AVAudioFormat?

    private struct Output {
        let nodes: [AVAudioNode]
        let connect: (AVAudioEngine) throws -> Void
        let onRestart: () -> Void
    }

    private struct Capture {
        let realtime: RAVEVoiceRealtimeSink?
        let buffers: RAVEVoiceBufferSink?
    }

    private var outputs: [ObjectIdentifier: Output] = [:]
    /// Order outputs were added, so reinstalling is deterministic.
    private var outputOrder: [ObjectIdentifier] = []
    private var captures: [ObjectIdentifier: Capture] = [:]
    private let fanout = Fanout()
    private var sinkNode: AVAudioSinkNode?
    private var tapInstalled = false
    private var observers: [NSObjectProtocol] = []
    private var recordPermission: Bool?

    private init() {}

    // MARK: Outputs

    /// Adds an output: `nodes` are attached to the engine and `connect` wires
    /// them (ending at `engine.mainMixerNode`, normally). Both happen now and
    /// again for every engine that replaces this one, so a client never keeps
    /// the engine. `onRestart` runs after any stop and restart of the engine:
    /// whatever the client had scheduled on its nodes is gone, and a tap on
    /// one of them has to be installed again.
    public func addOutput(
        _ owner: AnyObject,
        nodes: [AVAudioNode],
        connect: @escaping (AVAudioEngine) throws -> Void,
        onRestart: @escaping () -> Void = {}
    ) throws {
        let id = ObjectIdentifier(owner)
        guard outputs[id] == nil else { return }
        let output = Output(nodes: nodes, connect: connect, onRestart: onRestart)
        outputs[id] = output
        outputOrder.append(id)
        do {
            if !isRunning { prepareSession() }
            try install(output, into: engine)
            if !isRunning { try startEngine() }
        } catch {
            outputs[id] = nil
            outputOrder.removeAll { $0 == id }
            detach(output, from: engine)
            RAVEVoiceLog.engine.error("output failed to install: \(error.localizedDescription, privacy: .private)")
            throw RAVEVoiceEngineError.engineFailed(error.localizedDescription)
        }
    }

    /// Removes an output and detaches its nodes. Stops the engine when
    /// nothing is left.
    public func removeOutput(_ owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        guard let output = outputs.removeValue(forKey: id) else { return }
        outputOrder.removeAll { $0 == id }
        detach(output, from: engine)
        stopIfIdle()
    }

    private func install(_ output: Output, into engine: AVAudioEngine) throws {
        for node in output.nodes where node.engine == nil { engine.attach(node) }
        try output.connect(engine)
    }

    private func detach(_ output: Output, from engine: AVAudioEngine) {
        for node in output.nodes where node.engine === engine { engine.detach(node) }
    }

    // MARK: Captures

    /// Opens the microphone for `owner` (or adds it to the open one) and
    /// returns the processed capture format. Asks for record permission the
    /// first time.
    @discardableResult
    public func addCapture(
        _ owner: AnyObject,
        realtime: RAVEVoiceRealtimeSink? = nil,
        buffers: RAVEVoiceBufferSink? = nil
    ) async throws -> AVAudioFormat {
        if recordPermission != true {
            recordPermission = await AVAudioApplication.requestRecordPermission()
            RAVEVoiceLog.engine.info("record permission \(self.recordPermission == true ? "granted" : "denied", privacy: .public)")
        }
        guard recordPermission == true else { throw RAVEVoiceEngineError.microphonePermissionDenied }

        let id = ObjectIdentifier(owner)
        let wasCapturing = isCapturing
        captures[id] = Capture(realtime: realtime, buffers: buffers)
        publishSinks()

        if wasCapturing, isRunning, let captureFormat { return captureFormat }
        do {
            try openMicrophone()
        } catch {
            captures[id] = nil
            publishSinks()
            if !wasCapturing { rebuild(reason: "microphone failed to open") }
            throw error
        }
        guard let captureFormat else { throw RAVEVoiceEngineError.noMicrophone }
        NotificationCenter.default.post(name: Self.captureDidChange, object: self)
        return captureFormat
    }

    /// Stops delivering to `owner`; the last capture closes the microphone.
    public func removeCapture(_ owner: AnyObject) {
        guard captures.removeValue(forKey: ObjectIdentifier(owner)) != nil else { return }
        publishSinks()
        guard captures.isEmpty else { return }
        rebuild(reason: "microphone released")
        NotificationCenter.default.post(name: Self.captureDidChange, object: self)
    }

    // MARK: Lifecycle

    /// - Parameter notify: tell outputs their queued audio is gone (the
    ///   caller notifies itself when it is rebuilding anyway).
    private func openMicrophone(notify: Bool = true) throws {
        prepareSession()
        let wasRunning = isRunning
        if wasRunning { engine.stop() }
        let input = engine.inputNode
        if !voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                voiceProcessing = true
            } catch {
                RAVEVoiceLog.engine.error("voice processing unavailable, capturing plain: \(error.localizedDescription, privacy: .private)")
            }
        }
        try connectInput()
        try startEngine()
        if wasRunning, notify { notifyRestart() }
        RAVEVoiceLog.engine.info("""
        microphone open: \(self.captureFormat?.sampleRate ?? 0, privacy: .public) Hz \
        ×\(self.captureFormat?.channelCount ?? 0, privacy: .public) \
        voiceProcessing=\(self.voiceProcessing ? "on" : "off", privacy: .public) \
        outputs=\(self.outputs.count, privacy: .public) captures=\(self.captures.count, privacy: .public)
        """)
    }

    /// Connects the input to the realtime fan-out and installs the buffer tap.
    /// The input's format is read after voice processing is set, which changes it.
    private func connectInput() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RAVEVoiceEngineError.noMicrophone }
        captureFormat = format
        if let sinkNode { engine.disconnectNodeInput(sinkNode) } else {
            let node = Self.makeSinkNode(fanout)
            engine.attach(node)
            sinkNode = node
        }
        if let sinkNode { engine.connect(input, to: sinkNode, format: format) }
        if tapInstalled { input.removeTap(onBus: 0) }
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.makeTapBlock(fanout))
        tapInstalled = true
    }

    private func startEngine() throws {
        // Even with only an input, the mixer has to reach the output for the
        // I/O unit to run.
        _ = engine.mainMixerNode
        engine.prepare()
        do {
            try engine.start()
        } catch {
            isRunning = false
            RAVEVoiceLog.engine.error("engine start failed: \(error.localizedDescription, privacy: .private)")
            throw RAVEVoiceEngineError.engineFailed(error.localizedDescription)
        }
        if !isRunning {
            isRunning = true
            installObservers()
        }
    }

    /// Replaces the engine with a fresh one that has never opened the
    /// microphone, reinstalling every output, and reopens capture if anyone
    /// still captures. Dropping the input-owning engine is what releases the
    /// microphone (Raven's call engine measured that switching voice
    /// processing off is not enough); outputs carry on in the new one.
    private func rebuild(reason: String) {
        if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
        engine.stop()
        if voiceProcessing { try? engine.inputNode.setVoiceProcessingEnabled(false) }
        voiceProcessing = false
        removeObservers()
        isRunning = false
        // An AVAudioNode belongs to one engine at a time: let go of the clients'
        // nodes before the old engine goes, so the new one can take them.
        for output in outputs.values { detach(output, from: engine) }
        if let sinkNode { engine.detach(sinkNode) }
        sinkNode = nil
        captureFormat = nil
        engine = AVAudioEngine()

        guard !outputs.isEmpty || !captures.isEmpty else {
            RAVEVoiceLog.engine.info("engine stopped (\(reason, privacy: .public))")
            return
        }
        do {
            for id in outputOrder { if let output = outputs[id] { try install(output, into: engine) } }
            if !captures.isEmpty {
                try openMicrophone(notify: false)
            } else {
                try startEngine()
            }
            RAVEVoiceLog.engine.info("engine rebuilt (\(reason, privacy: .public)): outputs=\(self.outputs.count, privacy: .public) captures=\(self.captures.count, privacy: .public)")
        } catch {
            RAVEVoiceLog.engine.error("engine rebuild failed (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .private)")
        }
        notifyRestart()
    }

    private func stopIfIdle() {
        guard outputs.isEmpty, captures.isEmpty, isRunning else { return }
        rebuild(reason: "idle")
    }

    /// The I/O unit was rebuilt under the engine (a route or session change)
    /// or an interruption stopped it: reconnect the input at whatever format it
    /// has now and start again.
    private func restart(reason: String) {
        guard isRunning else { return }
        engine.stop()
        do {
            if isCapturing { try connectInput() }
            try startEngine()
            RAVEVoiceLog.engine.info("engine restarted (\(reason, privacy: .public))")
        } catch {
            RAVEVoiceLog.engine.error("engine restart failed (\(reason, privacy: .public)), rebuilding")
            rebuild(reason: "restart failed")
            return
        }
        notifyRestart()
    }

    private func notifyRestart() {
        for id in outputOrder { outputs[id]?.onRestart() }
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { _ in
            MainActor.assumeIsolated { RAVEVoiceEngine.shared.restart(reason: "configuration change") }
        })
        #if !os(macOS)
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended else { return }
            MainActor.assumeIsolated { RAVEVoiceEngine.shared.restart(reason: "interruption ended") }
        })
        #endif
    }

    private func removeObservers() {
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers = []
    }

    // MARK: Session

    private func prepareSession() {
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        do {
            if !captures.isEmpty {
                if session.category != .playAndRecord {
                    try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
                } else if !session.categoryOptions.contains(.mixWithOthers) {
                    try session.setCategory(.playAndRecord, mode: session.mode,
                                            options: session.categoryOptions.union(.mixWithOthers))
                }
            } else {
                let plays: Set<AVAudioSession.Category> = [.playAndRecord, .playback, .multiRoute]
                if !plays.contains(session.category) {
                    try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                }
            }
            try session.setActive(true)
        } catch {
            RAVEVoiceLog.engine.error("session refused: \(error.localizedDescription, privacy: .private)")
        }
        #endif
    }

    // MARK: Fan-out

    private func publishSinks() {
        let ordered = captures.values
        fanout.set(realtime: ordered.compactMap(\.realtime), buffers: ordered.compactMap(\.buffers))
    }

    // Built outside the main actor: these run on the render and tap threads,
    // and a closure written in a main-actor method would be main-actor
    // isolated and trap on its first call (Raven's call engine, first device run).
    private nonisolated static func makeSinkNode(_ fanout: Fanout) -> AVAudioSinkNode {
        AVAudioSinkNode { _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
            guard let first = buffers.first, let data = first.mData, frameCount > 0 else { return noErr }
            fanout.deliver(UnsafePointer(data.assumingMemoryBound(to: Float.self)), count: Int(frameCount))
            return noErr
        }
    }

    private nonisolated static func makeTapBlock(_ fanout: Fanout) -> AVAudioNodeTapBlock {
        { buffer, time in fanout.deliver(buffer, time: time) }
    }
}

/// The subscriber lists the render and tap threads read. Swapped whole under
/// a lock held only for an array copy (a retain, no allocation), the same
/// bargain Raven's playback ring makes.
private final class Fanout: @unchecked Sendable {
    private let lock = NSLock()
    private var realtime: [RAVEVoiceRealtimeSink] = []
    private var buffers: [RAVEVoiceBufferSink] = []

    func set(realtime: [RAVEVoiceRealtimeSink], buffers: [RAVEVoiceBufferSink]) {
        lock.withLock {
            self.realtime = realtime
            self.buffers = buffers
        }
    }

    func deliver(_ samples: UnsafePointer<Float>, count: Int) {
        let sinks = lock.withLock { realtime }
        for sink in sinks { sink(samples, count) }
    }

    func deliver(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let sinks = lock.withLock { buffers }
        for sink in sinks { sink(buffer, time) }
    }
}
#endif
