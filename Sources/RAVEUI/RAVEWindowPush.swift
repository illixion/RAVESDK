/*
 RAVE SDK — pushing a window: open another window in this one's place, and
 bring this one back when that one closes.

 SwiftUI's `pushWindow` (visionOS 2) does this by backgrounding the calling
 scene. It has degraded with each visionOS release, and on visionOS 27 it
 fails outright: the pushed window opens as an ordinary new window and the
 caller stays visible beside it. There is no way to repair it from app code,
 so this replaces it with parts that do work:

 - the pushed window is opened with a plain `openWindow`, sized to match the
   caller through `raveWindowPushPlacement(id:)` (what `pushWindow` did);
 - once the pushed window's root appears, the caller **hides itself in
   place**: its content goes to opacity 0, stops taking input, and its system
   window controls are hidden. On a `.plain`-style window there is then
   nothing left to see. This is the same technique as an app's "Hide All
   Windows" switch, and unlike scene backgrounding it is entirely the app's;
 - when the pushed window goes away — its own Back button, its system close
   button, a recycle from the window manager, or its scene disconnecting for
   any other reason — the caller is shown again exactly where it was, with its
   state intact, because it never left.

 What the host cannot do for you: **ornaments**. An ornament is presented
 apart from the content it hangs off, so the content's opacity does not reach
 it. A window that pushes reads `\.raveIsPushedAway` and passes `.hidden` to
 its ornaments' `visibility:` while it is true. RAVEUI's own ornaments
 (`raveHomeOrnament`) do this already.

 Usage:

     // Scenes — every window that pushes or is pushed hosts the mechanism:
     WindowGroup(id: "main", for: UUID.self) { $id in
         GalleryView().raveWindowPushHost(sceneID: "main", value: id)
     }
     WindowGroup(id: "viewer", for: Photo.self) { $photo in
         ViewerView(photo).raveWindowPushHost(sceneID: "viewer", value: photo)
     }
     .raveWindowPushPlacement(id: "viewer")

     // Views:
     @Environment(\.ravePushWindow) private var pushWindow
     pushWindow(id: "viewer", value: photo)

 The pushed window closes itself with the ordinary `dismissWindow()`. A
 Home button that should bring the caller back *beside* a pushed window that
 keeps running calls `RAVEWindowPushCoordinator.shared.reveal(sceneID:value:)`
 before its `openWindow`.
 Pushes nest: a pushed window may push again, and each close reveals the one
 beneath it.

 Stacking is strict: only
 a visible window pushes (a hidden one's push opens a plain pop-out), a
 stacked window leaves the stack only by closing or by
 `\.raveDetachFromStack`, and `\.raveIsPushedWindow` tells a window which of
 the two it is right now.

 A push that never lands — the value is already open in another window, so
 `openWindow` brought that one forward instead of opening a new one — hides
 nothing: the caller only hides once a new window claims the push, and an
 unclaimed push expires after a few seconds.
 */

#if os(visionOS)

import SwiftUI
import UIKit

// MARK: - Coordinator

/// Which windows are hidden behind which pushed windows.
///
/// Windows are identified by a per-scene token that `raveWindowPushHost`
/// keeps for the scene's lifetime.
@MainActor
@Observable
public final class RAVEWindowPushCoordinator {
    public static let shared = RAVEWindowPushCoordinator()

    /// A push that has been issued but whose window has not appeared yet.
    private struct Pending {
        let id = UUID()
        let source: UUID
        let sceneID: String
        let value: AnyHashable?
        let sourceSize: CGSize?
    }

    @ObservationIgnored private var pending: [Pending] = []

    /// Pushed window → the window it hides.
    private var covers: [UUID: UUID] = [:]

    /// Last known content size of each hosted window, for size matching.
    @ObservationIgnored private var sizes: [UUID: CGSize] = [:]

    @ObservationIgnored private var scenes: [UUID: WeakScene] = [:]

    /// What each hosted window was opened with, so `reveal(sceneID:value:)`
    /// can find it.
    @ObservationIgnored private var hosts: [UUID: (sceneID: String, value: AnyHashable?)] = [:]
    @ObservationIgnored private var disconnectObserver: NSObjectProtocol?

