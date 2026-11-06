/*
 RAVE SDK — keep the wearer's other apps visible beside an open immersive space.

 An open immersive space normally hides every other app's windows (their audio
 keeps playing). Measured on visionOS 27.2 (2026-11-05, spatial-ai-character,
 then Longwave's foveated PCVR space): opening any window of the app *after* the
 space is open brings the other apps back, usable, while the space keeps running
 (world and hand tracking live, depth between the space's content and other
 windows correct), and that survives closing the window again. Other apps keep
 running too, so a long job in one of them carries on beside the space.

 So `trigger()` flashes a small window open and shut once the space has settled.
 There is no API for this; it is an OS behaviour a later visionOS may drop, and
 then the setting simply stops doing anything. Only windows come back, not a
 second app's immersive content.

 Home and notifications close the space outright (scene gone), which ends it;
 the trigger runs again the next time the space turns active. Reopening the
 space is the app's business (`onSpaceClosed`).

 Wiring:

     // App
     let appsBeside = RAVEAppsBesideSpace(windowID: "appsBeside", defaultsKey: "appsBeside.keepVisible")
     var body: some Scene {
         ...
         ImmersiveSpace(id: "space") { MySpaceView().appsBesideSpace(appsBeside) }
         RAVEAppsBesideTriggerWindow(appsBeside)
     }

 The modifier hands the controller the space's own window actions, its scene
 phase and its disappearance. An app that already tracks those can call
 `spacePhaseChanged(_:)` and `spaceClosed()` itself and set `openWindow` and
 `dismissWindow` from inside the space instead.
 */

#if os(visionOS)

import SwiftUI

@MainActor
@Observable
public final class RAVEAppsBesideSpace {

    /// The trigger window's scene id (`RAVEAppsBesideTriggerWindow` uses it).
    public let windowID: String

    /// Show other apps' windows beside the open space. Persisted under
    /// `defaultsKey` when one was given.
    public var keepAppsVisible: Bool {
        didSet {
            if let defaultsKey { UserDefaults.standard.set(keepAppsVisible, forKey: defaultsKey) }
            if keepAppsVisible, !isPaused, spaceActive, !applied { triggerSoon() }
        }
    }

    /// Holds the trigger off for a while without touching the saved setting:
    /// spatial-ai-character pauses it while a gaze session's approval prompt
    /// is up, because other apps showing then kill the session. Turning the
    /// setting itself off for that was saved to disk, and an app quit or a
    /// reboot mid-connect left it off for good. Never persisted.
    public var isPaused = false {
        didSet {
            if !isPaused, keepAppsVisible, spaceActive, !applied { triggerSoon() }
        }
    }

    /// False while something else owns the space (a host process, say), so
    /// the trigger stays out of it.
    @ObservationIgnored public var isAvailable: @MainActor () -> Bool = { true }

    /// Runs once each time a space that had been active closes, for whatever
    /// reason. The app decides what a close means (its own, or visionOS
    /// taking the space away) and whether to reopen it.
    @ObservationIgnored public var onSpaceClosed: (@MainActor () -> Void)?

    /// Each event as it happens (trigger, closed), for the app's own log.
    @ObservationIgnored public var onEvent: (@MainActor (String) -> Void)?

    /// The space's own window actions. A window opened through them, from
    /// inside the space, is what lets the other apps show.
    @ObservationIgnored public var openWindow: OpenWindowAction?
    @ObservationIgnored public var dismissWindow: DismissWindowAction?

    public private(set) var spaceActive = false
    /// The trigger ran for this opening of the space.
    public private(set) var applied = false

    /// How long after the space turns active the trigger waits. Fired at once
    /// the window opened and closed but the other apps stayed hidden, while
    /// visionOS was still bringing the space in; seconds later it worked
    /// (headset, 2026-11-05).
    public let settleDelay: Duration

    @ObservationIgnored private let defaultsKey: String?
    @ObservationIgnored private var spaceWasUp = false
    @ObservationIgnored private var pendingTrigger: Task<Void, Never>?
    @ObservationIgnored private var counts: [String: Int] = [:]
    @ObservationIgnored private var lastEvent = ""

