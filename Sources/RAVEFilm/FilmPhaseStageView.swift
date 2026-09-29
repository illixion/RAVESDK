/*
 Hypnos - the film player's sound stage, through PHASE

 `FilmStageView`'s counterpart for the platforms where the listener's own
 head tracking and personalized spatial audio profile matter more than
 RealityKit's scene: an Apple TV with AirPods or HomePods first. One
 `RAVEPhaseStage` source per Atmos element; objects are positioned and move
 along their tracks, the LFE bed plays head-locked and dry. Each source's
 pull stream reads `AtmosObjectAudio`, whose host-time alignment keeps the
 streams sample-locked even though PHASE gives every stream its own sample
 timeline (as RealityKit's generators do).

 The listener is at the origin facing the screen, so the room is centred
 on it; PHASE turns it with the wearer's head when head tracking is on.
 Room size comes from `FilmPlayer`'s room dimensions, the reverb from its
 `reverbPreset` and `reverbDB`, all read every tick so settings apply live.

 Recentring (the way the wearer faces becomes the screen) happens whenever
 `recenterRequest` changes, which is what a Recenter button bumps, and
 every time playback starts or resumes: someone who paused and turned away
 comes back facing the screen.

 An audio session interruption (another app taking the session: Music did,
 on an AirPods pause press, before the player claimed Now Playing) stops
 PHASE's engine for good. The film pauses when one begins; when it ends,
 or when media services reset, the stage is rebuilt from scratch and the
 film resumes if the system says it should. `AtmosObjectAudio`'s
 host-time anchoring lines the new streams up again.

 A route change does the same: disconnecting AirPods and connecting them
 again left the engine rendering to nothing (tvOS, 2026-09-27). The stage
 is rebuilt on every route change, and the film pauses when the old
 output went away, as Apple's players do.

 The view draws nothing.
 */

import DebugTrace
import AVFAudio
import os
import RAVESpatialAudio
import SwiftUI

// Synchronization.Atomic and PHASE pull streams; the package floor stays at macOS 14.
@available(macOS 15.0, *)
public struct FilmPhaseStageView: View {
    let player: FilmPlayer
    var headTracking: Bool
    var recenterRequest: Int

    @State private var stage: RAVEPhaseStage?
    @State private var wasPlaying = false
    @State private var builtFor: ObjectIdentifier?
    @State private var tickTask: Task<Void, Never>?

    private let logger = DebugLogger(subsystem: "com.illixion.hypnos", category: "FilmPhaseStage")

    public init(player: FilmPlayer, headTracking: Bool = true, recenterRequest: Int = 0) {
        self.player = player
        self.headTracking = headTracking
        self.recenterRequest = recenterRequest
    }

    public var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                tickTask = Task { @MainActor in
                    while !Task.isCancelled {
                        tick()
                        try? await Task.sleep(for: .milliseconds(16))
                    }
                }
            }
            .onDisappear {
                tickTask?.cancel()
                teardown()
            }
            .onChange(of: headTracking) { _, on in stage?.setHeadTracking(on) }
            .onChange(of: recenterRequest) { stage?.recenter() }
            #if !os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
                handleInterruption(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { note in
                handleRouteChange(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)) { _ in
                logger.info("Media services reset; rebuilding the stage")
                teardown()
            }
            #endif
    }

    private func teardown() {
        stage?.stop()
        stage = nil
        builtFor = nil
    }

    #if !os(macOS)
    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        switch reason {
        case .oldDeviceUnavailable:
            logger.info("Output went away; pausing and rebuilding the stage")
            player.pause()
            teardown()
        case .newDeviceAvailable, .override:
            // The route PHASE rendered to may be gone; start clean on the new
            // one. Not on configuration or category changes: starting PHASE
            // can post those itself, which would rebuild in a loop.
            logger.info("Route changed (\(raw)); rebuilding the stage")
            teardown()
        default:
            break
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            logger.info("Audio session interrupted; pausing")
            player.pause()
        case .ended:
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            logger.info("Interruption ended (resume: \(options.contains(.shouldResume))); rebuilding the stage")
            try? AVAudioSession.sharedInstance().setActive(true)
            // The next tick builds a fresh stage for the same audio.
            teardown()
            if options.contains(.shouldResume) { player.play() }
        @unknown default:
            break
        }
    }
    #endif

    /// (Re)builds the stage when the player's audio changes (a new film).
    private func buildIfNeeded() {
        let current = player.audio.map(ObjectIdentifier.init)
        guard current != builtFor else { return }
        teardown()
        builtFor = current
        guard let audio = player.audio else { return }
        let stage = RAVEPhaseStage(sampleRate: audio.sampleRate, binaural: true, headTracking: headTracking,
                                   reverbPreset: player.reverbPreset, reverbSend: Self.send(player.reverbDB))
        let frame = player.currentFrame
        for element in player.elements {
            do {
                // The handler must not be a closure literal here — see
                // `AtmosObjectAudio.renderHandler(channel:)`.
                try stage.addSource(id: element.channel, kind: element.isBed ? .bed : .positioned,
                                    render: audio.renderHandler(channel: element.channel))
                if !element.isBed {
                    stage.setPosition(of: element.channel, to: player.listenerPosition(of: element, frame: frame))
                }
            } catch {
                logger.error("Source for element \(element.id) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            try stage.start()
            if !player.isPlaying { stage.pause() }
            wasPlaying = player.isPlaying
            self.stage = stage
            logger.info("Built PHASE stage for \(player.elements.count) elements")
        } catch {
            logger.error("PHASE stage didn't start: \(error.localizedDescription, privacy: .public)")
            stage.stop()
        }
    }

    private func tick() {
        buildIfNeeded()
        player.tick()
        guard let stage else { return }
        // The engine follows the transport (see `RAVEPhaseStage.pause()`),
        // and each resume recentres.
        if player.isPlaying != wasPlaying {
            if player.isPlaying {
                stage.resume()
                stage.recenter()
            } else {
                stage.pause()
            }
        }
        wasPlaying = player.isPlaying
        let frame = player.currentFrame
        for element in player.elements where !element.isBed {
            stage.setPosition(of: element.channel, to: player.listenerPosition(of: element, frame: frame))
        }
        stage.setReverbPreset(player.reverbPreset)
        stage.setReverbSend(Self.send(player.reverbDB))
    }

    /// `FilmPlayer.reverbDB` (−40…0 dB, −40 = off) as PHASE's linear send.
    static func send(_ db: Float) -> Double {
        db <= -40 ? 0 : Double(powf(10, db / 20))
    }
}
