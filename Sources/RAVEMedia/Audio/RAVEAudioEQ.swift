/*
 RAVEMedia - one audio EQ for an app.

 Like the listening volume, the EQ is the listener's, not a video's or a song's:
 `RAVEAudioEQ` holds the one `EQSettings` (persisted; `EQSettings.defaultsKey`
 in the defaults it is given), and every processor the app has running follows
 it live. Hosts attach it where they make audio:

 - `attach(to:player:)` for an `AVPlayerItem`: the tap (`EQAudioTap`) on a
   file, or for HLS, which no tap reaches, the stream path (`EQStreamPlayback`:
   the host's `streamSource` reads the audio, which is played through the EQ
   in the player's place, on its clock);
 - `makeProcessor(channelCount:sampleRate:)` for a host that renders audio
   itself and calls `EQProcessor.process` (RAVEFilm's object audio).

 Processors are held weakly: when a player item or a film goes, its processor
 goes with it, and nothing here needs telling.
 */

import AVFoundation
import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
@Observable
public final class RAVEAudioEQ {
    /// The listener's curve. Changing it saves it and moves every live processor. While Auto
    /// preamp is on, the preamp is re-trimmed on every band change (and when Auto turns on) so a
    /// boosted curve never plays louder than flat; the editor leaves that to its host.
    public var settings: EQSettings {
        didSet {
            guard settings != oldValue else { return }
            if settings.autoPreamp, settings.bands != oldValue.bands || !oldValue.autoPreamp {
                settings.autoTrimPreamp() // assigning inside didSet doesn't re-enter it
            }
            scheduleSave()
            pushToProcessors()
            updateStreams()
        }
    }

    /// Saved curves (the editor reads and writes `EQPreset`'s own store; this mirrors it for menus).
    public private(set) var customPresets: [EQPreset]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let processors = NSHashTable<EQProcessor>.weakObjects()
    @ObservationIgnored private let saveDelay: Duration
    /// Reads an HLS item's audio for the stream path; without one, HLS stays unequalised.
    @ObservationIgnored public var streamSource: EQStreamSource?
    /// The HLS items being equalised, each until its item or player goes.
    @ObservationIgnored public private(set) var streams: [EQStreamPlayback] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var resignObserver: NSObjectProtocol?

