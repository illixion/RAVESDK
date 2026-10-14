//
//  RAVEPageDriver.swift
//  RAVEBrowser
//
//  A Chrome-MCP-sized tool surface over a WKWebView an app already shows:
//  navigate, read, list elements, snapshot (optionally with each element's
//  ref drawn on it), click, type, scroll, find, dismiss overlays. What a
//  language model needs to use a page without anything site-specific — it
//  looks at the marked snapshot or reads the outline and answers with refs.
//
//  The driver borrows the view and claims nothing on it: no navigation or UI
//  delegate (the host app, Raven's BrowserTab for one, owns those), no user
//  scripts. Loading is watched through `isLoading`, and every script runs in
//  its own content world, out of the page's reach.
//
//  Deliberately absent: running arbitrary JavaScript. Page text reaches the
//  model, and a model that can be talked into running script can do anything
//  the page can.
//
//  Input is synthetic: events from script are untrusted, and the few sites
//  that check `isTrusted` will ignore them. There is no public way to inject
//  a real touch into a WKWebView.
//

#if canImport(WebKit)
import Foundation
import WebKit

public enum RAVEPageError: Error, LocalizedError, Equatable {
    /// The web view has been deallocated.
    case noWebView
    /// The page threw; the message says why ("stale ref 4: …").
    case script(String)
    case timeout(String)
    case snapshotFailed(String)
    case badResult(String)

    public var errorDescription: String? {
        switch self {
        case .noWebView: "the web view is gone"
        case .script(let message): message
        case .timeout(let what): "timed out: \(what)"
        case .snapshotFailed(let why): "snapshot failed: \(why)"
        case .badResult(let why): "unexpected script result: \(why)"
        }
    }
}

@MainActor
public final class RAVEPageDriver {
    public private(set) weak var webView: WKWebView?
    public let world: WKContentWorld

    public init(webView: WKWebView, worldName: String = "RAVEBrowser") {
        self.webView = webView
        self.world = .world(name: worldName)
    }

    // MARK: - Navigation

    public func info() async throws -> RAVEPageInfo {
        var info: RAVEPageInfo = try await run(RAVEPageScripts.info)
        info.isLoading = webView?.isLoading
        return info
    }

    @discardableResult
    public func navigate(to url: URL, timeout: Duration = .seconds(20)) async throws -> RAVEPageInfo {
        try view().load(URLRequest(url: url))
        return try await settle(expectingNavigation: true, timeout: timeout)
    }

    /// Loads markup directly, for local pages and tests.
    @discardableResult
    public func load(html: String, baseURL: URL? = nil, timeout: Duration = .seconds(10)) async throws -> RAVEPageInfo {
        try view().loadHTMLString(html, baseURL: baseURL)
        return try await settle(expectingNavigation: true, timeout: timeout)
    }

    @discardableResult
    public func goBack() async throws -> RAVEPageInfo {
        try view().goBack()
        return try await settle(expectingNavigation: true, timeout: .seconds(20))
    }

    @discardableResult
    public func goForward() async throws -> RAVEPageInfo {
        try view().goForward()
        return try await settle(expectingNavigation: true, timeout: .seconds(20))
    }

    @discardableResult
    public func reload() async throws -> RAVEPageInfo {
        try view().reload()
        return try await settle(expectingNavigation: true, timeout: .seconds(20))
    }

    // MARK: - Reading

    public func read(mode: RAVEPageReading.Mode = .auto, maxCharacters: Int = 20_000) async throws -> RAVEPageReading {
        if mode != .page, mode != .main { try await loadReadability() }
        return try await run(RAVEPageScripts.read, ["mode": mode.rawValue, "maxCharacters": maxCharacters])
    }

    public enum Scope: String, Sendable {
        /// What is on screen and not covered by something else.
        case viewport
        /// Everything rendered, scrolled away or not.
        case page
    }

    /// Lists what can be clicked or typed into, and numbers it. The numbers
    /// are what `click`, `type` and `scroll(toRef:)` take, until the next
    /// call or navigation.
    public func elements(scope: Scope = .viewport, limit: Int = 150) async throws -> RAVEPageElements {
        try await run(RAVEPageScripts.elements, ["scope": scope.rawValue, "limit": limit])
    }

    public func find(_ text: String, index: Int = 0) async throws -> RAVEPageFind {
        try await run(RAVEPageScripts.find, ["text": text, "index": index])
    }