    /// - Parameter defaultValue: `keepAppsVisible` until the wearer sets it.
    public init(windowID: String, defaultsKey: String? = nil, defaultValue: Bool = false,
                settleDelay: Duration = .milliseconds(1500)) {
        self.windowID = windowID
        self.defaultsKey = defaultsKey
        self.settleDelay = settleDelay
        keepAppsVisible = defaultsKey.flatMap { UserDefaults.standard.object(forKey: $0) as? Bool } ?? defaultValue
    }

    // MARK: - Space lifecycle

    /// The space's scene phase changed.
    public func spacePhaseChanged(_ phase: ScenePhase) {
        spaceActive = phase == .active
        guard spaceActive else { return }
        spaceWasUp = true
        if keepAppsVisible, !isPaused, !applied { triggerSoon() }
    }

    /// The space closed. Safe to call more than once per close: only the
    /// first call after the space was active reaches `onSpaceClosed`.
    public func spaceClosed() {
        pendingTrigger?.cancel()
        spaceActive = false
        applied = false
        guard spaceWasUp else { return }
        spaceWasUp = false
        note("closed")
        onSpaceClosed?()
    }

    // MARK: - The trigger

    private func triggerSoon() {
        pendingTrigger?.cancel()
        pendingTrigger = Task { [weak self] in
            guard let delay = self?.settleDelay else { return }
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.spaceActive, self.keepAppsVisible, !self.isPaused,
                  !self.applied else { return }
            self.trigger()
        }
    }

    /// Opens the trigger window now; it closes itself once it is up.
    public func trigger() {
        guard isAvailable(), let openWindow else { return }
        applied = true
        note("trigger")
        openWindow(id: windowID)
    }

    /// The trigger window is on screen: the other apps are back. Close it.
    func triggerWindowAppeared() {
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            dismissWindow?(id: windowID)
        }
    }

    // MARK: - Report

    private func note(_ event: String) {
        counts[event, default: 0] += 1
        lastEvent = event
        onEvent?(event)
    }

    /// State and event counts, for a debug endpoint.
    public func report() -> [String: Any] {
        ["keepAppsVisible": keepAppsVisible, "paused": isPaused, "spaceActive": spaceActive, "applied": applied,
         "available": isAvailable(), "events": counts, "lastEvent": lastEvent]
    }
}

/// The window `RAVEAppsBesideSpace.trigger()` flashes open: small, near the
/// wearer, gone in a moment. Never opens at launch or on restore.
public struct RAVEAppsBesideTriggerWindow: Scene {
    let controller: RAVEAppsBesideSpace
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    public init(_ controller: RAVEAppsBesideSpace,
                title: LocalizedStringKey = "Your Apps",
                message: LocalizedStringKey = "Keeping your apps in view") {
        self.controller = controller
        self.title = title
        self.message = message
    }

    public var body: some Scene {
        Window(title, id: controller.windowID) {
            Label(message, systemImage: "square.on.square")
                .font(.headline)
                .padding(24)
                .onAppear { controller.triggerWindowAppeared() }
        }
        .windowResizability(.contentSize)
        .defaultWindowPlacement { _, _ in WindowPlacement(.utilityPanel) }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

private struct AppsBesideSpaceModifier: ViewModifier {
    let controller: RAVEAppsBesideSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear {
                controller.openWindow = openWindow
                controller.dismissWindow = dismissWindow
            }
            .onChange(of: scenePhase, initial: true) { _, phase in controller.spacePhaseChanged(phase) }
            .onDisappear { controller.spaceClosed() }
    }
}

public extension View {
    /// Put on the immersive space's root view: wires the space to `controller`
    /// (its window actions, scene phase and disappearance).
    func appsBesideSpace(_ controller: RAVEAppsBesideSpace) -> some View {
        modifier(AppsBesideSpaceModifier(controller: controller))
    }
}

#endif