    /// - Parameter saveDelay: how long after the last change the curve is written. A drag in the
    ///   editor changes it every frame, and a write to the defaults can stall a player's main
    ///   thread (Hypnos measured ~40 ms), so a drag costs one write after it ends. `.zero` saves at once.
    public init(defaults: UserDefaults = .standard, saveDelay: Duration = .milliseconds(600)) {
        self.defaults = defaults
        self.saveDelay = saveDelay
        settings = EQSettings.load(from: defaults)
        customPresets = EQPreset.loadCustom(from: defaults)
        // A change made in the last moments before the app is suspended still gets written.
        #if canImport(UIKit)
        let resign = UIApplication.willResignActiveNotification
        #elseif canImport(AppKit)
        let resign = NSApplication.willResignActiveNotification
        #endif
        #if canImport(UIKit) || canImport(AppKit)
        resignObserver = NotificationCenter.default.addObserver(forName: resign, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        #endif
    }

    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    /// Writes the curve now, instead of after the debounce.
    public func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        settings.save(to: defaults)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        guard saveDelay > .zero else {
            settings.save(to: defaults)
            return
        }
        saveTask = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            self.settings.save(to: self.defaults)
        }
    }

    /// Whether the EQ is on and shaping anything.
    public var isActive: Bool {
        settings.enabled && (!settings.bands.isEmpty || settings.preampDB != 0)
    }

    /// Name of the preset the bands match, if any: "Flat", "Bass Boost", a saved one. Nil for a
    /// hand-made curve.
    public var matchingPresetName: String? {
        (EQPreset.builtIns + customPresets).first { Self.sameBands($0.bands, settings.bands) }?.name
    }

    /// Whether `preset` is the curve in force (the EQ is on and its bands are the preset's).
    public func matches(_ preset: EQPreset) -> Bool {
        settings.enabled && Self.sameBands(preset.bands, settings.bands)
    }

    private static func sameBands(_ a: [EQBandSetting], _ b: [EQBandSetting]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy {
            $0.type == $1.type && $0.frequency == $1.frequency && $0.gain == $1.gain && $0.q == $1.q
        }
    }

    // MARK: - Editing

    /// Applies a preset's bands (and turns the EQ on, as the editor's own menu does).
    public func apply(_ preset: EQPreset) {
        var next = settings
        next.bands = preset.bands
        next.enabled = true
        settings = next
    }

    public func setEnabled(_ enabled: Bool) {
        settings.enabled = enabled
    }

    /// Re-reads the saved presets, after the editor has added or removed one.
    public func reloadPresets() {
        customPresets = EQPreset.loadCustom(from: defaults)
    }

    // MARK: - Hosts

    /// A processor that follows `settings`. The caller owns it; the EQ holds it weakly.
    public func makeProcessor(channelCount: Int = 2, sampleRate: Double = EQSettings.displaySampleRate) -> EQProcessor {
        let processor = EQProcessor(channelCount: channelCount, sampleRate: sampleRate)
        processor.update(settings)
        processors.add(processor)
        return processor
    }

    /// Makes a processor the host built itself follow `settings`, from now.
    public func follow(_ processor: EQProcessor) {
        processor.update(settings)
        processors.add(processor)
    }

    /// Puts the EQ on `item`'s audio. Safe to call once playback has started (the mix applies
    /// live). An HLS item, which no tap reaches, is equalised by playing its audio in `player`'s
    /// place (`.streamed`) when there is a `streamSource` and a player; otherwise it comes back
    /// `.noAudioTrack` and is untouched. `onResult` hears a later failure of the stream path.
    @discardableResult
    public func attach(to item: AVPlayerItem, player: AVPlayer? = nil,
                       onResult: (@MainActor (EQAttachResult) -> Void)? = nil) async -> EQAttachResult {
        let (mix, result) = await audioMix(for: item.asset)
        if let mix { item.audioMix = mix }
        guard result == .noAudioTrack, let player, let streamSource else { return result }
        return attachStream(to: item, player: player, source: streamSource, onResult: onResult)
    }

    /// The stream path for `item` (`EQStreamPlayback`), whatever the item is.
    @discardableResult
    func attachStream(to item: AVPlayerItem, player: AVPlayer, source: @escaping EQStreamSource,
                      onResult: (@MainActor (EQAttachResult) -> Void)? = nil) -> EQAttachResult {
        streams.removeAll { $0.item == nil || $0.player == nil || $0.item === item }
        let playback = EQStreamPlayback(player: player, item: item, eq: self, source: source, onResult: onResult)
        streams.append(playback)
        RAVEMediaLog.audioEQ.info("Equalising an HLS stream through its own audio path")
        return .streamed
    }

    /// The stream path for `item`, if it has one.
    public func streamPlayback(for item: AVPlayerItem) -> EQStreamPlayback? {
        streams.first { $0.item === item }
    }

    private func updateStreams() {
        streams.removeAll { !$0.update() }
    }

    /// The audio mix that carries the EQ for `asset`: what `attach` sets on an item, for a host
    /// that reads audio itself (an `AVAssetReaderAudioMixOutput`, an export). Nil with the reason
    /// when the asset has no audio track a tap can reach.
    public func audioMix(for asset: AVAsset) async -> (mix: AVAudioMix?, result: EQAttachResult) {
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            return (nil, .failed(error.localizedDescription))
        }
        guard !tracks.isEmpty else { return (nil, .noAudioTrack) }

        var inputs: [AVAudioMixInputParameters] = []
        for track in tracks {
            let processor = makeProcessor()
            guard let tap = EQAudioTap.makeTap(processor: processor) else { continue }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTapProcessor = tap
            inputs.append(parameters)
        }
        guard !inputs.isEmpty else { return (nil, .failed("The audio tap could not be created.")) }
        let mix = AVMutableAudioMix()
        mix.inputParameters = inputs
        return (mix, .attached)
    }

    private func pushToProcessors() {
        let settings = settings
        for processor in processors.allObjects { processor.update(settings) }
    }
}

extension AVPlayer {
    /// Whether the listener has this player muted. That is `isMuted`, except while the
    /// equalizer plays an HLS item's sound in the player's place (`EQStreamPlayback`), which
    /// mutes the player itself: read this, not `isMuted`, for what a mute button shows.
    @MainActor public var listenerIsMuted: Bool {
        EQStreamPlayback.live.allObjects.first { $0.player === self && $0.isSounding }?.isListenerMuted ?? isMuted
    }
}

extension AVPlayerItem {
    /// Puts the app's EQ (`RAVEMediaPolicy.audioEQ`) on this item's audio, once its tracks load,
    /// and says what came of it. A no-op without an EQ. Call it once the item has its player,
    /// like `applySpatialAudioPolicy`. HLS needs `player` (its sound is played in the player's
    /// place, `.streamed`); without one it is `.noAudioTrack`. `onResult` may be called again
    /// later, with `.failed`, if the stream path gives up.
    @MainActor
    public func attachAudioEQ(player: AVPlayer? = nil, onResult: (@MainActor (EQAttachResult) -> Void)? = nil) {
        guard let eq = RAVEMediaPolicy.audioEQ else { return }
        Task { @MainActor [weak self, weak player] in
            guard let self else { return }
            let result = await eq.attach(to: self, player: player, onResult: onResult)
            onResult?(result)
        }
    }
}
