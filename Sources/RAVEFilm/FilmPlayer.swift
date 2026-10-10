/*
 Hypnos - film player: picture and Atmos object audio on one clock

 Owns the transport. Every start, whether after a seek or a pause, is
 scheduled rather than immediate:

 1. The picture is parked at the film time T and primed (the frame at T
    queued), and the audio streamer fetches the segment holding T's frame.
 2. Once both are ready, one host time H a moment ahead is chosen.
 3. The audio is told "scene frame F(T) renders at H", and the picture
    "film time T is due at H + output latency + avOffset", since the audio
    rendered at H is heard that much later.

 Film time is the container's clock, which both halves share: the video
 segments are stamped in it and the scene's `startSeconds` places audio
 frame 0 on it. Both halves then run from the host clock, so once started
 they cannot drift apart.

 Items without Atmos objects (the plugin answers 422) play picture only.
 */

import DebugTrace
import CoreMedia
import Foundation
import Observation
import os
// Re-exported: `reverbPreset` is part of this API, so a client of RAVEFilm
// shouldn't have to link the stage's product to set it.
@_exported import RAVESpatialAudio
import simd

@MainActor
// Synchronization.Atomic; the package floor stays at macOS 14.
@available(macOS 15.0, *)
@Observable
public final class FilmPlayer {
    public let video = FilmVideoPlayer()
    public private(set) var scene: AtmosScene?
    @ObservationIgnored public private(set) var audio: AtmosObjectAudio?
    /// The room `FilmStageView` plays when `roomSource` is `.virtual`; made with the audio.
    @ObservationIgnored public private(set) var roomReverb: FilmRoomReverb?
    @ObservationIgnored public private(set) var streamer: AtmosSegmentStreamer?
    public private(set) var isPlaying = false
    public private(set) var status = "Idle"
    public private(set) var audioStatus = "—"
    /// How the object audio is being fetched right now, for a menu:
    /// "Lossless", "AAC 64 kbps", "Auto · AAC 64 kbps". Empty when the sound
    /// isn't from the plugin.
    public private(set) var audioQuality = ""
    /// The item's object-audio tracks (empty from an older plugin, or with one).
    public private(set) var audioTracks: [FilmAudioTrack] = []
    /// The track playing; see `selectAudioTrack(_:)`.
    public private(set) var audioStream: Int?
    @ObservationIgnored private var client: (any FilmAudioSource)?

    // Tuning, read by the stage every tick.
    /// Mute is independent of saved gain tuning and keeps the clock running.
    public var isMuted = false { didSet { tick() } }
    /// Listening volume, 0…1, on top of the saved gain tuning (which is the
    /// mix, not how loud the viewer wants it).
    public var volume: Float = 1 { didSet { tick() } }
    public var masterGainDB: Float = 0
    public var lfeGainDB: Float = 0
    public var reverbDB: Float = 0
    /// The room's reverb character: PHASE's on tvOS, and on a RealityKit
    /// stage `FilmRoomReverb`'s while `roomSource` is `.virtual`.
    public var reverbPreset: RAVEReverbPreset = .mediumRoom
    /// RealityKit stages: the system's room acoustics (on visionOS, the
    /// wearer's real room) or `FilmRoomReverb`. PHASE ignores it.
    public var roomSource: FilmRoomSource = .system
    public var roomHalfWidth: Float = 2.0
    public var roomHalfDepth: Float = 2.5
    public var roomHeight: Float = 1.6
    public var flattenHeights = false
    /// Extra picture delay on top of the route's reported latency, in ms.
    /// Positive shows the picture later. RealityKit's own processing isn't
    /// reported anywhere, so this is set by eye and ear.
    public var avOffsetMs: Double = 0 {
        didSet { if isPlaying { resume() } }
    }
    /// Output latency of the current route, as the platform reports it.
    public private(set) var outputLatency: Double = 0
    /// How far ahead a start is scheduled, so both halves are ready when it comes.
    public var startLead: Double = 0.25

