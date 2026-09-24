/*
 RAVE SDK — "Open Main Window" App Intent.

 visionOS offers no public control over which scene the system foregrounds when
 the user taps an app's icon: with any window alive anywhere, the launch-scene
 machinery (`defaultLaunchBehavior`) is skipped entirely and the OS summons the
 nearest existing window to the user — dragging a wall-pinned window out of its
 room instead of opening a fresh main window. There is no reopen callback and no
 opt-out (researched Aug 2026; developer forums 748187/789355 confirm the gap).

 This intent is the supported escape hatch: "Hey Siri, open a <app> window" (or
 a Shortcuts action) runs in-process and opens a *new* main window at the user's
 location, leaving parked windows untouched. Apps expose it through their own
 `AppShortcutsProvider` — App Shortcuts cannot live in a package — and chain the
 metadata via `RAVEUIAppIntentsPackage`:

     extension MyApp: AppIntentsPackage {
         static var includedPackages: [any AppIntentsPackage.Type] {
             [RAVEUIAppIntentsPackage.self]
         }
     }

 The main-window id and the live `openWindow` action come from
 `RAVEWindowSessionRegistry`, so the host must already capture scene actions
 with `captureOpenWindowAction()` and count mains with `registerAsMainWindow()`.
 */

#if canImport(AppIntents) && canImport(SwiftUI) && !os(tvOS)

import AppIntents
import Foundation

/// Metadata anchor for App Intents defined in RAVEUI. Host apps list this in
/// their own `AppIntentsPackage.includedPackages` so Xcode's extractor
/// processes the package's intents.
public struct RAVEUIAppIntentsPackage: AppIntentsPackage {}

/// Opens a fresh main window at the user's location.
///
/// Deliberately *always* opens a new window rather than no-op'ing when a main
/// window is already registered: a registered main window may be parked in
/// another room (registration tracks scene existence, not visibility), and a
/// user invoking this by voice wants a window *here*. The one exception is a
/// main window that registered within `launchGrace` — that means this very
/// activation already presented one (scene restoration, or the launch-behavior
/// machinery on a cold start), and opening another would double up.
public struct RAVEOpenMainWindowIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Main Window"
    public static let description = IntentDescription(
        "Opens a new main window at your location, leaving windows placed in other rooms untouched."
    )

    /// The intent is meaningless without the app's scenes on screen.
    public static let openAppWhenRun: Bool = true

    /// How long to wait for a scene root to capture an `openWindow` action on
    /// a cold launch before giving up.
    private static let actionCaptureTimeout: Duration = .seconds(3)

    /// Settle time after the action is available, so scenes presented by this
    /// same activation (restoration, `defaultLaunchBehavior(.presented)`, an
    /// app-delegate fallback) have registered before we decide whether one of
    /// them already covers us. Deliberately longer than typical app-side
    /// "ensure main window" delays (~400ms) so we observe their result instead
    /// of racing it.
    private static let launchSettle: Duration = .milliseconds(1200)

    /// A main window registered this recently is attributed to the current
    /// activation, not to an old scene parked in another room — `onAppear`
    /// fires when a scene's content joins the hierarchy, not on every
    /// background→foreground flutter.
    private static let launchGrace: TimeInterval = 5

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        let registry = RAVEWindowSessionRegistry.shared

        // Cold launch: perform() can run before any SwiftUI scene root has
        // appeared and captured its openWindow action. Poll briefly.
        let deadline = ContinuousClock.now + Self.actionCaptureTimeout
        while registry.openWindow == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard registry.openWindow != nil else {
            registry.log?("RAVEOpenMainWindowIntent: no openWindow action captured; giving up")
            return .result()
        }

        try? await Task.sleep(for: Self.launchSettle)

        if let registered = registry.lastMainWindowRegistration,
           Date().timeIntervalSince(registered) < Self.launchGrace {
            registry.log?("RAVEOpenMainWindowIntent: launch already presented a main window; skipping")
            return .result()
        }

        registry.log?("RAVEOpenMainWindowIntent: opening a fresh main window")
        registry.openNewMainWindow()
        return .result()
    }
}

#endif
