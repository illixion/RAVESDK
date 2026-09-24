/*
 RAVE SDK — window-session bookkeeping, and the CGSize wrapper that goes with it.

 visionOS refuses to close an app's last window, and `openWindow` is async — so
 an app with pop-out scenes has to know whether a main window is currently up
 before it dismisses anything or tries to summon one. Both apps that have
 pop-out windows arrived at the same registry to answer that.
 */

// tvOS has one window and no openWindow.
#if canImport(SwiftUI) && !os(tvOS)

import CoreGraphics
import SwiftUI

/// `Codable`/`Hashable` wrapper around `CGSize`.
///
/// Window *values* get archived by visionOS scene restoration, and a bare
/// `CGSize` does not survive that encoder cleanly. This is what lets a window
/// remember a user-chosen size across a cold relaunch.
public struct RAVECodableSize: Codable, Hashable, Sendable {
    public var width: CGFloat
    public var height: CGFloat

    public init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    public init(_ size: CGSize) {
        self.width = size.width
        self.height = size.height
    }

    public var cgSize: CGSize {
        CGSize(width: width, height: height)
    }
}

/// Tracks how many "main" windows are open and holds a live `OpenWindowAction`,
/// so app and scene lifecycle hooks can summon the main window even when only
/// pop-out scenes are connected.
@MainActor
public final class RAVEWindowSessionRegistry {
    public static let shared = RAVEWindowSessionRegistry()

    public private(set) var mainWindowCount: Int = 0

    /// When the most recent main window registered. `RAVEOpenMainWindowIntent`
    /// uses this to tell "this activation just presented one" apart from "a
    /// main window exists somewhere" (possibly parked in another room).
    public private(set) var lastMainWindowRegistration: Date?

    /// The identifier `ensureMainWindowVisible` opens. Set once at launch if
    /// the app's main scene is not called "main".
    public var mainWindowID: String = "main"

    /// Most recently captured `openWindow` action from a SwiftUI view.
    /// Refreshed by every scene root on appear, so the reference stays live
    /// whichever scene happens to be rendered.
    public var openWindow: OpenWindowAction?

    /// Where a warning goes when there is no captured action. Apps route this
    /// into their own logger; nil is silent.
    public var log: (@MainActor (String) -> Void)?

    private init() {}

    public func registerMainWindow() {
        mainWindowCount += 1
        lastMainWindowRegistration = Date()
    }

    public func unregisterMainWindow() {
        mainWindowCount = Swift.max(0, mainWindowCount - 1)
    }

    /// Opens the main window if none is visible. No-op when one already is,
    /// so it is safe to call from scene and app lifecycle hooks.
    public func ensureMainWindowVisible() {
        guard mainWindowCount == 0 else { return }
        guard let openWindow else {
            log?("ensureMainWindowVisible: no openWindow action captured")
            return
        }
        log?("ensureMainWindowVisible: summoning main window")
        openWindow(id: mainWindowID, value: UUID())
    }

    /// Unconditionally open a fresh main window, regardless of how many are
    /// already up. This is the "give me a window *here*" primitive behind
    /// `RAVEOpenMainWindowIntent`; use `ensureMainWindowVisible()` for the
    /// no-op-when-one-exists semantic.
    public func openNewMainWindow() {
        guard let openWindow else {
            log?("openNewMainWindow: no openWindow action captured")
            return
        }
        openWindow(id: mainWindowID, value: UUID())
    }

    /// Surface the main window, then run `close`.
    ///
    /// `openWindow` is async, so a `dismissWindow` issued in the same turn can
    /// still be evaluated as "closing the last window" and silently dropped.
    /// Waiting for the main window to actually register first is what makes
    /// teardown reliable.
    public func closeAfterSurfacingMain(_ close: @escaping @MainActor () -> Void) {
        guard mainWindowCount == 0 else {
            close()
            return
        }
        ensureMainWindowVisible()
        Task { @MainActor in
            // Poll briefly rather than assuming a fixed delay: how long the
            // scene takes to connect depends on what else is being rendered.
            for _ in 0..<40 {
                if mainWindowCount > 0 { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            close()
        }
    }
}

/// Keeps `RAVEWindowSessionRegistry.shared.openWindow` fresh from any scene root.
private struct RAVECaptureOpenWindowModifier: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            RAVEWindowSessionRegistry.shared.openWindow = openWindow
        }
    }
}

public extension View {
    /// Capture this scene's `openWindow` into the shared registry.
    func captureOpenWindowAction() -> some View {
        modifier(RAVECaptureOpenWindowModifier())
    }

    /// Count this view's scene as a main window for as long as it exists.
    func registerAsMainWindow() -> some View {
        onAppear { RAVEWindowSessionRegistry.shared.registerMainWindow() }
            .onDisappear { RAVEWindowSessionRegistry.shared.unregisterMainWindow() }
    }
}

#endif
