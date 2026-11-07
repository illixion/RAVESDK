#if os(visionOS)
import AVFoundation
import Foundation

/// Keeps an app activity running when attention moves elsewhere, using the
/// same mixable silent playback pattern as Apparition's JIT service.
/// Declare UIBackgroundModes/audio in the host. Stop when the activity ends.
/// This owns only its silent renderer, never the app's shared audio session.
@MainActor
public final class RAVEAudioActivityHold {
    public enum Failure: Error { case recordingOnlySession, unavailableBuffer }
    public private(set) var isRequested = false
    public private(set) var lastFailure: String?
    public var isRunning: Bool { engine?.isRunning == true && player?.isPlaying == true }
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var interruption: NSObjectProtocol?
    private var configuration: NSObjectProtocol?
    private var restart: Task<Void, Never>?

    public init() {}

    public func start() throws {
        isRequested = true
        guard !isRunning else { return }
        do {
            try buildRenderer()
            if interruption == nil {
                interruption = NotificationCenter.default.addObserver(
                    forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
                ) { [weak self] note in
                    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                          AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                    Task { @MainActor [weak self] in self?.scheduleResume() }
                }
            }
            lastFailure = nil
        } catch {
            stop()
            lastFailure = "startFailed"
            throw error
        }
    }

    public func stop() {
        isRequested = false
        restart?.cancel(); restart = nil
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        interruption = nil
        stopRenderer()
        // Do not deactivate AVAudioSession: voice capture or real playback
        // elsewhere in the app may still own it.
    }

    private func stopRenderer() {
        if let configuration { NotificationCenter.default.removeObserver(configuration) }
        configuration = nil
        player?.stop(); engine?.stop()
        player = nil; engine = nil
    }

    private func buildRenderer() throws {
        stopRenderer()
        let session = AVAudioSession.sharedInstance()
        guard session.category != .record else { throw Failure.recordingOnlySession }
        let preserve = session.category == .playAndRecord || session.category == .multiRoute || session.category == .playback
        let category: AVAudioSession.Category = preserve ? session.category : .playback
        let options: AVAudioSession.CategoryOptions = preserve ? session.categoryOptions.union(.mixWithOthers) : .mixWithOthers
        if session.category != category || session.categoryOptions != options {
            try session.setCategory(category, mode: preserve ? session.mode : .default, options: options)
        }
        try session.setActive(true)
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000),
              let samples = buffer.floatChannelData else { throw Failure.unavailableBuffer }
        buffer.frameLength = buffer.frameCapacity
        samples[0].update(repeating: 0, count: Int(buffer.frameLength))
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        try engine.start()
        player.play()
        self.engine = engine; self.player = player
        configuration = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleResume() }
        }
    }

    private func scheduleResume() {
        guard isRequested, restart == nil else { return }
        restart = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self, self.isRequested else { return }
            self.restart = nil
            do { try self.buildRenderer(); self.lastFailure = nil }
            catch { self.lastFailure = "resumeFailed" }
        }
    }
}
#endif
