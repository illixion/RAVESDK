/*
 Hypnos - the film player's sound stage

 A `RealityView` with one entity per Atmos element. Objects carry a
 `SpatialAudioComponent` and move along their position track; the LFE bed
 has no position, so it plays head-locked through a `ChannelAudioComponent`.
 Each entity's audio is an `AudioGeneratorController` reading
 `AtmosObjectAudio`. The view draws nothing; it only decides where the
 listener is.

 The room: each object's send to the system's acoustics is
 `FilmPlayer.systemReverbDB`. With `roomSource == .virtual` that send is
 off and `FilmRoomReverb`'s four outputs play as four more dry sources
 around the listener (see that file for why a window needs this).

 - visionOS: the view fills the player window, whose origin is the
   window's centre with +z toward the viewer, and the listener is the
   wearer's head. The room is centred `listenerDistance` in front of the
   window, so it moves with the window and the screen is its front wall.
   A window can't see the head, so that distance is a guess. A window
   pushed away grows to keep its angular size, and a `RealityView`'s
   metres grow with it (`WorldScalingCompensation`), so the room is
   scaled back by that factor to stay a real room: its sizes are the
   wearer's metres at any window distance. `.automatic` reads the same
   factor as how much further away the window is than at its natural
   size, and moves the listener with it.
 - visionOS, in an immersive space (`roomPose`): the app knows where the
   head and the screen are, so it hands the room's pose in the space's
   coordinates (listener at the origin, −z toward the screen) and the
   stage sets it in scene space, whatever the view's own origin.
 - iOS and macOS: a virtual camera. A `PerspectiveCamera` at the origin is
   the active camera and so the audio listener, with the room centred on
   it; `listenerOrientation` turns it (head tracking lives in the app). An
   explicit `audioListener` entity hung the main thread in RealityKit's
   listener-transform SVD on iOS, so it isn't used.

 An audio session interruption (another app taking the session; YouTube
 did, visionOS 2026-10-10) leaves RealityKit's generators silent for good:
 the transport kept running and seeking changed nothing. As in
 `FilmPhaseStageView`, the film pauses when one begins and the generators
 are rebuilt when it ends, on a media services reset, and on the next play
 while still interrupted (an app that takes the session needn't ever say it
 is done with it). `AtmosObjectAudio`'s host-time anchoring lines the new
 generators up again.

 Moved from the app's Atmos spike (AtmosSpikeStageView).
 */

import DebugLog
import AudioToolbox
import AVFAudio
import os
import RealityKit
import SwiftUI

/// visionOS: how far in front of the film window the listener is assumed
/// to sit, in the wearer's real metres.
public enum FilmListenerDistance: Equatable, Sendable {
    /// Always this far.
    case fixed(Float)
    /// `atNaturalSize` metres while the window is at its natural size, and
    /// further in proportion as the window's dynamic scale grows (a window
    /// keeps its angular size, so its scale follows its distance).
    case automatic(atNaturalSize: Float = 1.5)

    /// Real metres from the window to the listener at `windowScale`.
    public func metres(windowScale: Float) -> Float {
        switch self {
        case .fixed(let metres): metres
        case .automatic(let atNaturalSize): atNaturalSize * windowScale
        }
    }
}

// Synchronization.Atomic; the package floor stays at macOS 14.
/// The stage's logic and entities, apart from any view: what `FilmStageView` draws in a window,
/// and what a host mounts under its own entity when the room lives in a shared immersive space
/// (Nexus), where a `RealityView` of its own can't go. Call `start()` once the room is in a scene
/// and `stop()` when it leaves; `stop()` takes the generators down too.
@available(macOS 15.0, *)
@MainActor
public final class FilmStage {
    /// The room: one entity per Atmos element, positioned in the listener's frame. Put it in
    /// the scene (a `RealityView`'s content, or under a host's root) before `start()`.
    public let room = Entity()
    let player: FilmPlayer
    /// visionOS: where the listener sits in front of the window.
    var placement: FilmListenerDistance
    /// visionOS, in an immersive space: the room's pose in scene space, read every tick; nil
    /// keeps the last one. Replaces `placement`.
    var roomPose: (@MainActor () -> simd_float4x4?)?
    /// visionOS window: real metres per `RealityView` metre.
    var windowScale: Float = 1
    /// iOS/macOS: the listener's head orientation, read every tick.
    var listenerOrientation: @MainActor () -> simd_quatf
    #if !os(visionOS)
    public let listener = PerspectiveCamera()
    #endif