    // Telemetry
    public private(set) var levels: [Float] = []
    public private(set) var measuredRate: Double = 0
    public private(set) var clockReport = "—"

    private let logger = DebugLogger(subsystem: "com.illixion.hypnos", category: "FilmPlayer")
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var lastState: [Int: (pos: SIMD3<Float>, gainDB: Float)] = [:]
    @ObservationIgnored private var rateSample: (frames: Int, time: ContinuousClock.Instant)?
    @ObservationIgnored private var lastTelemetry = ContinuousClock.now

    public init() {
        // A lost picture decoder restarts at the playhead with the audio
        // re-anchored, the same as any seek (see FilmVideoPlayer).
        video.onDecodingInterrupted = { [weak self] in
            guard let self else { return }
            self.seek(to: self.currentTime)
        }
    }

    public var elements: [AtmosScene.Element] { scene?.elements ?? [] }
    /// Film time of the picture.
    public var currentTime: Double { video.currentTime }
    public var duration: Double { video.duration }

    // MARK: Loading

    /// Loads the item `client` names: its Atmos scene, and its picture from
    /// the plugin's video segments (at `pictureHeight`, a lower tier, when
    /// the plugin offers it) or, when given, from `picture`.
    public func load(_ client: FilmServerClient, picture: FilmPictureSource? = nil, startAt seconds: Double = 0,
                     pictureHeight: Int? = nil) async {
        await load(audio: client, startAt: seconds) { @MainActor [video] in
            if let picture {
                video.load(picture, startAt: seconds)
            } else {
                await video.load(client, startAt: seconds, pictureHeight: pictureHeight)
            }
        }
    }

    /// Loads a film from its picture and, if it has any, its sound.
    public func load(picture: FilmPictureSource, audio: (any FilmAudioSource)?, startAt seconds: Double = 0) async {
        await load(audio: audio, startAt: seconds) { @MainActor [video] in
            video.load(picture, startAt: seconds)
        }
    }

    /// Whether the loaded film has sound playing through the stage.
    public var hasAudioScene: Bool { scene != nil }

    private func load(audio source: (any FilmAudioSource)?, startAt seconds: Double,
                      picture: @escaping @MainActor () async -> Void) async {
        stop()
        status = "Loading…"
        audioStatus = "Loading…"
        audioTracks = []
        audioStream = nil
        self.client = nil
        async let videoLoad: Void = picture()
        var scene: AtmosScene?
        if let source {
            // The default track follows the device's languages.
            let tracks = (try? await source.audioTracks(languages: FilmServerClient.deviceLanguages)) ?? []
            let chosen = tracks.first(where: \.isDefault) ?? tracks.first
            let client = source.with(audioStream: chosen?.index)
            audioTracks = tracks
            audioStream = chosen?.index
            self.client = client
            do {
                scene = try await client.audioScene(startSeconds: seconds)
                audioStatus = scene == nil ? "No object audio; picture only" : "Streaming"
            } catch {
                audioStatus = "Audio unavailable: \(error.localizedDescription)"
                logger.error("\(self.audioStatus, privacy: .public)")
            }
        } else {
            audioStatus = "No sound"
        }
        await videoLoad

        if let scene, let client { install(scene, client: client, at: seconds) }
        status = video.status
    }

    private func install(_ scene: AtmosScene, client: any FilmAudioSource, at seconds: Double) {
        let audio = AtmosObjectAudio(scene: scene)
        let streamer = AtmosSegmentStreamer(audio: audio, client: client, scene: scene)
        streamer.focus(on: frame(for: seconds, in: scene))
        self.scene = scene
        self.audio = audio
        roomReverb = FilmRoomReverb(audio: audio, elements: scene.elements)
        self.streamer = streamer
        levels = Array(repeating: 0, count: scene.elements.count)
        streamTask = Task.detached(priority: .userInitiated) { await streamer.run() }
        logger.info("Atmos: \(scene.elements.count) elements, \(scene.segmentCount) segments, start \(scene.startSeconds)s, stream \(client.audioStream ?? -1)")
    }

