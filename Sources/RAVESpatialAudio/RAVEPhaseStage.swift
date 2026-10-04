/*
 RAVESDK - a PHASE sound stage fed by streams

 Positioned sources and head-locked beds, each fed by a pull-stream render
 block, heard by one listener, in a room whose reverb the app (and so the
 user) can change while it plays. It knows nothing about what feeds the
 streams: Hypnos's film player hands it Atmos elements; a game can hand it
 channels of its own mixer.

 Why PHASE rather than RealityKit or AVAudioEnvironmentNode: on tvOS, iOS
 and macOS it is one of the three engines the system applies AirPods head
 tracking (`automaticHeadTrackingFlags`, needs the
 `com.apple.developer.coremotion.head-pose` entitlement) and the listener's
 personalized spatial audio profile to
 (`com.apple.developer.spatial-audio.profile-access`), and it has room
 reverb built in. RealityKit gets neither.

 Measured on an Apple TV 4K (tvOS 27, 2026-09-27, Hypnos's FilmLabTV
 probe): binaural rendering and head tracking work on AirPods Max, and on a
 HomePod mini stereo pair once the output is forced binaural; left
 automatic, PHASE chose plain speaker panning there, which heard as stereo.
 A pull stream's render block stamps a valid sample and host time, on its
 own sample timeline per stream, so a caller that keeps several streams
 sample-locked must align them by host time.

 visionOS: PHASE renders through the system spatializer, which pins app
 audio to the window and was deafening in LambdaVision (visionOS 26).
 visionOS 26 added a rendering mode: `systemRendering: true` builds the
 engine with `.client`, which renders in the system's audio server, where
 Apple says it can apply low-latency head tracking and the personalized
 profile. Longwave's Moonlight surround is the first visionOS consumer and
 uses it (2026-10-04); not yet heard on a headset, so start quiet.

 Coordinates are the listener's: −z forward, +x right, +y up, metres.
 */

import DebugTrace
import AVFAudio
import Foundation
import os
import PHASE
import simd

/// A PHASE reverb, named for a settings picker.
public enum RAVEReverbPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case none, smallRoom, mediumRoom, largeRoom, mediumChamber, largeChamber, mediumHall, largeHall, cathedral

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: "Off"
        case .smallRoom: "Small Room"
        case .mediumRoom: "Medium Room"
        case .largeRoom: "Large Room"
        case .mediumChamber: "Chamber"
        case .largeChamber: "Large Chamber"
        case .mediumHall: "Hall"
        case .largeHall: "Large Hall"
        case .cathedral: "Cathedral"
        }
    }

    var phase: PHASEReverbPreset {
        switch self {
        case .none: .none
        case .smallRoom: .smallRoom
        case .mediumRoom: .mediumRoom
        case .largeRoom: .largeRoom
        case .mediumChamber: .mediumChamber
        case .largeChamber: .largeChamber
        case .mediumHall: .mediumHall
        case .largeHall: .largeHall
        case .cathedral: .cathedral
        }
    }
}

/// The stage. Build it, add every source, then `start()`; sources can't be
/// added to a running stage (tear it down and build a new one instead).
// Pull streams and automatic head tracking; the package floor stays at
// macOS 14 for Longwave's Mac app.
@available(macOS 15.0, *)
@MainActor
public final class RAVEPhaseStage {
    public enum SourceKind: Sendable {
        /// Placed in the room, spatialized, reverberant.
        case positioned
        /// Head-locked and dry, e.g. an LFE channel.
        case bed
    }

    /// The render block's shape: `PHASEPullStreamRenderHandler`, which is
    /// the same function type as `AVAudioSourceNodeRenderBlock` and
    /// RealityKit's `Audio.GeneratorRenderHandler`.
    public typealias RenderHandler = PHASEPullStreamRenderHandler

    private struct Source {
        let kind: SourceKind
        let object: PHASESource?
        let assetID: String
        var event: PHASESoundEvent?
    }

    private static let sendParameterID = "rave-reverb-send"
    private static let streamID = "rave-stream"

