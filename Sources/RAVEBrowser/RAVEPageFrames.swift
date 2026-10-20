//
//  RAVEPageFrames.swift
//  RAVEBrowser
//
//  Every frame of a page, so the driver can reach into iframes: a login
//  widget, a payment field, a video player, a cookie dialog served from
//  another origin. WebKit has no public way to list a page's frames; what it
//  does hand over is the `WKFrameInfo` of whichever frame posts a script
//  message, and a `WKFrameInfo` is exactly what `callAsyncJavaScript(in:)`
//  takes. So each frame announces itself as its document starts.
//
//  The announcing script runs in the driver's own content world, which the
//  page can neither see nor reach, and a cross-origin frame is no different
//  from any other there. That is why this is safe for every tab, unlike
//  `RAVEPageSupport`'s page-world wrappers, and why `RAVEBrowserTab` installs
//  it on all of them.
//
//  A frame's token lives in that world's global, so a frame that navigates
//  announces a new one, and a stale token is simply never answered again.
//

#if canImport(WebKit)
import Foundation
import WebKit

@MainActor
public final class RAVEPageFrames: RAVEPageFeature {
    nonisolated public static let messageHandler = "raveFrames"

    public struct Frame {
        /// Stable for the frame's current document.
        public let id: String
        public let info: WKFrameInfo
        /// The document's URL when it announced itself.
        public let url: String
    }

    /// The world the announcements run in: the driver's, so the token the
    /// driver reads back is the one registered here.
    public let world: WKContentWorld
    /// Subframes only, oldest first; the main frame is the driver's default.
    public private(set) var frames: [Frame] = []

    private let handler = Handler()
    private weak var controller: WKUserContentController?

    public init(worldName: String = "RAVEBrowser") {
        world = .world(name: worldName)
    }

    public func frame(id: String) -> Frame? { frames.first { $0.id == id } }

    /// For a web view no `RAVEBrowserTab` owns: installs on its controller.
    /// Frames already loaded announce themselves only on their next load.
    public func install(on webView: WKWebView) {
        install(on: webView.configuration.userContentController)
    }

    public func install(on controller: WKUserContentController) {
        self.controller = controller
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: world))
        handler.onMessage = { [weak self] id, url, info in
            MainActor.assumeIsolated { self?.register(id: id, url: url, info: info) }
        }
        controller.add(handler, contentWorld: world, name: Self.messageHandler)
    }

    public func pageWillNavigate() {
        frames = []
    }

    public func close() {
        controller?.removeScriptMessageHandler(forName: Self.messageHandler, contentWorld: world)
        handler.onMessage = nil
    }

    /// Drops a frame the driver found gone (removed, or navigated away).
    func forget(_ id: String) {
        frames.removeAll { $0.id == id }
    }

    private func register(id: String, url: String, info: WKFrameInfo) {
        guard !info.isMainFrame else { return }
        frames.removeAll { $0.id == id }
        frames.append(Frame(id: id, info: info, url: url))
        // A page that churns ads through iframes would otherwise grow this
        // forever; the driver prunes dead ones as it meets them, and this
        // caps what it has to try.
        if frames.count > 64 { frames.removeFirst(frames.count - 64) }
    }

    final class Handler: NSObject, WKScriptMessageHandler {
        var onMessage: ((String, String, WKFrameInfo) -> Void)?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let id = body["id"] as? String else { return }
            onMessage?(id, body["url"] as? String ?? "", message.frameInfo)
        }
    }

    /// In the driver's world, in every frame: a token for this document,
    /// announced once.
    static let script = #"""
        (() => {
            const R = globalThis.__rave || (globalThis.__rave = { refs: [] });
            if (R.frameID || window === window.top) return;
            R.frameID = (Math.random().toString(36) + Math.random().toString(36)).replace(/0\./g, '').slice(0, 12);
            const handlers = globalThis.webkit && globalThis.webkit.messageHandlers;
            if (handlers && handlers.raveFrames) handlers.raveFrames.postMessage({ id: R.frameID, url: location.href });
        })();
        """#
}
#endif
