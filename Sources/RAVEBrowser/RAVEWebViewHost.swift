//
//  RAVEWebViewHost.swift
//  RAVEBrowser
//
//  Shows a WKWebView the app owns, and pauses it. The representable creates
//  nothing: the web view belongs to the app (a tab, a screen) and outlives
//  every view that shows it, so `makeUIView` returns a plain container and
//  `updateUIView` puts the current web view into it. Raven's BrowserWebView
//  is the same shape and the reason tab switches there are swaps, not reloads.
//
//  Pausing is taking the web view out of the container. On visionOS that is
//  the only thing WebKit treats as "nobody can see this page" — measured on
//  the AVP (2026-09-28) with a page counting its own animation frames: in a
//  RealityKit attachment it ran at ~120 frames/s and reported itself visible
//  while its screen was behind the user, disabled, or removed from the scene,
//  and `isHidden` changed nothing. Out of its superview it drops to 0 frames/s,
//  timers throttle to ~0.4/s, the page gets a `visibilitychange` to hidden,
//  and putting it back resumes it at once. Media is suspended as well, since
//  a hidden page's playback was not measured.
//
//  A paused page's scripts still run, slowly, so `RAVEPageDriver` can read
//  it, but a snapshot or an element list wants it back in a window first.
//

#if canImport(UIKit) && canImport(WebKit)
import SwiftUI
import WebKit

public struct RAVEWebViewHost: UIViewRepresentable {
    /// The page to show, or nil for none.
    public let webView: WKWebView?
    public let isPaused: Bool

    public init(webView: WKWebView?, isPaused: Bool = false) {
        self.webView = webView
        self.isPaused = isPaused
    }

    public func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        return container
    }

    public func updateUIView(_ container: UIView, context: Context) {
        let wanted = isPaused ? nil : webView
        for subview in container.subviews where subview !== wanted { subview.removeFromSuperview() }
        if let webView, context.coordinator.mediaSuspended != isPaused {
            context.coordinator.mediaSuspended = isPaused
            let suspend = isPaused
            Task { @MainActor in await webView.setAllMediaPlaybackSuspended(suspend) }
        }
        guard let wanted, wanted.superview !== container else { return }
        wanted.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(wanted)
        NSLayoutConstraint.activate([
            wanted.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            wanted.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            wanted.topAnchor.constraint(equalTo: container.topAnchor),
            wanted.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        var mediaSuspended = false
    }

    /// Leave the web view attached to nothing rather than letting UIKit tear
    /// it down with the container: the app still owns it.
    public static func dismantleUIView(_ container: UIView, coordinator: Coordinator) {
        for subview in container.subviews { subview.removeFromSuperview() }
    }
}
#endif
