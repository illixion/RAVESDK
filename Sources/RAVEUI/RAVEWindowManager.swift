/*
 RAVE SDK — the window manager: an inventory of the app's open windows, with
 per-window "summon it to me" and "close it".

 Two apps arrived at this independently. Longwave's Sessions tab exists because
 a window snapped in another room is unreachable until you physically walk back
 to it. Spatial Stash's exists for that *and* for a visionOS 27 regression where
 a window can be activated but never re-attached to a compositor placement — it
 stays invisible and non-interactable forever, while the scene keeps reporting
 itself active and visible. Nothing app-side can force such a scene to draw:
 geometry round-trips don't recover it, and views added afterwards never get a
 layout pass. Destroying the scene session and opening a fresh one is the only
 recovery.

 That second case is why **summon is a recycle, not a recall**. Longwave's
 original summon was `openWindow(id:)` against the live scene, which is exactly
 the call that triggers the visionOS 27 failure. Here the default is: dismiss
 the scene, open an equivalent fresh one. For value-typed windows the fresh
 value carries a new instance id, so it cannot match the scene being torn down
 and the two can be issued in the same turn. Windows whose value *is* their
 identity, and plain `Window` scenes addressed by id alone, have to wait for the
 old scene to actually disconnect first — hence `reopenRequiresTeardown`.

 What is deliberately *not* here, mirroring `RAVETabBar`: the window catalogue.
 One app has one window per kind with a live connection name under it, the other
 has many photo/video windows whose labels come from their content. So the app
 describes each window at registration and the manager renders whatever it is
 told.
 */

#if os(visionOS)

import SwiftUI
import UIKit

// MARK: - Description

/// How a window presents itself in the manager. Kept separate from the
/// action closures so it can be `Equatable` — an app that computes a subtitle
/// from live state (a connection name, a playing title) re-pushes it as it
/// changes.
public struct RAVEWindowLabel: Equatable, Sendable {
    public var title: String
    public var subtitle: String?
    public var systemImage: String

    public init(title: String, subtitle: String? = nil, systemImage: String = "macwindow") {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
    }
}

/// Everything the manager needs to list a window and act on it. Build one with
/// `.value(id:_:label:recreate:)` or `.singleton(id:label:)` and hand it to
/// `.manageWindow(_:)` on the scene's root view.
public struct RAVEManagedWindow {
    public let sceneID: String
    public var label: RAVEWindowLabel
    /// Type-erased escape hatch for an app that wants to get from a registry
    /// entry back to its own live content object — e.g. a window model, so
    /// another window can hand it something (a tab, a document) directly.
    /// `RAVEWindowRegistry` deliberately carries no window catalogue of its
    /// own (see the file header), so this is the one field that lets an app
    /// build one on top without a second, parallel registry. Left `nil` and
    /// untouched by every app that doesn't need it.
    public var payload: Any?

    let close: @MainActor (DismissWindowAction) -> Void
    /// `nil` when this window cannot be recreated, which hides Summon for it.
    let reopen: (@MainActor (OpenWindowAction) -> Void)?
    /// Whether the reopen must wait for the old scene to disconnect. False only
    /// when the fresh window carries an identity the dying scene cannot match.
    let reopenRequiresTeardown: Bool

    /// A window presented with a value payload.
    ///
    /// `recreate` returns the same content under a **fresh window identity**
    /// (typically a new `id` UUID). Supply it whenever the value type has one:
    /// it is what lets the dismiss and the open be issued together, with no
    /// teardown race and no chance of recalling the scene being destroyed.
    /// Without it the value is reused verbatim and the reopen waits.
    ///
    /// `@MainActor` because the stored closures are: taking the value and the
    /// `recreate` transform on the same isolation they will run on is what
    /// keeps non-`Sendable` window payloads (most app value types) usable here.
    @MainActor
    public static func value<V: Codable & Hashable>(
        id sceneID: String,
        _ value: V,
        label: RAVEWindowLabel,
        recreate: ((V) -> V)? = nil,
        payload: Any? = nil
    ) -> RAVEManagedWindow {
        RAVEManagedWindow(
            sceneID: sceneID,
            label: label,
            payload: payload,
            close: { dismiss in dismiss(id: sceneID, value: value) },
            reopen: { open in open(id: sceneID, value: recreate.map { $0(value) } ?? value) },
            reopenRequiresTeardown: recreate == nil
        )
    }

    /// A window addressed by scene id alone — SwiftUI's plain `Window` scene.
    @MainActor
    public static func singleton(id sceneID: String, label: RAVEWindowLabel, payload: Any? = nil) -> RAVEManagedWindow {
        RAVEManagedWindow(
            sceneID: sceneID,
            label: label,
            payload: payload,
            close: { dismiss in dismiss(id: sceneID) },
            reopen: { open in open(id: sceneID) },
            reopenRequiresTeardown: true
        )
    }

