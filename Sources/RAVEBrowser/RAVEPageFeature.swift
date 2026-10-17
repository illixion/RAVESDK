//
//  RAVEPageFeature.swift
//  RAVEBrowser
//
//  The seam where an app attaches its own page scripts and bridges to a
//  `RAVEBrowserTab`. The tab core is generic; everything an app does *to* a
//  page (Raven's ad blocker, frame extraction, screen share, call audio,
//  diagnostics; the call layer below, for any app that opts in) is a feature.
//
//  **A feature's life follows the tab's, not the web view's.** The tab owns
//  one `WKUserContentController` for its whole life and configures every web
//  view it builds with it (see `RAVEBrowserTab`), so a feature installs its
//  user scripts and message handlers once, at the tab's birth, and they
//  survive hibernation. What a feature does see come and go is the web view:
//  `attach(to:)` hands it each one built, and `nil` when it is released.
//
//  **Script order is load-bearing, and the app decides it.** User scripts run
//  in the order they were added, and scripts that wrap the same function
//  (`getUserMedia`, `play()`) form a chain in that order: the one added last
//  is the one the page calls first. Raven's chain, for one, is page →
//  diagnostics → call audio → camera proxy → WebRTC recovery → WebKit:
//  identity first so every later script sees the finished costume, recovery
//  below the proxy so it probes and restarts the *real* camera and never sees
//  the canvas stream, call audio above the proxy so a combined request reaches
//  the proxy as the video-only one it handles, diagnostics last so its
//  capability report describes the world after every shim installed. So the
//  tab calls `install(on:)` on its features in exactly the order the app
//  listed them, and that array is the one place the order is written down.
//  `RAVECallFeatures` returns the call layer already in its order.
//

#if canImport(WebKit)
import Foundation
import WebKit

@MainActor
public protocol RAVEPageFeature: AnyObject {
    /// Once, at the tab's birth, in the order the app listed its features:
    /// add this feature's user scripts and message handlers to the tab's
    /// controller. They stay for the tab's whole life.
    func install(on controller: WKUserContentController)
    /// The tab built a web view (`webView`), or released the one it had
    /// (`nil`). Hold it weakly.
    func attach(to webView: WKWebView?)
    /// The document is going away: a navigation started, or the tab is
    /// hibernating. Anything keyed to the old document (frame tokens, a
    /// session the page set up) stops being true here.
    func pageWillNavigate()
    /// Why the tab must not be hibernated right now — a call, a share, a
    /// conversion — or nil. Asked at the moment of hibernating, not only when
    /// a sweep picks a victim.
    var hibernationBlocker: String? { get }
    /// The tab is closing. Remove message handlers: the controller retains
    /// them, and would keep the whole chain alive past the tab.
    func close()
}

public extension RAVEPageFeature {
    func attach(to webView: WKWebView?) {}
    func pageWillNavigate() {}
    var hibernationBlocker: String? { nil }
    func close() {}
}

/// A feature that is only user scripts: nothing to attach, nothing to close.
@MainActor
public final class RAVEUserScriptFeature: RAVEPageFeature {
    public let scripts: [WKUserScript]

    public init(_ scripts: WKUserScript...) {
        self.scripts = scripts
    }

    public init(scripts: [WKUserScript]) {
        self.scripts = scripts
    }

    public func install(on controller: WKUserContentController) {
        for script in scripts { controller.addUserScript(script) }
    }
}

// MARK: - Reports

/// Where page scripts that only report — the keyboard guard, the WebRTC
/// watchdog — send their lines when the app has no diagnostics of its own.
/// Each report becomes one log line in `RAVEBrowserLog.page`: its kind
/// (vetted, `.public`) and the rest of its fields `.private`, since they name
/// elements, labels and URLs from the page.
///
/// Raven passes its own `PageDiagnostics` handler name to those scripts
/// instead and formats each kind itself; this is the default for an app that
/// has nothing like it, so the `rtcStalled`/`rtcRecovered` evidence is not
/// simply dropped.
@MainActor
public final class RAVEPageReports: RAVEPageFeature {
    /// The handler the reporting scripts post to unless told otherwise.
    nonisolated public static let messageHandler = "ravePageReports"

    public let name: String
    /// Every report, after it is logged.
    public var onReport: (([String: Any]) -> Void)?

    private let tag: String
    private let handler = Handler()
    private weak var controller: WKUserContentController?

    /// - Parameter tabID: its first four characters prefix each line, to
    ///   tell apart tabs loading at once.
    public init(tabID: UUID? = nil, messageHandler: String = RAVEPageReports.messageHandler) {
        name = messageHandler
        tag = tabID.map { String($0.uuidString.prefix(4)) } ?? "page"
    }

    public func install(on controller: WKUserContentController) {
        self.controller = controller
        let tag = tag
        handler.onMessage = { [weak self] body in
            MainActor.assumeIsolated {
                Self.log(body, tag: tag)
                self?.onReport?(body)
            }
        }
        controller.add(handler, name: name)
    }

    public func close() {
        controller?.removeScriptMessageHandler(forName: name)
        handler.onMessage = nil
    }

    private static func log(_ body: [String: Any], tag: String) {
        let kind = RAVELogToken.vet(body["kind"])
        let isTop = body["top"] as? Bool ?? true
        let fields = body.keys.filter { $0 != "kind" && $0 != "top" }.sorted()
            .map { "\($0)=\(String(describing: body[$0] ?? ""))" }
            .joined(separator: " ")
        RAVEBrowserLog.page.info("""
        [\(tag, privacy: .public)\(isTop ? "" : " iframe", privacy: .public)] \
        \(kind, privacy: .public) \(fields, privacy: .private)
        """)
    }

    final class Handler: NSObject, WKScriptMessageHandler {
        var onMessage: (([String: Any]) -> Void)?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            onMessage?(body)
        }
    }
}

// MARK: - JavaScript literals

/// One JSON-based escaper for every value Swift puts into script source.
/// A device label or a page-supplied string is attacker-controlled text, and
/// hand-quoting it is how script injection happens. Raven's
/// `VideoCaptureScript.jsLiteral`, the same rules.
enum RAVEJavaScript {
    static func literal(_ value: Any) -> String {
        switch value {
        case let bool as Bool:
            return bool ? "true" : "false"
        case let int as Int:
            return String(int)
        case let double as Double:
            return double.isFinite ? String(double) : "0"
        default:
            let data = (try? JSONSerialization.data(withJSONObject: [String(describing: value)]))
                ?? Data("[\"\"]".utf8)
            let array = String(decoding: data, as: UTF8.self)
            // Unwrap the single-element array JSONSerialization requires.
            return String(array.dropFirst().dropLast())
        }
    }

    /// A string as a quoted JavaScript literal.
    static func string(_ value: String) -> String { literal(value) }
}
#endif
