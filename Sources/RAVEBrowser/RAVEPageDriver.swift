//
//  RAVEPageDriver.swift
//  RAVEBrowser
//
//  A Chrome-MCP-sized tool surface over a WKWebView an app already shows:
//  navigate, read, list elements, snapshot (optionally with each element's
//  ref drawn on it), click, type, press keys, hover, drag, select, check,
//  upload, scroll, find, wait, dismiss overlays, and — where the app allows
//  it — run JavaScript. What a language model needs to use a page without
//  anything site-specific: it looks at the marked snapshot or reads the
//  outline and answers with refs.
//
//  The driver borrows the view and claims nothing on it: no navigation or UI
//  delegate (the host app, Raven's BrowserTab for one, owns those), no user
//  scripts. Loading is watched through `isLoading`, and every script runs in
//  its own content world, out of the page's reach. What needs more than that
//  (console and network capture, dialogs, frames) is `RAVEPageSupport`, a
//  page feature the host installs; tools that need it say so when it is
//  absent.
//
//  Running the caller's JavaScript is tiered (`RAVEScriptPolicy`): the app
//  decides when it makes the driver, and the default is never. Page text
//  reaches the model, and a model that can be talked into running script can
//  do anything the page can.
//
//  Input is real on the Mac and synthetic elsewhere. On macOS, a web view in
//  a window gets `NSEvent`s (`RAVENativeInput`), so the page sees trusted
//  clicks, keys and typing. visionOS and iOS have no public way to inject a
//  touch, so there the events come from script and are untrusted; the few
//  sites that check `isTrusted` ignore them. A right click and a press on a
//  `<select>` are synthetic everywhere, since AppKit answers both with a menu
//  it tracks modally.
//

#if canImport(WebKit)
import Foundation
import UniformTypeIdentifiers
import WebKit

public enum RAVEPageError: Error, LocalizedError, Equatable {
    /// The web view has been deallocated.
    case noWebView
    /// The page threw; the message says why ("stale ref 4: …").
    case script(String)
    case timeout(String)
    case snapshotFailed(String)
    case badResult(String)
    /// This driver's `RAVEScriptPolicy` is `never`.
    case scriptingNotAllowed
    /// The policy asked and the answer was no.
    case scriptDeclined
    /// The call itself was wrong: a missing file, a bad key name.
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .noWebView: "the web view is gone"
        case .script(let message): message
        case .timeout(let what): "timed out: \(what)"
        case .snapshotFailed(let why): "snapshot failed: \(why)"
        case .badResult(let why): "unexpected script result: \(why)"
        case .scriptingNotAllowed: "running JavaScript is not allowed here"
        case .scriptDeclined: "running JavaScript on this page was declined"
        case .invalidArgument(let why): why
        }
    }
}

@MainActor
public final class RAVEPageDriver {
    public private(set) weak var webView: WKWebView?
    public let world: WKContentWorld
    /// Whether `evaluate` may run, decided by whoever made the driver.
    public let scripting: RAVEScriptPolicy

    public enum InputMode: String, Sendable {
        /// Native on the Mac whenever the web view is in a window; synthetic
        /// otherwise.
        case automatic
        /// Script events only, everywhere.
        case synthetic
    }

    /// How clicks, keys and typing reach the page.
    public var input: InputMode = .automatic

    public enum MouseButton: String, Sendable, CaseIterable { case left, middle, right }

    /// One end of a drag: an element, or a point in viewport CSS pixels.
    public enum Point: Sendable, Equatable {
        case ref(Int)
        case at(x: Double, y: Double)
    }

