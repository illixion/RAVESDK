//
//  RAVEBrowserTools.swift
//  RAVEBrowser
//
//  The page tools as DebugTrace endpoints: one catalog of names, parameters,
//  descriptions and handlers over `RAVEPageDriver`, which every host serves
//  the same way. DebugTrace's registry already is an MCP tool list — typed,
//  validated parameters with "did you mean", one envelope, a hint on every
//  error, images as MCP image content — so a host registers these on a
//  `DebugSurface` and has:
//
//  - spatial-ai-character: `web…` endpoints on its debug server, pointed at
//    the room's screen or the call window by its own `page` argument;
//  - Raven for Mac: its agent harness, an MCP server for coding agents, with
//    tab tools on top (`tabEndpoints`);
//  - any other app with a web view and a debug server.
//
//  What differs per host is passed in, not forked: the name prefix, the
//  parameters every tool takes to find its page (`tab`, or `page`/`wake`),
//  how a call finds its driver, whether JavaScript and local files are
//  offered at all. Whether a script actually runs is still the driver's own
//  `RAVEScriptPolicy`; leaving the tool out is only so a model is not shown a
//  tool that can never work.
//

#if canImport(WebKit)
import DebugTrace
import Foundation
import WebKit

@MainActor
public enum RAVEBrowserTools {
    /// What a tool call acts on.
    public struct Target {
        public var driver: RAVEPageDriver
        /// The tab's `RAVEPageSupport`, for console, network, dialogs and the
        /// events an action reports. Nil where the host has none.
        public var support: RAVEPageSupport?

        public init(driver: RAVEPageDriver, support: RAVEPageSupport? = nil) {
            self.driver = driver
            self.support = support
        }
    }

    public struct Options {
        /// Prepended to every name (`web` → `webClick`); the page tool is the
        /// prefix itself (`web`), or `page` with none.
        public var prefix: String
        /// Parameters every page tool takes, for the host to find its target
        /// (`tab`; spatial-ai-character's `page` and `wake`).
        public var context: [DebugParameter]
        /// Offer `evaluate`. The driver's policy still decides each call.
        public var scripting: Bool
        /// Offer `upload`, which reads files from this machine.
        public var uploads: Bool
        /// Fields the host adds to the page tool's answer (a view's size,
        /// whether a screen is paused).
        public var describe: (@MainActor (Target) async -> [String: JSONValue])?
        /// How `snapshot` is gated: `.screenCapture`, so a device asks the
        /// person, unless the host's server approves everything itself.
        public var snapshotSensitivity: DebugEndpoint.Sensitivity

        public init(prefix: String = "", context: [DebugParameter] = [], scripting: Bool = false, uploads: Bool = false,
                    describe: (@MainActor (Target) async -> [String: JSONValue])? = nil,
                    snapshotSensitivity: DebugEndpoint.Sensitivity = .screenCapture) {
            self.prefix = prefix
            self.context = context
            self.scripting = scripting
            self.uploads = uploads
            self.describe = describe
            self.snapshotSensitivity = snapshotSensitivity
        }

        func name(_ base: String) -> String {
            guard !prefix.isEmpty else { return base }
            return prefix + base.prefix(1).uppercased() + base.dropFirst()
        }

        var pageName: String { prefix.isEmpty ? "page" : prefix }
    }

    public typealias Resolve = @MainActor @Sendable (DebugArguments) async throws -> Target

    // MARK: - Page tools