    /// The viewport as a JPEG, `width` pixels wide. With `marks`, each listed
    /// element's box and ref is drawn on it (set-of-marks), so a vision model
    /// can answer "click 12" without producing coordinates.
    public func snapshot(width: Int = 1024, marks: RAVEPageElements? = nil, quality: Double = 0.75) async throws -> Data {
        let view = try view()
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let image: CGImage?
        do {
            #if canImport(UIKit)
            image = try await view.takeSnapshot(configuration: configuration).cgImage
            #else
            image = try await view.takeSnapshot(configuration: configuration)
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
            #endif
        } catch {
            throw RAVEPageError.snapshotFailed(error.localizedDescription)
        }
        guard let image else { throw RAVEPageError.snapshotFailed("no image") }
        let viewportWidth = marks?.viewport.width ?? Double(view.bounds.width)
        guard let jpeg = RAVEMarkedSnapshot.jpeg(image, width: width, viewportWidth: viewportWidth,
                                                 marks: marks?.elements ?? [], quality: quality) else {
            throw RAVEPageError.snapshotFailed("could not encode")
        }
        return jpeg
    }

    // MARK: - Acting

    @discardableResult
    public func click(ref: Int) async throws -> RAVEPageAction {
        try await act(RAVEPageScripts.click, ["ref": ref, "x": NSNull(), "y": NSNull()])
    }

    /// Clicks whatever is at a point in viewport CSS pixels: the fallback
    /// for a model that answers with coordinates.
    @discardableResult
    public func click(x: Double, y: Double) async throws -> RAVEPageAction {
        try await act(RAVEPageScripts.click, ["ref": NSNull(), "x": x, "y": y])
    }

    /// Replaces (or with `append`, extends) a field's text; `submit` then
    /// presses Enter and submits its form if the page did not stop it.
    @discardableResult
    public func type(ref: Int, text: String, append: Bool = false, submit: Bool = false) async throws -> RAVEPageAction {
        try await act(RAVEPageScripts.type, ["ref": ref, "text": text, "append": append, "submit": submit])
    }

    /// Scrolls by a fraction of the viewport; negative is up.
    @discardableResult
    public func scroll(by viewports: Double) async throws -> RAVEPageScroll {
        try await run(RAVEPageScripts.scroll, ["by": viewports, "to": NSNull(), "ref": NSNull()])
    }

    public enum Edge: String, Sendable { case top, bottom }

    @discardableResult
    public func scroll(to edge: Edge) async throws -> RAVEPageScroll {
        try await run(RAVEPageScripts.scroll, ["by": NSNull(), "to": edge.rawValue, "ref": NSNull()])
    }

    @discardableResult
    public func scroll(toRef ref: Int) async throws -> RAVEPageScroll {
        try await run(RAVEPageScripts.scroll, ["by": NSNull(), "to": NSNull(), "ref": ref])
    }

    /// Hides cookie banners, sign-up walls and other modal layers, and undoes
    /// the scroll lock they put on the page. A heuristic: `read()` in reader
    /// mode is unaffected by overlays in the first place and is the better
    /// tool when the text is all that is wanted.
    @discardableResult
    public func dismissOverlays() async throws -> RAVEPageOverlays {
        try await run(RAVEPageScripts.dismissOverlays)
    }

    // MARK: - Plumbing

    private func view() throws -> WKWebView {
        guard let webView else { throw RAVEPageError.noWebView }
        return webView
    }

    private func act(_ script: String, _ arguments: [String: Any]) async throws -> RAVEPageAction {
        var action: RAVEPageAction = try await run(script, arguments)
        var navigated = try await waitForLoad(expectingNavigation: action.followed != nil, timeout: .seconds(20))
            || action.followed != nil
        var quiet = try? await quiet()
        // A click's script can start a navigation after the grace for one
        // has passed (a search result going through a redirect does): the
        // wait sees the page leave, and then waits for the next one.
        let loading = try view().isLoading
        if quiet?.leaving == true || loading {
            navigated = true
            try await waitForLoad(expectingNavigation: true, timeout: .seconds(20))
            quiet = try? await self.quiet()
        }
        // After a navigation the changes counted are the new document's own
        // rendering, which says nothing about the click; the load does.
        if !navigated { action.changes = quiet?.changes }
        action.info = try await info()
        return action
    }

    /// How long the document must go unchanged to count as settled, and the
    /// most an action or a load waits for it. A second, because the page
    /// can go still while its fetch is out: a click marks a button expanded
    /// at once and the content follows when the server answers. A model's
    /// turn takes several seconds anyway, so waiting costs little.
    public var quietPeriod: Duration = .milliseconds(1000)
    public var quietLimit: Duration = .milliseconds(3000)