    private init() {}

    /// How long an issued push waits for its window before it is forgotten.
    private static let claimTimeout: Duration = .seconds(5)

    // MARK: Queries

    /// Whether `token`'s window is hidden behind a window it pushed.
    public func isPushedAway(_ token: UUID) -> Bool {
        covers.values.contains(token)
    }

    /// Whether `token`'s window was pushed by another window that is hidden
    /// behind it.
    public func isPushed(_ token: UUID) -> Bool {
        covers[token] != nil
    }

    // MARK: Push

    /// Issue a push from `source`. `open` opens the window; the source hides
    /// once that window's host claims the push.
    func push(from source: UUID, sceneID: String, value: AnyHashable?, open: () -> Void) {
        // Strict: only the window the person is looking at can push. A window
        // that is itself hidden behind another (a model reacting in the
        // background) has no place in the stack to push from, and hiding it
        // further would leave the visible window beside the new one. Its
        // window opens as an ordinary pop-out.
        guard !isPushedAway(source) else {
            open()
            return
        }
        let entry = Pending(source: source, sceneID: sceneID, value: value, sourceSize: sizes[source])
        pending.append(entry)
        open()
        let pendingID = entry.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.claimTimeout)
            self?.pending.removeAll { $0.id == pendingID }
        }
    }

    /// The size the next window for `sceneID` should open at, if a push to it
    /// is waiting. Read by `raveWindowPushPlacement(id:)`.
    func pendingSize(for sceneID: String) -> CGSize? {
        pending.first { $0.sceneID == sceneID }?.sourceSize
    }

    // MARK: Reveal

    /// Show a hidden window again without closing what it pushed: each window
    /// it was hidden behind becomes an ordinary window beside it. For a Home
    /// button in a pushed window that should bring the caller back while the
    /// pushed window carries on (a streaming session, a player).
    ///
    /// `openWindow` on a hidden window cannot do this on its own: the window
    /// is already open, so the system only brings it forward, still hidden.
    /// Call this, then `openWindow`, so the window also comes to the person.
    public func reveal(sceneID: String, value: (any Hashable)? = nil) {
        let key = value.map { AnyHashable($0) }
        let tokens = hosts.filter { $0.value.sceneID == sceneID && $0.value.value == key }.map(\.key)
        for token in tokens {
            for (pushed, source) in covers where source == token {
                covers[pushed] = nil
            }
        }
    }

    /// Turn a pushed window into a pop-out: show the window it covers again
    /// and leave the pushed window open and running. The covered window
    /// becomes an ordinary window beside it. A no-op for a window that was not
    /// pushed.
    func detach(token: UUID) {
        covers[token] = nil
    }

    // MARK: Host bookkeeping

    func hostAppeared(token: UUID, sceneID: String, value: AnyHashable?) {
        hosts[token] = (sceneID, value)
        guard covers[token] == nil,
              let index = pending.firstIndex(where: { $0.sceneID == sceneID && $0.value == value })
        else { return }
        let claimed = pending.remove(at: index)
        // A source that closed while its push was in flight took its pending
        // entries with it (`hostGone`), so whatever is left can be hidden.
        guard claimed.source != token else { return }
        covers[token] = claimed.source
    }

    func hostGone(token: UUID) {
        // A pushed window closing reveals its source.
        covers[token] = nil
        // A source closing leaves its pushed window an ordinary window.
        for (pushed, source) in covers where source == token {
            covers[pushed] = nil
        }
        pending.removeAll { $0.source == token }
        sizes[token] = nil
        scenes[token] = nil
        hosts[token] = nil
    }

    func updateSize(token: UUID, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        sizes[token] = size
    }

    /// SwiftUI gives a scene the system disconnects (a recycle, a close from
    /// another window) no `onDisappear`, so the host also watches its scene.
    func attach(token: UUID, to scene: UIScene) {
        scenes[token] = WeakScene(scene)
        guard disconnectObserver == nil else { return }
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: UIScene.didDisconnectNotification, object: nil, queue: .main
        ) { notification in
            guard let scene = notification.object as? UIScene else { return }
            let identifier = ObjectIdentifier(scene)
            MainActor.assumeIsolated {
                RAVEWindowPushCoordinator.shared.sceneDidDisconnect(identifier)
            }
        }
    }

    private func sceneDidDisconnect(_ scene: ObjectIdentifier) {
        let gone = scenes.filter { $0.value.scene.map(ObjectIdentifier.init) == scene }.map(\.key)
        for token in gone { hostGone(token: token) }
    }

    private final class WeakScene {
        weak var scene: UIScene?
        init(_ scene: UIScene) { self.scene = scene }
    }
}

