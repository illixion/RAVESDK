//
//  RAVEBackgroundWindow.swift
//  RAVEBrowser
//
//  A window that keeps a page rendering on the Mac without ever taking focus:
//  for the tests, RAVEBrowserLab and an agent harness, which drive pages while
//  the person goes on working in another app.
//
//  A page needs a window. WebKit treats a web view in no window as hidden: it
//  stops painting, throttles timers and refuses snapshots. And a window that
//  is shown normally takes focus — the process activates, and the window
//  comes forward over whatever the person was doing. So:
//
//  - **The process is an accessory app** (`enterBackgroundMode`): no Dock
//    icon, no menu bar, never activated by showing a window. The same mode
//    Oneiros's Mac harness runs in (`ONEIROS_HARNESS_BACKGROUND=1`). An app
//    the person also uses normally must not call it: it would lose its Dock
//    icon and menus.
//  - **The window goes behind everything** (`.behind`), or in front without
//    becoming key (`.front`, for watching a run). Neither makes it key or
//    activates anything.
//  - **WebKit's occlusion check is off for the view**, so a page behind other
//    windows renders and runs timers as if it were visible. That is SPI
//    (`_setWindowOcclusionDetectionEnabled:`), set by key behind a
//    `responds(to:)` guard: a WebKit without it costs a background page its
//    animation frames, not a crash.
//
//  Real input still reaches a background window: clicks, keys and typed text
//  are delivered to the web view directly (`RAVENativeInput`). Pointer moves
//  are the exception — WebKit ignores a move into a window that is not key —
//  so hover falls back to synthetic events there, and says so.
//

#if os(macOS) && canImport(WebKit)
import AppKit
import WebKit

@MainActor
public enum RAVEBackgroundWindow {
    public enum Placement: Sendable {
        /// Behind every other window: nothing appears on screen.
        case behind
        /// In front of other windows, to watch, but never key: typing still
        /// goes to whatever had focus.
        case front
    }

    /// Makes this process an accessory app, which showing a window never
    /// activates. Only for a process with no other UI: a test runner, a lab,
    /// an app launched only to serve an agent.
    public static func enterBackgroundMode() {
        let app = NSApplication.shared
        if app.activationPolicy() != .accessory { app.setActivationPolicy(.accessory) }
    }

    /// A titled window of `size` holding `view`, shown without taking focus.
    /// Keep the returned window: closing it is the caller's.
    @discardableResult
    public static func show(_ view: WKWebView, size: CGSize, title: String = "",
                            placement: Placement = .behind) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = view
        keepRenderingWhenCovered(view)
        switch placement {
        case .behind: window.orderBack(nil)
        case .front: window.orderFrontRegardless()
        }
        return window
    }

    /// Turns off WebKit's occlusion check for `view`, so being covered by
    /// other windows does not make the page hidden. See the header.
    public static func keepRenderingWhenCovered(_ view: WKWebView) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard view.responds(to: selector) else { return }
        // The key without its underscore: KVC looks for `set<Key>:` and then
        // `_set<Key>:`, and the second is this setter's name.
        view.setValue(false, forKey: "windowOcclusionDetectionEnabled")
    }
}
#endif