    /// Switches the audio to track `index` (from `audioTracks`) at the
    /// current position, keeping the picture. The stages rebuild for the new
    /// audio; playing, the sound resumes once the new track's segment is in.
    public func selectAudioTrack(_ index: Int) async {
        guard index != audioStream, let base = client, audioTracks.contains(where: { $0.index == index }) else { return }
        audioStream = index
        await reloadAudio(with: base.with(audioStream: index), reason: "stream \(index)")
    }

    /// The encoding the playing film's object audio is fetched in, when its
    /// source is the plugin; nil for any other source.
    public var audioEncoding: FilmAudioEncoding? {
        (client as? FilmServerClient).map { client in scene.map(client.effectiveEncoding(for:)) ?? client.encoding }
    }

    /// Fetches the object audio as `encoding` from here on (lossless FLAC or
    /// a compressed bundle), rebuilding the stage at the current position the
    /// way a track change does. With a `governor` ("Auto") it picks the
    /// encoding of each segment as the link allows, and `encoding` is
    /// where it starts from when the plugin can't serve a compressed one.
    public func setAudioEncoding(_ encoding: FilmAudioEncoding, governor: FilmAudioGovernor? = nil) async {
        guard var server = client as? FilmServerClient,
              server.encoding != encoding || server.governor !== governor else { return }
        server.encoding = encoding
        server.governor = governor
        await reloadAudio(with: server, reason: governor == nil ? "encoding \(encoding)" : "encoding auto")
    }

    private func reloadAudio(with client: any FilmAudioSource, reason: String) async {
        let index = client.audioStream
        let position = currentTime
        startTask?.cancel()
        streamTask?.cancel()
        streamTask = nil
        audio?.pause()
        audio = nil
        roomReverb = nil
        streamer = nil
        scene = nil
        lastState = [:]
        self.client = client
        audioStatus = "Loading…"
        logger.info("Audio → \(reason, privacy: .public) at \(position, format: .fixed(precision: 2))s")
        let scene: AtmosScene?
        do {
            scene = try await client.audioScene(startSeconds: position)
            audioStatus = scene == nil ? "No Atmos objects; picture only" : "Streaming"
        } catch {
            scene = nil
            audioStatus = "Audio unavailable: \(error.localizedDescription)"
            logger.error("\(self.audioStatus, privacy: .public)")
        }
        // A newer choice (or another film) took over while this one loaded.
        guard self.client?.itemID == client.itemID, audioStream == index, Self.sameEncoding(self.client, client), let scene else { return }
        install(scene, client: client, at: currentTime)
        schedule(at: currentTime, seekVideo: false)
    }

    private static func sameEncoding(_ a: (any FilmAudioSource)?, _ b: any FilmAudioSource) -> Bool {
        let a = a as? FilmServerClient, b = b as? FilmServerClient
        return a?.encoding == b?.encoding && a?.governor === b?.governor
    }

    // MARK: Transport

    public func play() {
        guard !isPlaying, video.isLoaded else { return }
        isPlaying = true
        schedule(at: currentTime, seekVideo: false)
    }

    public func pause() {
        startTask?.cancel()
        isPlaying = false
        audio?.pause()
        video.pause()
    }

    public func seek(to seconds: Double) {
        let target = min(max(0, seconds), max(0, duration - 0.5))
        // Every position change goes through here, so a playhead that jumps
        // somewhere unexpected leaves a line naming where it came from.
        logger.info("Seek \(self.currentTime, format: .fixed(precision: 2))s → \(target, format: .fixed(precision: 2))s")
        schedule(at: target, seekVideo: true)
    }

    public func stop() {
        startTask?.cancel()
        streamTask?.cancel()
        streamTask = nil
        audio?.pause()
        video.stop()
        audio = nil
        roomReverb = nil
        streamer = nil
        scene = nil
        lastState = [:]
        isPlaying = false
        client = nil
    }