    /// Waits for the document to stop changing: an app-like page fetches and
    /// renders after its load has finished, and after a click that loads
    /// nothing at all.
    @discardableResult
    public func quiet() async throws -> RAVEPageQuiet {
        try await run(RAVEPageScripts.quiet, ["quietMs": Self.milliseconds(quietPeriod),
                                              "maxMs": Self.milliseconds(quietLimit)],
                      deadline: quietLimit + .seconds(2))
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Waits for a navigation to finish, if one starts, then for the page to
    /// go quiet.
    private func settle(expectingNavigation: Bool, timeout: Duration) async throws -> RAVEPageInfo {
        try await waitForLoad(expectingNavigation: expectingNavigation, timeout: timeout)
        _ = try? await quiet()
        return try await info()
    }

    /// Waits for a navigation to finish, if one starts. With
    /// `expectingNavigation` a load gets a second to begin; otherwise a
    /// short grace catches the one a click may have triggered.
    /// Returns whether a load happened.
    @discardableResult
    private func waitForLoad(expectingNavigation: Bool, timeout: Duration) async throws -> Bool {
        let view = try view()
        let clock = ContinuousClock()
        let start = clock.now
        let grace: Duration = expectingNavigation ? .seconds(1) : .milliseconds(300)
        var sawLoading = view.isLoading
        while clock.now - start < timeout {
            try await Task.sleep(for: .milliseconds(50))
            if view.isLoading { sawLoading = true; continue }
            if sawLoading || clock.now - start >= grace { break }
        }
        if view.isLoading { throw RAVEPageError.timeout("page still loading after \(timeout)") }
        return sawLoading
    }

    private static let readabilitySource: String? = Bundle.module
        .url(forResource: "Readability", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    private func loadReadability() async throws {
        let view = try view()
        let loaded = try await Self.withDeadline(scriptDeadline) { [world] in
            try await view.callAsyncJavaScript(
                RAVEPageScripts.hasReadability, arguments: [:], in: nil, contentWorld: world) as? Bool
        }
        guard loaded != true else { return }
        guard let source = Self.readabilitySource else { throw RAVEPageError.script("Readability.js is not in the bundle") }
        // A script, not a function body, so its `function Readability` lands
        // on the world's global. The trailing `true` gives WebKit a value it
        // can hand back.
        do {
            try await Self.withDeadline(scriptDeadline) { [world] in
                _ = try await view.evaluateJavaScript(source + "\n;true;", in: nil, contentWorld: world)
            }
        } catch {
            throw Self.pageError(error)
        }
    }

    /// The longest any one script may take, past which the driver stops
    /// waiting for it. WebKit can leave a call unanswered for good, seen on
    /// visionOS when the page navigated while the call was out, and an agent
    /// waiting on it would hang forever.
    public var scriptDeadline: Duration = .seconds(10)

    private func run<T: Decodable>(_ script: String, _ arguments: [String: Any] = [:],
                                   deadline: Duration? = nil) async throws -> T {
        let view = try view()
        let json = try await Self.withDeadline(deadline ?? scriptDeadline) { [world] in
            let result: Any?
            do {
                result = try await view.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: world)
            } catch {
                throw Self.pageError(error)
            }
            guard let json = result as? String else { throw RAVEPageError.badResult(String(describing: result)) }
            return json
        }
        guard let data = json.data(using: .utf8) else {
            throw RAVEPageError.badResult(json)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RAVEPageError.badResult("\(error) in \(json.prefix(300))")
        }
    }

    /// Whichever comes first: `body`'s result or a timeout. Unstructured on
    /// purpose: a task group would wait for the abandoned call on its way
    /// out, and WebKit's calls don't answer cancellation.
    private static func withDeadline<T: Sendable>(_ limit: Duration,
                                                  _ body: @escaping @MainActor () async throws -> T) async throws -> T {
        let once = RAVEOnce()
        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                do {
                    let value = try await body()
                    if once.claim() { continuation.resume(returning: value) }
                } catch {
                    if once.claim() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(for: limit)
                if once.claim() { continuation.resume(throwing: RAVEPageError.timeout("the page did not answer within \(limit)")) }
            }
        }
    }

    private static func pageError(_ error: Error) -> RAVEPageError {
        let info = (error as NSError).userInfo
        if let message = info["WKJavaScriptExceptionMessage"] as? String {
            return .script(message.replacingOccurrences(of: "Error: ", with: ""))
        }
        return .script(error.localizedDescription)
    }
}

/// True for the first caller only.
private final class RAVEOnce: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
#endif