    /// A window the manager lists and can close, but never recreates. For
    /// content that cannot be rebuilt from a value (a live session that would
    /// be lost), where closing and reopening is not the same window.
    @MainActor
    public static func closableOnly(id sceneID: String, label: RAVEWindowLabel, payload: Any? = nil) -> RAVEManagedWindow {
        RAVEManagedWindow(
            sceneID: sceneID,
            label: label,
            payload: payload,
            close: { dismiss in dismiss(id: sceneID) },
            reopen: nil,
            reopenRequiresTeardown: false
        )
    }
}

// MARK: - Registry

/// Live inventory of the app's managed windows.
///
/// Distinct from `RAVEWindowSessionRegistry`, which answers one narrow question
/// ("is a main window up, and how do I open one?") for app lifecycle hooks.
/// This one is the user-facing inventory: every window, what it is, and where.
@MainActor
@Observable
public final class RAVEWindowRegistry {
    public static let shared = RAVEWindowRegistry()

    public struct Entry: Identifiable {
        /// Registration token — stable for the scene's lifetime. Deliberately
        /// not the window value's id: a recycled window comes back under a new
        /// value, and a summoned-then-listed window must not inherit the dead
        /// scene's row.
        public let id: UUID
        public let sceneID: String
        public fileprivate(set) var label: RAVEWindowLabel
        /// `true` while the scene phase is `.active` — in the user's current
        /// room. Note this reports what the *scene* believes; a window lost to
        /// the visionOS 27 placement bug still claims to be here.
        public fileprivate(set) var isInActiveRoom: Bool
        public let openedAt: Date

        fileprivate let window: RAVEManagedWindow

        /// Whether this window can be recycled (see `RAVEManagedWindow.value`).
        public var canSummon: Bool { window.reopen != nil }

        /// The app-specific content object this window was registered with, if
        /// any — see `RAVEManagedWindow.payload`.
        public var payload: Any? { window.payload }
    }

    /// Open windows in the order they were opened.
    public private(set) var windows: [Entry] = []

    private init() {}

    // MARK: Bookkeeping (driven by the `manageWindow` modifier)

    public func register(token: UUID, window: RAVEManagedWindow, isInActiveRoom: Bool) {
        guard !windows.contains(where: { $0.id == token }) else { return }
        windows.append(
            Entry(
                id: token,
                sceneID: window.sceneID,
                label: window.label,
                isInActiveRoom: isInActiveRoom,
                openedAt: Date(),
                window: window
            )
        )
    }

    public func unregister(token: UUID) {
        windows.removeAll { $0.id == token }
    }

    public func update(token: UUID, label: RAVEWindowLabel) {
        guard let index = windows.firstIndex(where: { $0.id == token }) else { return }
        windows[index].label = label
    }

    public func setActiveRoom(token: UUID, _ active: Bool) {
        guard let index = windows.firstIndex(where: { $0.id == token }) else { return }
        windows[index].isInActiveRoom = active
    }

    // MARK: Actions

    /// Close the window's scene.
    public func close(_ entry: Entry, dismiss: DismissWindowAction) {
        entry.window.close(dismiss)
    }

    /// Bring the window to the user by recycling its scene: dismiss it, then
    /// open an equivalent fresh one. This is both "fetch the window I left in
    /// the other room" and the only recovery for a window the compositor has
    /// stopped placing.
    public func summon(_ entry: Entry, open: OpenWindowAction, dismiss: DismissWindowAction) {
        guard let reopen = entry.window.reopen else { return }
        entry.window.close(dismiss)

        guard entry.window.reopenRequiresTeardown else {
            reopen(open)
            return
        }

        // The fresh window would be indistinguishable from the dying scene, so
        // reopening now would just recall the scene being destroyed. Wait for
        // it to unregister — but bounded: if it never disconnects, reopen
        // anyway rather than leaving the user with nothing.
        Task { @MainActor in
            for _ in 0..<Self.teardownPollCount {
                if !windows.contains(where: { $0.id == entry.id }) { break }
                try? await Task.sleep(for: .milliseconds(Self.teardownPollMS))
            }
            reopen(open)
        }
    }

    private static let teardownPollMS = 50
    private static let teardownPollCount = 60
}

// MARK: - Scene-level escape hatch

public enum RAVEWindowScenes {
    /// Destroy every connected window scene session except `keeping`.
    ///
    /// The registry cannot reach a scene that never ran `onAppear` — which is
    /// exactly what the launch-time variant of the visionOS 27 blank-window bug
    /// produces. This goes underneath SwiftUI to UIKit's scene sessions, so it
    /// also clears windows the app never managed to register. Returns how many
    /// sessions were asked to go away.
    @MainActor
    @discardableResult
    public static func destroyAll(except keeping: UISceneSession?) -> Int {
        let sessions = UIApplication.shared.connectedScenes.compactMap { scene -> UISceneSession? in
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.session.role == .windowApplication,
                  windowScene.session !== keeping else {
                return nil
            }
            return windowScene.session
        }
        for session in sessions {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
        }
        return sessions.count
    }

    /// Whether any window scene other than `keeping` is currently connected.
    @MainActor
    public static func hasWindows(besides keeping: UISceneSession?) -> Bool {
        UIApplication.shared.connectedScenes.contains { scene in
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.session.role == .windowApplication else {
                return false
            }
            return windowScene.session !== keeping
        }
    }
}