    /// Re-anchors both halves at the current position, e.g. after an offset change.
    private func resume() {
        schedule(at: currentTime, seekVideo: false)
    }

    private func schedule(at filmTime: Double, seekVideo: Bool) {
        startTask?.cancel()
        audio?.pause()
        if seekVideo {
            video.seek(to: filmTime, resume: false)
        } else {
            video.pause()
        }
        guard let audio, let streamer, let scene else {
            if isPlaying { video.play() }
            return
        }
        let frame = frame(for: filmTime, in: scene)
        streamer.focus(on: frame)
        audio.playhead.store(frame, ordering: .relaxed)
        guard isPlaying else { return }

        startTask = Task { [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now + .seconds(15)
            let segment = frame / audio.segmentFrames
            while !Task.isCancelled, ContinuousClock.now < deadline,
                  !(self.video.isPrimed && audio.isResident(segment)) {
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard !Task.isCancelled else { return }
            if !audio.isResident(segment) { self.logger.error("Audio segment \(segment) not ready; starting anyway") }
            self.outputLatency = AudioOutputLatency.current()
            let host = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(seconds: self.startLead, preferredTimescale: 1_000_000_000)
            // Before the audio track's first frame (a film starting at 0 whose
            // audio begins 2 s in), frame 0 is due when the picture gets there,
            // not now; renders before the anchor are silent.
            let audioLead = max(0, scene.startSeconds - filmTime)
            audio.start(at: frame, anchorHostTime: Self.machTicks(host + CMTime(seconds: audioLead, preferredTimescale: 1_000_000_000)))
            let pictureDelay = self.outputLatency + self.avOffsetMs / 1000
            self.video.start(filmTime: filmTime, atHostTime: host + CMTime(seconds: pictureDelay, preferredTimescale: 1_000_000_000))
            self.rateSample = nil
            self.logger.info("Started at \(filmTime, format: .fixed(precision: 3))s (frame \(frame)), picture +\(pictureDelay * 1000, format: .fixed(precision: 0)) ms")
        }
    }

    private func frame(for filmTime: Double, in scene: AtmosScene) -> Int {
        max(0, Int(((filmTime - scene.startSeconds) * Double(scene.sampleRate)).rounded()))
    }

    private static func machTicks(_ time: CMTime) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return UInt64(time.seconds * 1e9 * Double(info.denom) / Double(info.numer))
    }

    // MARK: Per-frame work (called by the stage)

    /// Current audio render frame (one buffer ahead of what is heard).
    public var currentFrame: Int { audio?.playhead.load(ordering: .relaxed) ?? 0 }

    /// An element's DAMF position and gain at `frame`, from the streamed
    /// segment holding it; a segment not yet fetched keeps the last state.
    public func state(of element: AtmosScene.Element, frame: Int) -> (pos: SIMD3<Float>, gainDB: Float) {
        if let audio, let streamer,
           let track = streamer.track(segment: frame / audio.segmentFrames, element: element.id) {
            let state = track.state(at: frame)
            lastState[element.id] = state
            return state
        }
        return lastState[element.id] ?? (SIMD3(0, 1, 0), -144)
    }

    /// Position relative to the listener's ears in metres: −z forward
    /// (toward the screen), +y up.
    public func listenerPosition(of element: AtmosScene.Element, frame: Int) -> SIMD3<Float> {
        listenerPosition(ofRoomPoint: state(of: element, frame: frame).pos)
    }

    /// A DAMF room position (x right, y front, z up, each −1…1) in the
    /// listener's metres, as `listenerPosition(of:frame:)` places elements.
    public func listenerPosition(ofRoomPoint p: SIMD3<Float>) -> SIMD3<Float> {
        let z = flattenHeights ? 0 : max(0, min(p.z, 1))
        var local = SIMD3<Float>(p.x * roomHalfWidth, z * roomHeight, -p.y * roomHalfDepth)
        // A source at the listener's head has no direction; keep a minimum radius.
        let minRadius: Float = 0.6
        let length = simd_length(local)
        if length < minRadius {
            local = length > 0.001 ? local / length * minRadius : SIMD3(0, minRadius, 0)
        }
        return local
    }

    /// What a RealityKit stage sends each object to the system's room:
    /// `reverbDB`, or nothing while `FilmRoomReverb` is the room.
    public var systemReverbDB: Float { roomSource == .virtual ? -120 : reverbDB }

    /// `FilmRoomReverb`'s output gain: off unless it is the room, and off at
    /// the bottom of `reverbDB`'s range (−40 dB), as the system send is.
    public var roomReverbGain: Float {
        guard roomSource == .virtual, reverbPreset != .none, reverbDB > -40 else { return 0 }
        return powf(10, reverbDB / 20)
    }

    /// Pushes gains to the render side and refreshes telemetry. Called ~60 Hz.
    public func tick() {
        guard let audio, let scene else { return }
        if let roomReverb {
            // No tank unless it is heard (PHASE stages tick too).
            roomReverb.setRoom(roomSource == .virtual ? reverbPreset : .none)
            roomReverb.setLevel(roomReverbGain)
        }
        let frame = currentFrame
        for element in scene.elements {
            let db = masterGainDB + state(of: element, frame: frame).gainDB + (element.isBed ? lfeGainDB : 0)
            audio.targetGain[element.channel] = isMuted || db <= -120 ? 0 : powf(10, db / 20) * max(0, min(1, volume))
            let peak = audio.peak[element.channel]
            audio.peak[element.channel] = 0
            levels[element.channel] = max(peak, levels[element.channel] * 0.85)
        }

        let now = ContinuousClock.now
        guard now - lastTelemetry > .milliseconds(250) else { return }
        lastTelemetry = now
        if let server = client as? FilmServerClient {
            let quality = server.qualitySummary(for: scene)
            if quality != audioQuality { audioQuality = quality }
        }
        let rendered = audio.renderedFrames.load(ordering: .relaxed)
        if isPlaying, let sample = rateSample {
            let seconds = Double((now - sample.time).components.attoseconds) / 1e18 + Double((now - sample.time).components.seconds)
            if seconds > 2 {
                measuredRate = Double(rendered - sample.frames) / seconds
                rateSample = (rendered, now)
            }
        } else if isPlaying {
            rateSample = (rendered, now)
        }
        let drift = audio.alignment.maxDrift
        let resident = audio.slots.map { $0.segment.load(ordering: .relaxed) }.filter { $0 >= 0 }.sorted()
        clockReport = String(format: "%.0f Hz, max drift %d frames, %d re-anchors, segments %@, %d underrun buffers",
                             measuredRate, drift, audio.alignment.reanchors,
                             resident.map(String.init).joined(separator: ","),
                             audio.underruns.load(ordering: .relaxed))
        if let streamer {
            let dropped = streamer.droppedChannels.load(ordering: .relaxed)
            let omitted = streamer.omittedChannels.load(ordering: .relaxed)
            clockReport += String(format: ", last segment %d ms", streamer.lastLoadMilliseconds.load(ordering: .relaxed))
                + ", \(audioQuality)" + ((client as? FilmServerClient)?.governor?.measuredRate.map { String(format: " (link %.1f Mbps)", $0 / 1e6) } ?? "")
                + ", \(streamer.prefetched.load(ordering: .relaxed)) fetched ahead"
                + (dropped > 0 ? ", \(dropped) channel(s) dropped for time" : "")
                + (omitted > 0 ? ", \(omitted) left out for the link" : "")
        }
    }

    /// Audio position minus picture position, in ms, as each is currently
    /// scheduled to be perceived. Zero means in sync (given the offsets).
    public var scheduledSkewMs: Double? {
        guard let audio, let scene, isPlaying, audio.playing.load(ordering: .relaxed) else { return nil }
        let audioTime = scene.startSeconds + Double(audio.playhead.load(ordering: .relaxed)) / audio.sampleRate
        return (audioTime - outputLatency - avOffsetMs / 1000 - currentTime) * 1000
    }
}