    /// - Parameter scripting: whether `evaluate` runs. `never` unless the app
    ///   says otherwise; see `RAVEScriptPolicy` for who should say what.
    public init(webView: WKWebView, worldName: String = "RAVEBrowser", scripting: RAVEScriptPolicy = .never) {
        self.webView = webView
        self.world = .world(name: worldName)
        self.scripting = scripting
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

    /// Waits for the page's text to contain `text`, or with `gone` to stop
    /// containing it: a result that loads after the click that asked for it.
    public func wait(forText text: String, gone: Bool = false, timeout: Duration = .seconds(10)) async throws -> RAVEPageWait {
        try await run(RAVEPageScripts.waitForText, ["text": text, "gone": gone, "maxMs": Self.milliseconds(timeout)],
                      deadline: timeout + .seconds(2))
    }

    // MARK: - Acting

    /// Clicks an element: a real click on the Mac, a synthetic one elsewhere
    /// (and for a right click, or a press on a `<select>`).
    @discardableResult
    public func click(ref: Int, button: MouseButton = .left, count: Int = 1,
                      modifiers: RAVEPageModifiers = []) async throws -> RAVEPageAction {
        try await press(ref: ref, x: nil, y: nil, button: button, count: count, modifiers: modifiers)
    }

    /// Clicks whatever is at a point in viewport CSS pixels: the fallback
    /// for a model that answers with coordinates.
    @discardableResult
    public func click(x: Double, y: Double, button: MouseButton = .left, count: Int = 1,
                      modifiers: RAVEPageModifiers = []) async throws -> RAVEPageAction {
        try await press(ref: nil, x: x, y: y, button: button, count: count, modifiers: modifiers)
    }

    /// Replaces (or with `append`, extends) a field's text; `submit` then
    /// presses Enter and submits its form if the page did not stop it.
    ///
    /// On the Mac the field is clicked and the text inserted as typing
    /// inserts it, so the page sees trusted input; if nothing lands (a field
    /// that ignores it), the value is set the synthetic way instead.
    @discardableResult
    public func type(ref: Int, text: String, append: Bool = false, submit: Bool = false) async throws -> RAVEPageAction {
        #if os(macOS)
        if let view = nativeView() {
            let target: RAVEPageTarget = try await run(RAVEPageScripts.target, ["ref": ref, "x": NSNull(), "y": NSNull()])
            if target.covered == nil, !target.select {
                RAVENativeInput.click(view, at: windowPoint(target, in: view))
            }
            let field: RAVEPageFieldState = try await run(RAVEPageScripts.focusField, ["ref": ref, "append": append])
            RAVENativeInput.insert(view, text: text)
            let after: RAVEPageFieldState = try await run(RAVEPageScripts.fieldValue, ["ref": ref])
            if after.value == field.value, !text.isEmpty {
                // Nothing landed: set it the way a script can.
                var action: RAVEPageAction = try await run(RAVEPageScripts.type,
                                                           ["ref": ref, "text": text, "append": append, "submit": submit])
                action.via = "synthetic"
                action.note = "the field ignored typed input, so its value was set directly"
                return try await settle(after: action, followed: false)
            }
            if submit, let enter = try? RAVEPageKeyChord.parse("Enter") { RAVENativeInput.press(view, enter) }
            return try await settle(after: RAVEPageAction(target: field.target, via: "native"), followed: false)
        }
        #endif
        var action: RAVEPageAction = try await run(RAVEPageScripts.type,
                                                   ["ref": ref, "text": text, "append": append, "submit": submit])
        action.via = "synthetic"
        return try await settle(after: action, followed: false)
    }

    /// Presses keys (`Enter`, `Shift+Tab`, `Meta+a`, `ArrowDown ArrowDown
    /// Enter`) in whatever has focus, after focusing `ref` if one is given.
    @discardableResult
    public func press(keys: String, ref: Int? = nil) async throws -> RAVEPageAction {
        let chords: [RAVEPageKeyChord]
        do {
            chords = try RAVEPageKeyChord.parseSequence(keys)
        } catch {
            throw RAVEPageError.invalidArgument(error.localizedDescription)
        }
        #if os(macOS)
        if let view = nativeView() {
            // Focus only: a press on a button to focus it would press it.
            let focused: RAVEPageKeysResult = try await run(RAVEPageScripts.keys, ["ref": ref ?? NSNull(), "keys": []])
            for chord in chords { RAVENativeInput.press(view, chord) }
            return try await settle(after: RAVEPageAction(target: focused.target, via: "native"), followed: false)
        }
        #endif
        let pressed: RAVEPageKeysResult = try await run(RAVEPageScripts.keys,
                                                        ["ref": ref ?? NSNull(), "keys": chords.map(\.scriptValue)])
        return try await settle(after: RAVEPageAction(target: pressed.target, via: "synthetic"), followed: false)
    }

    /// Moves the pointer onto an element or a point, for menus and tooltips
    /// that open on hover.
    @discardableResult
    public func hover(_ point: Point) async throws -> RAVEPageAction {
        let (ref, x, y) = point.arguments
        var note: String?
        #if os(macOS)
        if let view = nativeView() {
            let target: RAVEPageTarget = try await run(RAVEPageScripts.target, ["ref": ref, "x": x, "y": y])
            RAVENativeInput.move(view, to: windowPoint(target, in: view))
            if await sawNativeEvent("mousemove") {
                return try await settle(after: RAVEPageAction(target: target.target, via: "native"), followed: false)
            }
            note = "WebKit ignores a real pointer move into a window that is not key, so it was hovered synthetically"
        }
        #endif
        let hovered: RAVEPageKeysResult = try await run(RAVEPageScripts.hover, ["ref": ref, "x": x, "y": y])
        return try await settle(after: RAVEPageAction(target: hovered.target, via: "synthetic", note: note), followed: false)
    }

    /// Whether the page saw a real event of `type` since the last `target`
    /// script, waiting briefly: WebKit delivers input after the call that
    /// sent it returns.
    private func sawNativeEvent(_ type: String, within limit: Duration = .milliseconds(400)) async -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < limit {
            if let seen: [String: Bool] = try? await run(RAVEPageScripts.seen), seen[type] == true { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Drags from one element or point to another. An element marked
    /// `draggable` gets HTML drag and drop (synthetic everywhere: AppKit's
    /// dragging session follows only the real mouse); anything else a pointer
    /// drag, real on the Mac.
    @discardableResult
    public func drag(from: Point, to: Point, steps: Int = 12) async throws -> RAVEPageDrag {
        let (fromRef, fromX, fromY) = from.arguments
        let (toRef, toX, toY) = to.arguments
        #if os(macOS)
        if let view = nativeView() {
            let source: RAVEPageTarget = try await run(RAVEPageScripts.target, ["ref": fromRef, "x": fromX, "y": fromY])
            if !source.draggable {
                let destination: RAVEPageTarget = try await run(RAVEPageScripts.target, ["ref": toRef, "x": toX, "y": toY])
                RAVENativeInput.drag(view, from: windowPoint(source, in: view), to: windowPoint(destination, in: view),
                                     steps: steps)
                var drag = RAVEPageDrag(from: source.target, to: destination.target, html5: false, dropped: true)
                drag.via = "native"
                return try await settle(after: drag)
            }
        }
        #endif
        var drag: RAVEPageDrag = try await run(RAVEPageScripts.drag, [
            "fromRef": fromRef, "fromX": fromX, "fromY": fromY, "toRef": toRef, "toX": toX, "toY": toY, "steps": steps,
        ])
        drag.via = "synthetic"
        return try await settle(after: drag)
    }

    /// Chooses options of a `<select>` by value or visible text.
    @discardableResult
    public func select(ref: Int, values: [String]) async throws -> RAVEPageSelection {
        guard !values.isEmpty else { throw RAVEPageError.invalidArgument("select needs at least one option") }
        var selection: RAVEPageSelection = try await run(RAVEPageScripts.selectOption, ["ref": ref, "values": values])
        let action = try await settle(after: RAVEPageAction(target: selection.target), followed: false)
        selection.info = action.info
        selection.changes = action.changes
        return selection
    }

    /// Sets a checkbox, radio button or switch to `checked`, clicking it only
    /// if it is not already.
    @discardableResult
    public func check(ref: Int, checked: Bool = true) async throws -> RAVEPageCheck {
        let before: RAVEPageCheckState = try await run(RAVEPageScripts.checkState, ["ref": ref])
        guard before.checked != checked else {
            return RAVEPageCheck(target: before.target, checked: before.checked, changed: false, info: try await info())
        }
        if before.disabled == true { throw RAVEPageError.script("ref \(ref) is \(before.target), which is disabled") }
        let action = try await click(ref: ref)
        let after: RAVEPageCheckState? = try? await run(RAVEPageScripts.checkState, ["ref": ref])
        return RAVEPageCheck(target: before.target, checked: after?.checked ?? checked,
                             changed: (after?.checked ?? checked) != before.checked, info: action.info, via: action.via)
    }

    /// The largest total `upload` passes into the page, which holds every
    /// file in memory as it builds them.
    public static let uploadLimit = 25 * 1024 * 1024

    /// Puts files into a file field — the ref, one inside it, or its
    /// label's — or drops them on a drop zone. No file picker opens.
    @discardableResult
    public func upload(ref: Int, files: [URL]) async throws -> RAVEPageUpload {
        guard !files.isEmpty else { throw RAVEPageError.invalidArgument("upload needs at least one file") }
        var payload: [[String: Any]] = []
        var total = 0
        for file in files {
            let data: Data
            do {
                data = try Data(contentsOf: file)
            } catch {
                throw RAVEPageError.invalidArgument("cannot read \(file.path): \(error.localizedDescription)")
            }
            total += data.count
            guard total <= Self.uploadLimit else {
                throw RAVEPageError.invalidArgument("the files come to more than \(Self.uploadLimit / 1024 / 1024) MB")
            }
            let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            payload.append(["name": file.lastPathComponent, "type": type, "data": data.base64EncodedString()])
        }
        var upload: RAVEPageUpload = try await run(RAVEPageScripts.upload, ["ref": ref, "files": payload],
                                                   deadline: .seconds(30))
        upload.files = files.map(\.lastPathComponent)
        let action = try await settle(after: RAVEPageAction(target: upload.target), followed: false)
        upload.info = action.info
        upload.changes = action.changes
        return upload
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

    // MARK: - JavaScript

    /// Runs the caller's JavaScript in the page's own world, as the page:
    /// an expression (awaited, so a promise works) or statements ending in
    /// `return`. The result comes back as JSON, with elements described
    /// rather than serialised and cycles cut.
    ///
    /// Whether it runs at all is this driver's `scripting` policy.
    public func evaluate(_ source: String, maxCharacters: Int = 20_000,
                         timeout: Duration = .seconds(30)) async throws -> RAVEPageEvaluation {
        let view = try view()
        switch scripting {
        case .never:
            throw RAVEPageError.scriptingNotAllowed
        case .always:
            break
        case .ask(let consent):
            let url = view.url
            let request = RAVEScriptRequest(origin: url.map(Self.origin) ?? "about:blank",
                                            url: url?.absoluteString ?? "", source: source)
            guard await consent.allows(request) else { throw RAVEPageError.scriptDeclined }
        }
        // Parsed here first, by the same engine: an expression is awaited and
        // its value returned, and statements become a function's body. Never
        // run twice to find out which it was — the code has side effects.
        let asExpression = RAVEScriptSyntax.error(compiling: "return await (\n\(source)\n);") == nil
        if !asExpression, let syntax = RAVEScriptSyntax.error(compiling: source) {
            throw RAVEPageError.script(syntax)
        }
        let body = RAVEPageScripts.evaluation(source, asExpression: asExpression)
        let json = try await Self.withDeadline(timeout) {
            let result: Any?
            do {
                result = try await view.callAsyncJavaScript(body, arguments: ["__ravenMax": maxCharacters],
                                                            in: nil, contentWorld: .page)
            } catch {
                throw Self.pageError(error)
            }
            guard let json = result as? String else { throw RAVEPageError.badResult(String(describing: result)) }
            return json
        }
        var evaluation: RAVEPageEvaluation = try Self.decode(json)
        evaluation.mode = asExpression ? "expression" : "statements"
        return evaluation
    }

    /// `https://example.com:8443`: who a script would run as.
    static func origin(_ url: URL) -> String {
        guard let scheme = url.scheme, let host = url.host() else { return url.absoluteString }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    // MARK: - Plumbing

    private func view() throws -> WKWebView {
        guard let webView else { throw RAVEPageError.noWebView }
        return webView
    }

    #if os(macOS)
    /// The web view, when real input can reach it.
    private func nativeView() -> WKWebView? {
        guard input != .synthetic, let webView, RAVENativeInput.isAvailable(for: webView) else { return nil }
        return webView
    }

    private func windowPoint(_ target: RAVEPageTarget, in view: WKWebView) -> NSPoint {
        RAVENativeInput.windowPoint(css: CGPoint(x: target.x, y: target.y),
                                    viewport: CGSize(width: target.width, height: target.height), in: view)
    }
    #endif

    private func press(ref: Int?, x: Double?, y: Double?, button: MouseButton, count: Int,
                       modifiers: RAVEPageModifiers) async throws -> RAVEPageAction {
        var note: String?
        #if os(macOS)
        if let view = nativeView(), button != .right {
            let target: RAVEPageTarget = try await run(RAVEPageScripts.target,
                                                       ["ref": ref ?? NSNull(), "x": x ?? NSNull(), "y": y ?? NSNull()])
            // A web view with no UI delegate drops new-window navigations, so
            // a link that would open one is followed in place.
            if let link = target.newWindow, view.uiDelegate == nil, button == .left, let url = URL(string: link) {
                view.load(URLRequest(url: url))
                return try await settle(after: RAVEPageAction(target: target.target, followed: link, via: "native"),
                                        followed: true)
            }
            if target.select {
                note = "a <select> opens a menu that blocks the app, so it was pressed synthetically; use select to choose an option"
            } else if let covered = target.covered, ref != nil {
                // A real click lands on what is on top. The element was asked
                // for, so it gets a synthetic one and the model hears why.
                note = "covered by \(covered), so it was clicked synthetically"
            } else {
                RAVENativeInput.click(view, at: windowPoint(target, in: view),
                                      button: button == .middle ? .middle : .left, count: count, modifiers: modifiers)
                return try await settle(after: RAVEPageAction(target: target.target, via: "native"), followed: false)
            }
        }
        #endif
        var action: RAVEPageAction = try await run(RAVEPageScripts.click, [
            "ref": ref ?? NSNull(), "x": x ?? NSNull(), "y": y ?? NSNull(), "follow": true,
            "button": button == .right ? 2 : button == .middle ? 1 : 0, "count": max(1, count),
            "shift": modifiers.contains(.shift), "ctrl": modifiers.contains(.control),
            "alt": modifiers.contains(.option), "meta": modifiers.contains(.command),
        ])
        action.via = "synthetic"
        action.note = note
        return try await settle(after: action, followed: action.followed != nil)
    }

    /// After an action: waits for any navigation it started and for the
    /// document to go quiet, then reports the page.
    private func settle(after action: RAVEPageAction, followed: Bool) async throws -> RAVEPageAction {
        var action = action
        var navigated = try await waitForLoad(expectingNavigation: followed, timeout: .seconds(20)) || followed
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

    private func settle(after drag: RAVEPageDrag) async throws -> RAVEPageDrag {
        var drag = drag
        let action = try await settle(after: RAVEPageAction(target: drag.from), followed: false)
        drag.info = action.info
        drag.changes = action.changes
        return drag
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

    static func milliseconds(_ duration: Duration) -> Int {
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
        return try Self.decode(json)
    }

    private static func decode<T: Decodable>(_ json: String) throws -> T {
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

private extension RAVEPageDriver.Point {
    /// `(ref, x, y)` as script arguments, nulls for what does not apply.
    var arguments: (Any, Any, Any) {
        switch self {
        case .ref(let ref): (ref, NSNull(), NSNull())
        case .at(let x, let y): (NSNull(), x, y)
        }
    }
}

/// True for the first caller only.
private final class RAVEOnce: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
#endif