    public static func endpoints(_ options: Options, resolve: @escaping Resolve) -> [DebugEndpoint] {
        let o = options
        let context = o.context
        let elementsName = o.name("elements")
        let refHint = "refs come from \(elementsName) and go stale when the page changes: call it again"
        var list: [DebugEndpoint] = [
            .untyped(o.pageName, kind: .query,
                     "The page: title, URL, whether it is loading, the viewport and how far it is scrolled.",
                     parameters: context, trace: .never) { arguments in
                try await run(arguments, resolve) { target in
                    var body = try JSONValue(encoding: try await target.driver.info()).objectValue ?? [:]
                    for (key, value) in await o.describe?(target) ?? [:] { body[key] = value }
                    return body.mapValues(\.any)
                }
            },

            .command(o.name("navigate"),
                     "Load `url`, or go back, forward or reload, and wait for the page to finish and settle. Returns the page.",
                     parameters: [
                        .string("url", "an absolute URL (https://…)"),
                        .boolean("back", "go back instead"),
                        .boolean("forward", "go forward instead"),
                        .boolean("reload", "reload instead"),
                     ] + context, timeout: .seconds(60)) { arguments in
                try await act(arguments, resolve) { target in
                    let driver = target.driver
                    if let url = arguments.string("url") {
                        guard let target = URL(string: url), let scheme = target.scheme?.lowercased(),
                              ["http", "https", "about", "file", "data"].contains(scheme) else {
                            throw DebugError.invalidArgument("not a URL: \(url)", hint: "pass an absolute URL, e.g. https://example.com/")
                        }
                        return try await driver.navigate(to: target, timeout: .seconds(45))
                    }
                    if arguments.bool("back") == true { return try await driver.goBack() }
                    if arguments.bool("forward") == true { return try await driver.goForward() }
                    if arguments.bool("reload") == true { return try await driver.reload() }
                    throw DebugError.invalidArgument("nothing to do", hint: "pass url, or back, forward or reload set to true")
                }
            },

            .query(o.name("read"),
                   "The page's text. content (the default) is the article if Readability finds one that is most of the "
                   + "page, else the main content without navigation and sidebars; reader is Readability's article "
                   + "(ignores overlays); main is the main landmark; page is everything rendered. Long text comes in "
                   + "parts: pass `offset` from the last answer's `nextOffset`.",
                   parameters: [
                    .string("mode", "what to read", default: "content", choices: ["content", "reader", "main", "page", "auto"]),
                    .integer("max", "at most this many characters", default: 20_000, range: 100...200_000),
                    .integer("offset", "start this many characters in", default: 0, range: 0...10_000_000),
                   ] + context, trace: .never) { arguments in
                try await run(arguments, resolve) { target in
                    let max = arguments.int("max") ?? 20_000
                    let offset = arguments.int("offset") ?? 0
                    let mode = RAVEPageReading.Mode(rawValue: arguments.string("mode") ?? "content") ?? .content
                    var reading = try await target.driver.read(mode: mode, maxCharacters: offset + max)
                    if offset > 0 { reading.text = String(reading.text.dropFirst(offset)) }
                    return ReadReply(reading: reading, offset: offset)
                }
            },

            .untyped(elementsName, kind: .query,
                     "What can be clicked or typed into, numbered: `outline` is one line per element, `[12] link \"Title\" → url`. "
                     + "The numbers are the `ref` every other tool takes. viewport (the default) is what is on screen and not "
                     + "covered; page is everything. Elements inside iframes are included and say which frame.",
                     parameters: [
                        .string("scope", "viewport: on screen and not covered; page: every element", default: "viewport",
                                choices: ["viewport", "page"]),
                        .integer("limit", "at most this many elements", default: 150, range: 1...2_000),
                     ] + context, trace: .never) { arguments in
                try await run(arguments, resolve) { target in
                    let scope = RAVEPageDriver.Scope(rawValue: arguments.string("scope") ?? "viewport") ?? .viewport
                    let list = try await target.driver.elements(scope: scope, limit: arguments.int("limit") ?? 150)
                    var body = list.raveJSONObject() as? [String: Any] ?? [:]
                    body["outline"] = list.outline()
                    return body
                }
            },

            .raw(o.name("snapshot"), kind: .query,
                 "A JPEG of what the page shows. With `marks`, each element from \(elementsName) has its box and ref drawn "
                 + "on it, so you can pick a ref by looking.",
                 parameters: [
                    .integer("width", "image width in pixels", default: 1024, range: 128...4_096),
                    .boolean("marks", "draw the numbered element boxes", default: false),
                    .integer("quality", "JPEG quality, percent", default: 75, range: 10...100),
                 ] + context, trace: .never, sensitivity: o.snapshotSensitivity, timeout: .seconds(30)) { arguments in
                try await run(arguments, resolve) { target in
                    let marks = arguments.bool("marks") == true ? try await target.driver.elements() : nil
                    let jpeg = try await target.driver.snapshot(width: arguments.int("width") ?? 1024, marks: marks,
                                                                quality: Double(arguments.int("quality") ?? 75) / 100)
                    return DebugResult.binary(jpeg, contentType: "image/jpeg", filename: "page.jpg")
                }
            },

            .command(o.name("click"),
                     "Click an element by `ref`, or a point by `x`,`y` (viewport CSS pixels). Real input on the Mac. Waits for "
                     + "any navigation and for the page to settle, and says what changed and what the page did (dialogs, "
                     + "downloads, new windows, console errors).",
                     parameters: [
                        .integer("ref", "element number from \(elementsName)", range: 1...1_000_000),
                        .number("x", "viewport x in CSS pixels (with y)"),
                        .number("y", "viewport y in CSS pixels (with x)"),
                        .string("button", "which button", default: "left", choices: ["left", "middle", "right"]),
                        .integer("count", "2 for a double click", default: 1, range: 1...3),
                        .string("modifiers", "keys held, joined by +: shift, control, option, command"),
                     ] + context, timeout: .seconds(60)) { arguments in
                try await act(arguments, resolve) { target in
                    let button = RAVEPageDriver.MouseButton(rawValue: arguments.string("button") ?? "left") ?? .left
                    let count = arguments.int("count") ?? 1
                    let modifiers = try modifierArgument(arguments)
                    if let ref = arguments.int("ref") {
                        return try await target.driver.click(ref: ref, button: button, count: count, modifiers: modifiers)
                    }
                    guard let x = arguments.double("x"), let y = arguments.double("y") else {
                        throw DebugError.invalidArgument("pass ref, or x and y", hint: "\(elementsName) lists refs")
                    }
                    return try await target.driver.click(x: x, y: y, button: button, count: count, modifiers: modifiers)
                }
            },

            .command(o.name("type"),
                     "Type into a text field or editable element: replaces its text, or with `append` adds to it; `submit` "
                     + "presses Enter afterwards. Real typing on the Mac.",
                     parameters: [
                        .integer("ref", "field number from \(elementsName)", required: true, range: 1...1_000_000),
                        .string("text", "what to type", required: true),
                        .boolean("append", "add to the field's text instead of replacing it", default: false),
                        .boolean("submit", "press Enter afterwards", default: false),
                     ] + context, timeout: .seconds(60)) { arguments in
                try await act(arguments, resolve) { target in
                    try await target.driver.type(ref: try arguments.requireInt("ref"), text: try arguments.requireString("text"),
                                                 append: arguments.bool("append") == true,
                                                 submit: arguments.bool("submit") == true)
                }
            },

            .command(o.name("keys"),
                     "Press keys in whatever has focus, after focusing `ref` if given. Space-separated presses, + for "
                     + "chords: `Enter`, `Escape`, `Tab`, `Shift+Tab`, `ArrowDown ArrowDown Enter`, `Meta+a`, `Backspace`, `F5`.",
                     parameters: [
                        .string("keys", "the presses", required: true),
                        .integer("ref", "element to focus first", range: 1...1_000_000),
                     ] + context, timeout: .seconds(60)) { arguments in
                try await act(arguments, resolve) { target in
                    try await target.driver.press(keys: try arguments.requireString("keys"), ref: arguments.int("ref"))
                }
            },

            .command(o.name("hover"),
                     "Move the pointer onto an element or a point, for menus and tooltips that open on hover.",
                     parameters: [
                        .integer("ref", "element number from \(elementsName)", range: 1...1_000_000),
                        .number("x", "viewport x in CSS pixels (with y)"),
                        .number("y", "viewport y in CSS pixels (with x)"),
                     ] + context) { arguments in
                try await act(arguments, resolve) { target in
                    try await target.driver.hover(try point(arguments, ref: "ref", x: "x", y: "y", hint: refHint))
                }
            },

            .command(o.name("drag"),
                     "Drag from one element or point to another: a slider, a list to reorder, a file onto a drop zone.",
                     parameters: [
                        .integer("fromRef", "element to drag", range: 1...1_000_000),
                        .number("fromX", "or a point to press, viewport x"),
                        .number("fromY", "and y"),
                        .integer("toRef", "element to drop on", range: 1...1_000_000),
                        .number("toX", "or a point to release at, viewport x"),
                        .number("toY", "and y"),
                        .integer("steps", "pointer moves along the way", default: 12, range: 1...200),
                     ] + context, timeout: .seconds(60)) { arguments in
                try await act(arguments, resolve) { target in
                    try await target.driver.drag(from: try point(arguments, ref: "fromRef", x: "fromX", y: "fromY", hint: refHint),
                                                 to: try point(arguments, ref: "toRef", x: "toX", y: "toY", hint: refHint),
                                                 steps: arguments.int("steps") ?? 12)
                }
            },

            .command(o.name("select"),
                     "Choose an option of a dropdown (<select>) by its value or visible text; several, one per line, for a "
                     + "multiple one. For a custom dropdown, click it open and click the option instead.",
                     parameters: [
                        .integer("ref", "the <select> from \(elementsName)", required: true, range: 1...1_000_000),
                        .string("option", "the option's text or value; one per line for several", required: true),
                     ] + context) { arguments in
                try await act(arguments, resolve) { target in
                    let options = try arguments.requireString("option").split(separator: "\n").map(String.init)
                    return try await target.driver.select(ref: try arguments.requireInt("ref"), values: options)
                }
            },

            .command(o.name("check"),
                     "Set a checkbox, radio button or switch on (or off with checked=false); clicks only if it is not already.",
                     parameters: [
                        .integer("ref", "element number from \(elementsName)", required: true, range: 1...1_000_000),
                        .boolean("checked", "the state wanted", default: true),
                     ] + context) { arguments in
                try await act(arguments, resolve) { target in
                    try await target.driver.check(ref: try arguments.requireInt("ref"), checked: arguments.bool("checked") ?? true)
                }
            },

            .command(o.name("scroll"),
                     "Scroll the page: an element into view by `ref`, to the top or bottom, or `by` a number of viewports "
                     + "(negative is up; default 0.8 down). An app-like page with its own scrolling pane scrolls that.",
                     parameters: [
                        .integer("ref", "element to bring into view", range: 1...1_000_000),
                        .string("to", "an edge", choices: ["top", "bottom"]),
                        .number("by", "viewports; negative is up", range: -100...100),
                     ] + context) { arguments in
                try await run(arguments, resolve) { target in
                    if let ref = arguments.int("ref") { return try await target.driver.scroll(toRef: ref) }
                    if let edge = arguments.string("to").flatMap(RAVEPageDriver.Edge.init(rawValue:)) {
                        return try await target.driver.scroll(to: edge)
                    }
                    return try await target.driver.scroll(by: arguments.double("by") ?? 0.8)
                }
            },

            .command(o.name("find"),
                     "Find text on the page: how many matches, the lines around the first few, and the `index`th scrolled into view.",
                     parameters: [
                        .string("text", "text to find, case-insensitive", required: true),
                        .integer("index", "which match to scroll to, from 0", default: 0, range: 0...100_000),
                     ] + context) { arguments in
                try await run(arguments, resolve) { target in
                    try await target.driver.find(try arguments.requireString("text"), index: arguments.int("index") ?? 0)
                }
            },

            .command(o.name("wait"),
                     "Wait for text to appear on the page (or, with gone, to go away), up to `seconds`; or with no text, "
                     + "just wait that long.",
                     parameters: [
                        .string("text", "text to wait for, case-insensitive"),
                        .boolean("gone", "wait for the text to disappear instead", default: false),
                        .number("seconds", "the most to wait", default: 10, range: 0.1...60),
                     ] + context, timeout: .seconds(70)) { arguments in
                try await run(arguments, resolve) { target in
                    let seconds = arguments.double("seconds") ?? 10
                    guard let text = arguments.string("text"), !text.isEmpty else {
                        try await Task.sleep(for: .seconds(seconds))
                        return RAVEPageWait(met: true, waited: Int(seconds * 1000), leaving: nil)
                    }
                    return try await target.driver.wait(forText: text, gone: arguments.bool("gone") == true,
                                                        timeout: .seconds(seconds))
                }
            },

            .command(o.name("overlays"),
                     "Hide cookie banners, sign-up walls and other layers covering the page, and undo their scroll lock. "
                     + "A consent banner offering to decline is declined. Says what it hid.",
                     parameters: context) { arguments in
                try await act(arguments, resolve) { target in try await target.driver.dismissOverlays() }
            },

            .query(o.name("frames"),
                   "The page's iframes: id (for evaluate's `frame`), address, and where each is on screen.",
                   parameters: context, trace: .never) { arguments in
                try await run(arguments, resolve) { target in FramesReply(frames: await target.driver.frames()) }
            },

            .query(o.name("console"),
                   "The page's console messages and uncaught errors, newest last, across its navigations.",
                   parameters: [
                    .string("level", "which messages", default: "all", choices: ["all", "error", "warn"]),
                    .string("contains", "only messages containing this text, case-insensitive"),
                    .integer("limit", "at most this many, the newest", default: 100, range: 1...1_000),
                    .boolean("clear", "empty the list after reading", default: false),
                   ] + context, trace: .never) { arguments in
                try await run(arguments, resolve) { target in
                    let support = try requireSupport(target, "console")
                    let level = arguments.string("level") ?? "all"
                    let needle = arguments.string("contains")?.lowercased()
                    let entries = support.console.filter { entry in
                        (level == "all" || entry.level == level || (level == "warn" && entry.level == "error"))
                            && (needle.map { entry.text.lowercased().contains($0) } ?? true)
                    }
                    let reply = ListReply(entries: Array(entries.suffix(arguments.int("limit") ?? 100)), total: entries.count)
                    if arguments.bool("clear") == true { support.clearConsole() }
                    return reply
                }
            },

            .query(o.name("network"),
                   "Requests the page made, newest last: documents, fetch and XHR with method and status, and every other "
                   + "resource with its timing. Response bodies are not kept.",
                   parameters: [
                    .string("contains", "only URLs containing this text, case-insensitive"),
                    .boolean("failed", "only failed requests and 4xx/5xx statuses", default: false),
                    .string("type", "only this kind: document, fetch, xhr, script, img, css, link…"),
                    .integer("limit", "at most this many, the newest", default: 100, range: 1...1_000),
                    .boolean("clear", "empty the list after reading", default: false),
                   ] + context, trace: .never) { arguments in
                try await run(arguments, resolve) { target in
                    let support = try requireSupport(target, "network")
                    let needle = arguments.string("contains")?.lowercased()
                    let failedOnly = arguments.bool("failed") == true
                    let type = arguments.string("type")?.lowercased()
                    let entries = support.network.filter { entry in
                        (needle.map { entry.url.lowercased().contains($0) } ?? true)
                            && (!failedOnly || entry.error != nil || (entry.status ?? 0) >= 400)
                            && (type.map { entry.type.lowercased() == $0 } ?? true)
                    }
                    let reply = ListReply(entries: Array(entries.suffix(arguments.int("limit") ?? 100)), total: entries.count)
                    if arguments.bool("clear") == true { support.clearNetwork() }
                    return reply
                }
            },

            .command(o.name("dialog"),
                     "How to answer the page's next JavaScript dialog (alert, confirm, prompt). Without this, confirm and "
                     + "prompt are cancelled. Applies once; then do the action that opens it. Also lists recent dialogs.",
                     parameters: [
                        .boolean("accept", "OK (true) or Cancel (false)", required: true),
                        .string("text", "for a prompt: the text to answer with"),
                     ] + context) { arguments in
                try await run(arguments, resolve) { target in
                    let support = try requireSupport(target, "dialog")
                    let accept = try arguments.requireBool("accept")
                    support.answerNextDialog(accept ? .accept(text: arguments.string("text")) : .dismiss)
                    return EventsReply(armed: accept ? "the next dialog will be answered OK" : "the next dialog will be cancelled",
                                       events: support.events.filter { $0.kind == "dialog" }.suffix(10).map(\.text))
                }
            },

            .query(o.name("downloads"),
                   "Downloads the page started: where each was saved, or why it failed.",
                   parameters: context, trace: .never) { arguments in
                try await run(arguments, resolve) { target in
                    let support = try requireSupport(target, "downloads")
                    return EventsReply(armed: support.downloadDirectory.map { "downloads go to \($0.path)" } ?? "downloads are off",
                                       events: support.events.filter { $0.kind == "download" }.suffix(50).map(\.text))
                }
            },
        ]

        if o.uploads {
            list.append(.command(o.name("upload"),
                                 "Put files from this computer into a file field (the ref, a field inside it, or its label's), "
                                 + "or drop them on a drop zone. No file picker opens. Up to 25 MB in all.",
                                 parameters: [
                                    .integer("ref", "the file field or drop zone from \(elementsName)", required: true,
                                             range: 1...1_000_000),
                                    .string("paths", "absolute paths, one per line", required: true),
                                 ] + context, timeout: .seconds(60)) { arguments in
                try await act(arguments, resolve) { target in
                    let paths = try arguments.requireString("paths").split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    let files = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                    // Staged too, for a page that opens its file chooser itself.
                    target.support?.stagedFiles = files
                    return try await target.driver.upload(ref: try arguments.requireInt("ref"), files: files)
                }
            })
        }

        if o.scripting {
            list.append(.command(o.name("evaluate"),
                                 "Run JavaScript in the page, as the page: an expression (a promise is awaited) or statements "
                                 + "ending in `return`. The value comes back as JSON; elements are described, not serialised.",
                                 parameters: [
                                    .string("script", "the JavaScript", required: true),
                                    .string("frame", "an iframe's id from \(o.name("frames")), to run it there"),
                                    .integer("max", "cut the result to this many characters", default: 20_000,
                                             range: 100...1_000_000),
                                 ] + context, timeout: .seconds(70)) { arguments in
                try await act(arguments, resolve) { target in
                    let evaluation = try await target.driver.evaluate(try arguments.requireString("script"),
                                                                      frame: arguments.string("frame"),
                                                                      maxCharacters: arguments.int("max") ?? 20_000,
                                                                      timeout: .seconds(60))
                    return EvaluationReply(evaluation)
                }
            })
        }
        return list
    }