    private var entities: [Int: Entity] = [:]
    private var roomEntities: [Entity] = []
    private var controllers: [AudioGeneratorController] = []
    private var appliedReverb: Float?
    private var builtFor: ObjectIdentifier?
    private var tickTask: Task<Void, Never>?
    /// An interruption began and the generators haven't been rebuilt since.
    private var interrupted = false
    private var observers: [NSObjectProtocol] = []

    private let logger = DebugLogger(subsystem: "com.illixion.hypnos", category: "FilmStage")

    init(player: FilmPlayer, placement: FilmListenerDistance = .automatic(),
         roomPose: (@MainActor () -> simd_float4x4?)? = nil,
         listenerOrientation: @escaping @MainActor () -> simd_quatf = { simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }) {
        self.player = player
        self.placement = placement
        self.roomPose = roomPose
        self.listenerOrientation = listenerOrientation
        #if !os(visionOS)
        listener.name = "film-listener"
        #endif
    }

    #if os(visionOS)
    /// A stage in an immersive space, its room placed by `roomPose`.
    public convenience init(player: FilmPlayer, roomPose: @escaping @MainActor () -> simd_float4x4?) {
        self.init(player: player, placement: .automatic(), roomPose: roomPose)
    }
    #endif

    public func start() {
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        #if !os(macOS)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                // Plain integers cross to the main actor; the notification itself doesn't.
                let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                MainActor.assumeIsolated { self?.handleInterruption(type: type, options: options) }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.logger.info("Media services reset; rebuilding the generators")
                    self?.teardown()
                }
            },
        ]
        #endif
    }

    public func stop() {
        tickTask?.cancel()
        tickTask = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        teardown()
    }

    #if !os(macOS)
    private func handleInterruption(type raw: UInt?, options rawOptions: UInt?) {
        guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            logger.info("Audio session interrupted; pausing")
            interrupted = true
            player.pause()
        case .ended:
            let options = rawOptions.map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            logger.info("Interruption ended (resume: \(options.contains(.shouldResume))); rebuilding the generators")
            recoverFromInterruption()
            if options.contains(.shouldResume) { player.play() }
        @unknown default:
            break
        }
    }

    private func recoverFromInterruption() {
        interrupted = false
        try? AVAudioSession.sharedInstance().setActive(true)
        // The next tick builds fresh generators for the same audio.
        teardown()
    }
    #endif

    private func teardown() {
        for controller in controllers { controller.stop() }
        controllers.removeAll()
        room.children.removeAll()
        entities.removeAll()
        roomEntities.removeAll()
        builtFor = nil
    }

    /// (Re)builds the generators when the player's audio changes (a new film).
    private func buildIfNeeded() {
        let current = player.audio.map(ObjectIdentifier.init)
        guard current != builtFor else { return }
        teardown()
        builtFor = current
        guard let audio = player.audio else { return }
        for element in player.elements {
            let entity = Entity()
            entity.name = "atmos-\(element.id)"
            if element.isBed {
                entity.components.set(ChannelAudioComponent())
            } else {
                entity.components.set(SpatialAudioComponent(
                    gain: 0,
                    directLevel: 0,
                    reverbLevel: Audio.Decibel(player.systemReverbDB),
                    directivity: .beam(focus: 0),
                    distanceAttenuation: .rolloff(factor: 0)
                ))
                entity.position = player.listenerPosition(of: element, frame: player.currentFrame)
            }
            room.addChild(entity)
            entities[element.channel] = entity
            do {
                // The handler must not be a closure literal here — see
                // `AtmosObjectAudio.renderHandler(channel:)`.
                let controller = try entity.prepareAudio(
                    configuration: AudioGeneratorConfiguration(layoutTag: kAudioChannelLayoutTag_Mono, mixGroupName: nil),
                    audio.renderHandler(channel: element.channel)
                )
                controllers.append(controller)
            } catch {
                logger.error("Generator for element \(element.id) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let reverb = player.roomReverb {
            for output in 0 ..< FilmRoomReverb.outputCount {
                let entity = Entity()
                entity.name = "film-room-\(output)"
                // Already the room's sound: no second room on top of it.
                entity.components.set(SpatialAudioComponent(
                    gain: 0,
                    directLevel: 0,
                    reverbLevel: -120,
                    directivity: .beam(focus: 0),
                    distanceAttenuation: .rolloff(factor: 0)
                ))
                entity.position = player.listenerPosition(ofRoomPoint: FilmRoomReverb.outputPositions[output])
                room.addChild(entity)
                roomEntities.append(entity)
                do {
                    let controller = try entity.prepareAudio(
                        configuration: AudioGeneratorConfiguration(layoutTag: kAudioChannelLayoutTag_Mono, mixGroupName: nil),
                        reverb.renderHandler(output: output)
                    )
                    controllers.append(controller)
                } catch {
                    logger.error("Room output \(output) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        appliedReverb = player.systemReverbDB
        // Start every generator in the same turn; they emit silence until the transport plays.
        for controller in controllers { controller.play() }
        logger.info("Built \(controllers.count) generators for \(player.elements.count) elements")
    }

    private func tick() {
        #if !os(macOS)
        if interrupted, player.isPlaying {
            logger.info("Playing after an interruption that never ended; rebuilding the generators")
            recoverFromInterruption()
        }
        #endif
        buildIfNeeded()
        player.tick()
        #if os(visionOS)
        if let roomPose {
            if let pose = roomPose() { room.setTransformMatrix(pose, relativeTo: nil) }
        } else {
            // The room in real metres, its centre the listener's real distance away.
            room.scale = SIMD3(repeating: 1 / windowScale)
            room.position = SIMD3(0, 0, placement.metres(windowScale: windowScale) / windowScale)
        }
        #else
        listener.orientation = listenerOrientation()
        #endif
        let frame = player.currentFrame
        for element in player.elements where !element.isBed {
            entities[element.channel]?.position = player.listenerPosition(of: element, frame: frame)
        }
        for (output, entity) in roomEntities.enumerated() {
            entity.position = player.listenerPosition(ofRoomPoint: FilmRoomReverb.outputPositions[output])
        }
        let send = player.systemReverbDB
        if appliedReverb != send {
            appliedReverb = send
            for element in player.elements where !element.isBed {
                guard let entity = entities[element.channel],
                      var spatial = entity.components[SpatialAudioComponent.self] else { continue }
                spatial.reverbLevel = Audio.Decibel(send)
                entity.components.set(spatial)
            }
        }
    }
}

@available(macOS 15.0, *)
public struct FilmStageView: View {
    @State private var stage: FilmStage
    /// visionOS: where the listener sits in front of the window.
    var listenerDistance: FilmListenerDistance
    /// visionOS: called with the window's dynamic scale (real metres per
    /// `RealityView` metre) whenever it changes.
    var onWindowScale: (@MainActor (Float) -> Void)?
    #if os(visionOS)
    @Environment(\.physicalMetrics) private var metrics
    #endif

    public init(player: FilmPlayer, listenerDistance: FilmListenerDistance = .automatic(),
                listenerOrientation: @escaping @MainActor () -> simd_quatf = { simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) },
                onWindowScale: (@MainActor (Float) -> Void)? = nil) {
        _stage = State(initialValue: FilmStage(player: player, placement: listenerDistance, listenerOrientation: listenerOrientation))
        self.listenerDistance = listenerDistance
        self.onWindowScale = onWindowScale
    }

    #if os(visionOS)
    /// A stage in an immersive space, its room placed by `roomPose`.
    public init(player: FilmPlayer, roomPose: @escaping @MainActor () -> simd_float4x4?) {
        _stage = State(initialValue: FilmStage(player: player, roomPose: roomPose))
        self.listenerDistance = .automatic()
        self.onWindowScale = nil
    }
    #endif

    public var body: some View {
        RealityView { content in
            #if !os(visionOS)
            content.camera = .virtual
            content.add(stage.listener)
            #endif
            content.add(stage.room)
        }
        .onAppear { stage.start() }
        .onDisappear { stage.stop() }
        #if os(visionOS)
        .onChange(of: listenerDistance, initial: true) { stage.placement = listenerDistance }
        .onChange(of: metrics, initial: true) {
            let scaled = metrics.worldScalingCompensation(.scaled).convert(CGFloat(1000), to: .meters)
            let unscaled = metrics.worldScalingCompensation(.unscaled).convert(CGFloat(1000), to: .meters)
            guard scaled > 0, unscaled > 0 else { return }
            let scale = min(max(Float(unscaled / scaled), 0.1), 50)
            stage.windowScale = scale
            onWindowScale?(scale)
        }
        #endif
    }
}