// MARK: - Action

/// Opens a window in place of the window it is called from. The stand-in for
/// SwiftUI's `PushWindowAction`, with the same call shapes.
@MainActor
public struct RAVEPushWindowAction {
    let source: UUID?
    let openWindow: OpenWindowAction?

    public func callAsFunction(id: String) {
        guard let openWindow else { return }
        guard let source else { return openWindow(id: id) }
        RAVEWindowPushCoordinator.shared.push(from: source, sceneID: id, value: nil) {
            openWindow(id: id)
        }
    }

    public func callAsFunction<V: Codable & Hashable>(id: String, value: V) {
        guard let openWindow else { return }
        guard let source else { return openWindow(id: id, value: value) }
        RAVEWindowPushCoordinator.shared.push(from: source, sceneID: id, value: AnyHashable(value)) {
            openWindow(id: id, value: value)
        }
    }
}

/// Detaches the calling window from the stack it was pushed onto, so the
/// window it covers shows again beside it. See `raveDetachFromStack`.
@MainActor
public struct RAVEDetachFromStackAction {
    let token: UUID?

    public func callAsFunction() {
        guard let token else { return }
        RAVEWindowPushCoordinator.shared.detach(token: token)
    }
}

// MARK: - Environment

private struct RAVEPushWindowKey: EnvironmentKey {
    static var defaultValue: RAVEPushWindowAction {
        MainActor.assumeIsolated { RAVEPushWindowAction(source: nil, openWindow: nil) }
    }
}

private struct RAVEDetachFromStackKey: EnvironmentKey {
    static var defaultValue: RAVEDetachFromStackAction {
        MainActor.assumeIsolated { RAVEDetachFromStackAction(token: nil) }
    }
}

private struct RAVEIsPushedAwayKey: EnvironmentKey {
    static let defaultValue = false
}

private struct RAVEIsPushedWindowKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// Push a window in place of this one. Outside a `raveWindowPushHost` it
    /// does nothing; inside one whose window is not tracked yet it opens the
    /// window without hiding anything.
    var ravePushWindow: RAVEPushWindowAction {
        get { self[RAVEPushWindowKey.self] }
        set { self[RAVEPushWindowKey.self] = newValue }
    }

    /// Make this pushed window a pop-out: the window it covers shows again
    /// beside it and this one keeps running. Use it for a "show the gallery"
    /// control on a stacked viewer. `dismissWindow()` instead ends this window
    /// (a player stops); detaching never does.
    var raveDetachFromStack: RAVEDetachFromStackAction {
        get { self[RAVEDetachFromStackKey.self] }
        set { self[RAVEDetachFromStackKey.self] = newValue }
    }

    /// True while this window is hidden behind a window it pushed. Hide
    /// ornaments with it: they are not covered by the host's opacity.
    var raveIsPushedAway: Bool {
        get { self[RAVEIsPushedAwayKey.self] }
        set { self[RAVEIsPushedAwayKey.self] = newValue }
    }

    /// True while this window was pushed and its caller is hidden behind it,
    /// so a Back button (`dismissWindow()`) will reveal the caller.
    var raveIsPushedWindow: Bool {
        get { self[RAVEIsPushedWindowKey.self] }
        set { self[RAVEIsPushedWindowKey.self] = newValue }
    }
}

// MARK: - Host