    // MARK: - Tab tools

    /// One tab, as the tab tools list it.
    public struct Tab: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var url: String
        public var active: Bool
        public var loading: Bool
        /// `shared` (the person's profile, logins and all) or a throwaway
        /// profile's name.
        public var profile: String

        public init(id: String, title: String, url: String, active: Bool, loading: Bool, profile: String) {
            self.id = id
            self.title = title
            self.url = url
            self.active = active
            self.loading = loading
            self.profile = profile
        }
    }

    /// The host's tabs, for the tab tools.
    @MainActor
    public protocol TabHost: AnyObject {
        func tabs() -> [Tab]
        /// - Parameter profile: nil or `shared` for the person's profile,
        ///   `throwaway` for a new empty one, or an earlier throwaway's name to
        ///   share its cookies.
        func openTab(url: URL?, profile: String?, background: Bool) async throws -> Tab
        func closeTab(_ id: String) throws
        func selectTab(_ id: String) throws
        /// Resizes the window the tabs are in; returns the new viewport size.
        func resize(width: Int, height: Int) throws -> [String: Int]
    }

    public static func tabEndpoints(prefix: String = "", host: TabHost) -> [DebugEndpoint] {
        let o = Options(prefix: prefix)
        return [
            .query(o.name("tabs"), "The tabs you can use: id, title, address, which is active, and their profile.",
                   trace: .never) { [weak host] _ in
                guard let host else { throw DebugError.unavailable("the browser is gone") }
                return TabsReply(tabs: host.tabs())
            },
            .command(o.name("tabOpen"),
                     "Open a tab, at `url` or blank, and make it the one the other tools act on (unless background). profile "
                     + "shared (default) is the person's: logged in where they are. throwaway is a new, empty profile that "
                     + "keeps nothing; pass its name back to open more tabs in it.",
                     parameters: [
                        .string("url", "an absolute URL"),
                        .string("profile", "shared, throwaway, or a throwaway profile's name", default: "shared"),
                        .boolean("background", "open it without making it the active tab", default: false),
                     ], timeout: .seconds(60)) { [weak host] arguments in
                guard let host else { throw DebugError.unavailable("the browser is gone") }
                let url = try arguments.string("url").map { text -> URL in
                    guard let url = URL(string: text), url.scheme != nil else {
                        throw DebugError.invalidArgument("not a URL: \(text)", hint: "pass an absolute URL, e.g. https://example.com/")
                    }
                    return url
                }
                return try await host.openTab(url: url, profile: arguments.string("profile"),
                                              background: arguments.bool("background") == true)
            },
            .command(o.name("tabClose"), "Close a tab.",
                     parameters: [.string("tab", "its id from \(o.name("tabs"))", required: true)]) { [weak host] arguments in
                guard let host else { throw DebugError.unavailable("the browser is gone") }
                try host.closeTab(try arguments.requireString("tab"))
                return TabsReply(tabs: host.tabs())
            },
            .command(o.name("tabSelect"), "Make a tab the one the other tools act on.",
                     parameters: [.string("tab", "its id from \(o.name("tabs"))", required: true)]) { [weak host] arguments in
                guard let host else { throw DebugError.unavailable("the browser is gone") }
                try host.selectTab(try arguments.requireString("tab"))
                return TabsReply(tabs: host.tabs())
            },
            .command(o.name("resize"), "Resize the browser window, to see a page at another size.",
                     parameters: [
                        .integer("width", "window content width in points", required: true, range: 320...7_680),
                        .integer("height", "window content height in points", required: true, range: 240...4_320),
                     ]) { [weak host] arguments in
                guard let host else { throw DebugError.unavailable("the browser is gone") }
                return try host.resize(width: try arguments.requireInt("width"), height: try arguments.requireInt("height"))
            },
        ]
    }

    // MARK: - Plumbing

    /// Runs a tool against its target, turning a driver error into one that
    /// says what to do.
    static func run<Output>(_ arguments: DebugArguments, _ resolve: Resolve,
                            _ body: @MainActor (Target) async throws -> Output) async throws -> Output {
        let target = try await resolve(arguments)
        do {
            return try await body(target)
        } catch let error as DebugError {
            throw error
        } catch let error as RAVEPageError {
            throw debugError(error)
        } catch let error as RAVEPageKeyError {
            throw DebugError.invalidArgument(error.message, hint: "keys look like Enter, Shift+Tab, Meta+a, ArrowDown")
        } catch is CancellationError {
            throw DebugError(.timeout, "the call was cancelled", hint: "the page may be busy; try again")
        } catch {
            throw DebugError.failedPrecondition(error.localizedDescription, hint: "call the page tool to see what is loaded")
        }
    }

    /// An action: also reports what the page did meanwhile (dialogs,
    /// downloads, new windows, console errors), when the host captures it.
    static func act<Output: Encodable>(_ arguments: DebugArguments, _ resolve: Resolve,
                                       _ body: @MainActor (Target) async throws -> Output) async throws -> WithEvents<Output> {
        var support: RAVEPageSupport?
        var mark = 0
        let output = try await run(arguments, resolve) { target in
            support = target.support
            mark = target.support?.lastSequence ?? 0
            return try await body(target)
        }
        return WithEvents(value: output, events: support?.events(after: mark).map { "\($0.kind): \($0.text)" } ?? [])
    }

    /// A driver error as one that tells a model what to do next, for a host's
    /// own tools over the driver.
    public static func debugError(_ error: RAVEPageError) -> DebugError {
        switch error {
        case .noWebView:
            return .failedPrecondition("the tab has no page", hint: "navigate somewhere first, or pick another tab")
        case .timeout(let what):
            return DebugError(.timeout, "the page timed out: \(what)", hint: "call the page tool to see what is loaded, then retry")
        case .script(let message):
            if message.contains("is gone from the page") || message.hasPrefix("ref ") {
                return .failedPrecondition(message, hint: "refs go stale when the page changes: list elements again")
            }
            return .failedPrecondition(message, hint: "the page threw; list elements or read the console to see why")
        case .snapshotFailed(let why):
            return .failedPrecondition("snapshot failed: \(why)", hint: "the page may be hidden or still loading; retry")
        case .badResult(let why):
            return DebugError(.internal, "unexpected script result: \(why)", hint: "retry; if it persists, the page broke the tool")
        case .scriptingNotAllowed:
            return DebugError(.forbidden, "running JavaScript is not allowed here",
                              hint: "use the other tools: elements, click, type, read")
        case .scriptDeclined:
            return DebugError(.forbidden, "the person declined running JavaScript on this page",
                              hint: "don't ask again in this session; use the other tools")
        case .invalidArgument(let why):
            return .invalidArgument(why, hint: "check the tool's parameters")
        }
    }

    static func requireSupport(_ target: Target, _ tool: String) throws -> RAVEPageSupport {
        guard let support = target.support else {
            throw DebugError.unavailable("\(tool) is recorded only on tabs the agent opened",
                                         hint: "open the page in a tab of your own (tabOpen) and use that")
        }
        return support
    }

    static func point(_ arguments: DebugArguments, ref: String, x: String, y: String,
                      hint: String) throws -> RAVEPageDriver.Point {
        if let value = arguments.int(ref) { return .ref(value) }
        guard let px = arguments.double(x), let py = arguments.double(y) else {
            throw DebugError.invalidArgument("pass \(ref), or \(x) and \(y)", hint: hint)
        }
        return .at(x: px, y: py)
    }

    static func modifierArgument(_ arguments: DebugArguments) throws -> RAVEPageModifiers {
        guard let text = arguments.string("modifiers"), !text.isEmpty else { return [] }
        do {
            return try RAVEPageModifiers.parse(text.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) })
        } catch let error as RAVEPageKeyError {
            throw DebugError.invalidArgument(error.message, hint: "e.g. shift, or command+shift")
        }
    }

    // MARK: - Replies

    struct WithEvents<Value: Encodable>: Encodable {
        let value: Value
        let events: [String]

        enum Keys: String, CodingKey { case events }

        func encode(to encoder: any Encoder) throws {
            try value.encode(to: encoder)
            guard !events.isEmpty else { return }
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(events, forKey: .events)
        }
    }

    struct ReadReply: Encodable {
        let reading: RAVEPageReading
        let offset: Int

        enum Keys: String, CodingKey { case nextOffset }

        func encode(to encoder: any Encoder) throws {
            try reading.encode(to: encoder)
            var container = encoder.container(keyedBy: Keys.self)
            let next = offset + reading.text.count
            if next < reading.length { try container.encode(next, forKey: .nextOffset) }
        }
    }

    struct EvaluationReply: Encodable {
        let type: String
        /// The value itself when it is JSON and was not cut; `text` otherwise.
        let value: JSONValue?
        let text: String?
        let truncated: Bool
        let length: Int

        init(_ evaluation: RAVEPageEvaluation) {
            type = evaluation.type
            truncated = evaluation.truncated
            length = evaluation.length
            if !evaluation.truncated, let json = evaluation.json, let parsed = try? JSONValue.parse(Data(json.utf8)) {
                value = parsed
                text = nil
            } else {
                value = nil
                text = evaluation.json
            }
        }
    }

    struct FramesReply: Encodable { let frames: [RAVEPageFrame] }
    struct TabsReply: Encodable { let tabs: [Tab] }
    struct ListReply<Entry: Encodable>: Encodable {
        let entries: [Entry]
        let total: Int
    }
    struct EventsReply: Encodable {
        let armed: String
        let events: [String]
    }
}

private extension JSONValue {
    /// As Foundation values, for an untyped endpoint's dictionary.
    var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .string(let value): value
        case .array(let values): values.map(\.any)
        case .object(let object): object.mapValues(\.any)
        }
    }
}
#endif