// MARK: - Registration modifier

/// The registration token of the window a view is being rendered in, so a
/// manager hosted *inside* a managed window can leave itself off the list.
public struct RAVEWindowTokenKey: EnvironmentKey {
    public static let defaultValue: UUID? = nil
}

public extension EnvironmentValues {
    var raveWindowToken: UUID? {
        get { self[RAVEWindowTokenKey.self] }
        set { self[RAVEWindowTokenKey.self] = newValue }
    }
}

private struct RAVEManageWindowModifier: ViewModifier {
    let window: RAVEManagedWindow
    @State private var token = UUID()
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .environment(\.raveWindowToken, token)
            .onAppear {
                RAVEWindowRegistry.shared.register(
                    token: token,
                    window: window,
                    isInActiveRoom: scenePhase == .active
                )
            }
            .onDisappear {
                RAVEWindowRegistry.shared.unregister(token: token)
            }
            .onChange(of: scenePhase) { _, phase in
                RAVEWindowRegistry.shared.setActiveRoom(token: token, phase == .active)
            }
            .onChange(of: window.label) { _, label in
                RAVEWindowRegistry.shared.update(token: token, label: label)
            }
    }
}

public extension View {
    /// List this scene in `RAVEWindowRegistry` for its lifetime, keeping its
    /// room status and label current. Apply to each scene's root content.
    ///
    /// Only the label is re-pushed as it changes; the action closures are taken
    /// once, which is correct because a window's *identity* never changes after
    /// it opens (that is what makes summoning it possible at all).
    func manageWindow(_ window: RAVEManagedWindow) -> some View {
        modifier(RAVEManageWindowModifier(window: window))
    }
}

// MARK: - Manager UI

/// The window inventory, shaped as a tab's root view: a list of open windows
/// with Summon and Close on each, plus an optional trailing section for
/// app-specific bulk actions.
///
/// The window hosting this view leaves itself off the list automatically (see
/// `EnvironmentValues.raveWindowToken`).
public struct RAVEWindowManagerView<Actions: View>: View {
    private let title: String
    private let emptyMessage: String
    private let actions: () -> Actions

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.raveWindowToken) private var selfToken

    private var registry: RAVEWindowRegistry { .shared }

    public init(
        title: String = "Windows",
        emptyMessage: String = "Windows you open will be listed here, so you can bring them back to you or close them.",
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.emptyMessage = emptyMessage
        self.actions = actions
    }

    private var listedWindows: [RAVEWindowRegistry.Entry] {
        registry.windows.filter { $0.id != selfToken }
    }

    public var body: some View {
        NavigationStack {
            List {
                if listedWindows.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Other Windows",
                            systemImage: "macwindow.on.rectangle",
                            description: Text(emptyMessage)
                        )
                    }
                } else {
                    Section {
                        ForEach(listedWindows) { entry in
                            RAVEWindowManagerRow(
                                entry: entry,
                                summon: {
                                    registry.summon(entry, open: openWindow, dismiss: dismissWindow)
                                },
                                close: {
                                    registry.close(entry, dismiss: dismissWindow)
                                }
                            )
                        }
                    } footer: {
                        Text("Summon closes a window and reopens it in front of you — use it to retrieve a window left in another room, or to recover one that has gone invisible.")
                    }
                }

                actions()
            }
            .navigationTitle(title)
        }
    }
}

public extension RAVEWindowManagerView where Actions == EmptyView {
    init(
        title: String = "Windows",
        emptyMessage: String = "Windows you open will be listed here, so you can bring them back to you or close them."
    ) {
        self.init(title: title, emptyMessage: emptyMessage) { EmptyView() }
    }
}

/// One window's row. Public so an app embedding the inventory in a settings
/// screen rather than a tab renders identical rows.
public struct RAVEWindowManagerRow: View {
    public let entry: RAVEWindowRegistry.Entry
    public let summon: () -> Void
    public let close: () -> Void

    public init(
        entry: RAVEWindowRegistry.Entry,
        summon: @escaping () -> Void,
        close: @escaping () -> Void
    ) {
        self.entry = entry
        self.summon = summon
        self.close = close
    }

    public var body: some View {
        HStack(spacing: 16) {
            Image(systemName: entry.label.systemImage)
                .font(.title2)
                .frame(width: 44)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label.title)
                    .font(.headline)
                if let subtitle = entry.label.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Label(
                    entry.isInActiveRoom ? "In this room" : "In another room",
                    systemImage: entry.isInActiveRoom ? "location.fill" : "location.slash"
                )
                .font(.caption)
                .foregroundStyle(entry.isInActiveRoom ? Color.secondary : Color.orange)
            }

            Spacer()

            if entry.canSummon {
                Button(action: summon) {
                    Label("Summon", systemImage: "arrow.down.right.and.arrow.up.left.rectangle")
                }
                .buttonStyle(.borderedProminent)
            }

            Button(role: .destructive, action: close) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close this window")
        }
        .padding(.vertical, 6)
    }
}

#endif