private struct RAVEWindowPushHostModifier: ViewModifier {
    let sceneID: String
    let value: AnyHashable?

    @State private var token = UUID()
    @Environment(\.openWindow) private var openWindow

    /// What the window itself asked for through `raveSystemOverlays`; nil when
    /// it never did.
    @State private var requestedOverlays: Visibility?
    /// True while a hidden state is being re-asserted after a resize: the
    /// applied value flips off for a moment so SwiftUI sees a real change.
    @State private var reasserting = false
    @State private var reassertTask: Task<Void, Never>?

    private static let reassertDelay: Duration = .milliseconds(600)

    private var coordinator: RAVEWindowPushCoordinator { .shared }

    func body(content: Content) -> some View {
        let pushedAway = coordinator.isPushedAway(token)
        let wantsHidden = pushedAway || requestedOverlays == .hidden
        let appliedOverlays: Visibility = wantsHidden
            ? (reasserting ? .automatic : .hidden)
            : (requestedOverlays ?? .automatic)
        content
            .environment(\.ravePushWindow, RAVEPushWindowAction(source: token, openWindow: openWindow))
            .environment(\.raveDetachFromStack, RAVEDetachFromStackAction(token: token))
            .environment(\.raveIsPushedAway, pushedAway)
            .environment(\.raveIsPushedWindow, coordinator.isPushed(token))
            .opacity(pushedAway ? 0 : 1)
            .allowsHitTesting(!pushedAway)
            .onPreferenceChange(RAVESystemOverlaysKey.self) { requestedOverlays = $0 }
            .persistentSystemOverlays(appliedOverlays)
            .animation(.easeInOut(duration: 0.2), value: pushedAway)
            .onGeometryChange(for: CGSize.self, of: \.size) { size in
                coordinator.updateSize(token: token, size: size)
                // A resize resets the system's overlay state to visible
                // without SwiftUI noticing; flip the applied value off and on
                // once the resize settles so a hidden state is applied again.
                guard pushedAway || requestedOverlays == .hidden else { return }
                reassertTask?.cancel()
                reasserting = true
                reassertTask = Task { @MainActor in
                    try? await Task.sleep(for: Self.reassertDelay)
                    guard !Task.isCancelled else { return }
                    reasserting = false
                }
            }
            .background {
                RAVEPushSceneReader { scene in
                    coordinator.attach(token: token, to: scene)
                }
            }
            .onAppear {
                coordinator.hostAppeared(token: token, sceneID: sceneID, value: value)
            }
            .onDisappear {
                coordinator.hostGone(token: token)
            }
    }
}

/// Reports the UIKit scene its view lands in.
private struct RAVEPushSceneReader: UIViewRepresentable {
    let onScene: (UIScene) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onScene = onScene
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {}

    final class ReaderView: UIView {
        var onScene: ((UIScene) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { onScene?(scene) }
        }
    }
}

public extension View {
    /// Take part in window pushing: provide `\.ravePushWindow` to this
    /// window's views, hide this window while a window it pushed is open, and
    /// claim a push aimed at this window.
    ///
    /// Apply to the scene's root content. `sceneID` and `value` are what the
    /// scene was opened with — the same pair a caller passes to
    /// `ravePushWindow(id:value:)` — and are how the window recognises the
    /// push meant for it. Leave `value` nil for a scene opened by id alone.
    func raveWindowPushHost(sceneID: String, value: (any Hashable)? = nil) -> some View {
        modifier(RAVEWindowPushHostModifier(sceneID: sceneID, value: value.map { AnyHashable($0) }))
    }
}

public extension Scene {
    /// Open a pushed window at its caller's size, as `pushWindow` did. Windows
    /// of this scene opened any other way keep the default placement.
    func raveWindowPushPlacement(id sceneID: String) -> some Scene {
        defaultWindowPlacement { _, _ in
            let size = MainActor.assumeIsolated {
                RAVEWindowPushCoordinator.shared.pendingSize(for: sceneID)
            }
            return WindowPlacement(size: size)
        }
    }
}

#endif