    private let engine: PHASEEngine
    private let listener: PHASEListener
    private let spatialMixer: PHASESpatialMixerDefinition
    private let bedMixer: PHASEChannelMixerDefinition
    private let format: AVAudioFormat
    private let stagePrefix = "rave-stage-\(UUID().uuidString)"
    private var sources: [Int: Source] = [:]
    private var recenterTask: Task<Void, Never>?
    private(set) public var isRunning = false
    private let logger = DebugLogger(subsystem: "com.illixion.ravesdk", category: "PhaseStage")

    /// Linear reverb send, 0…1, applied to every positioned source.
    public private(set) var reverbSend: Double
    public private(set) var reverbPreset: RAVEReverbPreset

    /// - Parameters:
    ///   - sampleRate: every stream's rate; each stream is mono.
    ///   - binaural: always render for headphones. Off lets PHASE choose by
    ///     route, which on AirPlay speakers means plain panning.
    ///   - systemRendering: visionOS only, ignored elsewhere: render in the
    ///     system's audio server (`PHASEEngine.RenderingMode.client`) rather
    ///     than in-process. Off keeps the engine's default mode.
    public init(sampleRate: Double, binaural: Bool = true, headTracking: Bool = true,
                reverbPreset: RAVEReverbPreset = .mediumRoom, reverbSend: Double = 0.25,
                systemRendering: Bool = false) {
        #if os(visionOS)
        engine = systemRendering
            ? PHASEEngine(updateMode: .automatic, renderingMode: .client)
            : PHASEEngine(updateMode: .automatic)
        #else
        engine = PHASEEngine(updateMode: .automatic)
        #endif
        if binaural { engine.outputSpatializationMode = .alwaysUseBinaural }
        engine.defaultReverbPreset = reverbPreset.phase
        self.reverbPreset = reverbPreset
        self.reverbSend = reverbSend

        listener = PHASEListener(engine: engine)
        listener.transform = matrix_identity_float4x4
        listener.automaticHeadTrackingFlags = headTracking ? [.orientation] : []

        let pipeline = PHASESpatialPipeline(flags: [.directPathTransmission, .lateReverb])!
        if let reverb = pipeline.entries[.lateReverb] {
            reverb.sendLevel = reverbSend
            reverb.sendLevelMetaParameterDefinition = PHASENumberMetaParameterDefinition(
                value: reverbSend, minimum: 0, maximum: 1, identifier: Self.sendParameterID
            )
        }
        spatialMixer = PHASESpatialMixerDefinition(spatialPipeline: pipeline)
        // Level is the caller's business: no distance falloff, so a source's
        // direction is all its position changes.
        let distance = PHASEGeometricSpreadingDistanceModelParameters()
        distance.rolloffFactor = 0
        spatialMixer.distanceModelParameters = distance

        bedMixer = PHASEChannelMixerDefinition(channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Mono)!)
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        do {
            try engine.rootObject.addChild(listener)
        } catch {
            logger.error("Listener: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Adds a source under `id`, fed by `render` on PHASE's realtime thread.
    /// `render` must not be a closure literal written in a main-actor
    /// context: it would inherit that isolation and trap on first call.
    public func addSource(id: Int, kind: SourceKind, render: @escaping RenderHandler) throws {
        precondition(!isRunning, "add sources before start()")
        let assetID = "\(stagePrefix)-\(id)"
        let stream = PHASEPullStreamNodeDefinition(
            mixerDefinition: kind == .positioned ? spatialMixer : bedMixer,
            format: format, identifier: Self.streamID
        )
        // Unity gain: the caller's samples are already at their level.
        stream.setCalibrationMode(calibrationMode: .relativeSpl, level: 0)
        _ = try engine.assetRegistry.registerSoundEventAsset(rootNode: stream, identifier: assetID)

        let parameters = PHASEMixerParameters()
        var object: PHASESource?
        switch kind {
        case .positioned:
            let source = PHASESource(engine: engine)
            try engine.rootObject.addChild(source)
            parameters.addSpatialMixerParameters(identifier: spatialMixer.identifier, source: source, listener: listener)
            object = source
        case .bed:
            break
        }
        let event = try PHASESoundEvent(engine: engine, assetIdentifier: assetID, mixerParameters: parameters)
        guard let node = event.pullStreamNodes[Self.streamID] else { throw StageError.noStreamNode }
        node.renderHandler = render
        sources[id] = Source(kind: kind, object: object, assetID: assetID, event: event)
    }

    /// Starts the engine and every source in the same turn. Sources render
    /// whatever their blocks produce from here on (silence until the
    /// caller's transport plays).
    public func start() throws {
        guard !isRunning else { return }
        try engine.start()
        for source in sources.values { source.event?.start() }
        isRunning = true
        logger.info("Started \(self.sources.count) sources")
    }

    /// Stops rendering without tearing anything down; `resume()` restarts
    /// it. On tvOS/iOS the system decides whether AirPods' and the remote's
    /// play/pause means play or pause from whether the app is producing
    /// audio, so a paused caller should pause the stage too: rendering
    /// silence reads as still playing, and every press arrives as pause.
    public func pause() {
        guard isRunning else { return }
        engine.pause()
    }

    public func resume() {
        guard isRunning else { return }
        do {
            try engine.start()
        } catch {
            logger.error("Resume: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func stop() {
        for source in sources.values {
            source.event?.stopAndInvalidate()
        }
        engine.stop()
        for source in sources.values {
            engine.assetRegistry.unregisterAsset(identifier: source.assetID, completion: nil)
            if let object = source.object { engine.rootObject.removeChild(object) }
        }
        sources.removeAll()
        isRunning = false
    }

    /// Adds one source per speaker of `layout`, each fed by `feed`'s
    /// channel of the same index: the LFE as a head-locked bed, the rest
    /// positioned `distance` metres away. Returns the speakers added.
    @discardableResult
    public func addSpeakers(_ layout: RAVESpeakerLayout, feed: RAVEChannelFeed, distance: Float = 2) throws -> [RAVESpeaker] {
        precondition(feed.channelCount >= layout.channelCount, "feed has fewer channels than the layout")
        for speaker in layout.speakers {
            // The feed builds the handler in a nonisolated context; see `addSource`.
            try addSource(id: speaker.channel, kind: speaker.isLFE ? .bed : .positioned,
                          render: feed.renderHandler(channel: speaker.channel))
            if let position = speaker.position(distance: distance) {
                setPosition(of: speaker.channel, to: position)
            }
        }
        return layout.speakers
    }

    /// Moves a positioned source (listener coordinates, metres).
    public func setPosition(of id: Int, to position: SIMD3<Float>) {
        guard let object = sources[id]?.object else { return }
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(position, 1)
        object.transform = transform
    }

    public func setHeadTracking(_ on: Bool) {
        recenterTask?.cancel()
        listener.automaticHeadTrackingFlags = on ? [.orientation] : []
    }

    public var headTracking: Bool { listener.automaticHeadTrackingFlags.contains(.orientation) }

    /// Makes the way the wearer faces now the front. The system's tracking
    /// has no recenter call (PHASE, AVAudioEnvironmentNode and
    /// AUSpatialMixer all expose only on/off), so this turns it off and on
    /// again, which starts it from the current head pose.
    public func recenter() {
        guard headTracking else { return }
        listener.automaticHeadTrackingFlags = []
        recenterTask?.cancel()
        recenterTask = Task { @MainActor [weak self] in
            // Long enough that PHASE sees tracking go off, not a no-op pair.
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled else { return }
            self.listener.automaticHeadTrackingFlags = [.orientation]
        }
    }

    public func setReverbPreset(_ preset: RAVEReverbPreset) {
        guard preset != reverbPreset else { return }
        reverbPreset = preset
        engine.defaultReverbPreset = preset.phase
    }

    /// Linear 0…1; applied live through the send meta-parameter.
    public func setReverbSend(_ send: Double) {
        let clamped = min(max(send, 0), 1)
        guard abs(clamped - reverbSend) > 0.0001 else { return }
        reverbSend = clamped
        for source in sources.values where source.kind == .positioned {
            // A short fade, so stepping it in settings doesn't click.
            (source.event?.metaParameters[Self.sendParameterID] as? PHASENumberMetaParameter)?
                .fade(value: clamped, duration: 0.15)
        }
    }

    enum StageError: LocalizedError {
        case noStreamNode
        var errorDescription: String? { "PHASE sound event has no pull stream node" }
    }
}
