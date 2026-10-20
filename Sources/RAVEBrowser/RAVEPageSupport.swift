//
//  RAVEPageSupport.swift
//  RAVEBrowser
//
//  What an agent driving a tab needs beyond the driver, as one page feature:
//  the page's console and network requests, its JavaScript dialogs answered
//  without anything modal appearing, downloads saved where the agent can find
//  them, a file chooser answered with the files it staged, and a running list
//  of all of that as events, so an action's result can say "a confirm dialog
//  opened and was cancelled" rather than leaving the model to wonder why the
//  click did nothing.
//
//  **For agent tabs only.** Capturing the console and the network means
//  wrapping `console`, `fetch` and `XMLHttpRequest` in the page's own world,
//  where the page can see the wrappers. That is a fair price for a tab an
//  agent drives, and the wrong one for a person's tab: "off means absent", as
//  for Raven's camera proxy. Raven for Mac installs it on the tabs its agent
//  harness opens and nowhere else.
//
//  Dialogs default to the cautious answer: OK for an alert (it has nothing
//  else), Cancel for confirm and prompt. An agent that wants OK says so for
//  the next dialog (`answerNextDialog`), so a "Delete everything?" is never
//  confirmed by a policy nobody looked at.
//

#if canImport(WebKit)
import Foundation
import WebKit

@MainActor
public final class RAVEPageSupport: RAVEPageFeature, RAVEPageEventHandler {
    nonisolated public static let messageHandler = "raveSupport"

    public struct ConsoleEntry: Codable, Sendable, Equatable {
        /// `log`, `info`, `warn`, `error`, `debug`; uncaught exceptions and
        /// unhandled rejections are `error`.
        public var level: String
        /// `console`, `exception` or `rejection`.
        public var source: String
        public var text: String
        /// Where it was thrown, for an exception.
        public var location: String?
        /// The document's URL.
        public var page: String
        public var inFrame: Bool
        public var time: Date
    }

    public struct NetworkEntry: Codable, Sendable, Equatable {
        /// `document`, `fetch`, `xhr`, or the resource timing initiator
        /// (`script`, `img`, `css`, `link`…).
        public var type: String
        public var method: String?
        public var url: String
        public var status: Int?
        public var durationMs: Int?
        public var bytes: Int?
        public var error: String?
        public var inFrame: Bool
        public var time: Date
    }

    public struct Event: Codable, Sendable, Equatable {
        public var sequence: Int
        /// `dialog`, `download`, `fileChooser`, `newWindow`, `consoleError`,
        /// `httpError`.
        public var kind: String
        public var text: String
        public var time: Date
    }

    public private(set) var console: [ConsoleEntry] = []
    public private(set) var network: [NetworkEntry] = []
    public private(set) var events: [Event] = []
    /// How many entries each list keeps; older ones drop off.
    public var limit = 1000

    /// Where downloads go. Nil declines them.
    public var downloadDirectory: URL?
    /// Files the next file chooser gets, then cleared. Nil cancels it.
    public var stagedFiles: [URL]?

    private var nextDialogAnswer: RAVEPageDialogAnswer?
    private var sequence = 0
    private let handler = Handler()
    private weak var controller: WKUserContentController?

    /// - Parameter downloadDirectory: where downloads are saved; nil declines
    ///   them, which the agent hears as an event.
    public init(downloadDirectory: URL? = nil) {
        self.downloadDirectory = downloadDirectory
    }

    /// The last event's sequence number: pass it to `events(after:)` to get
    /// what an action caused.
    public var lastSequence: Int { sequence }

    public func events(after sequence: Int) -> [Event] { events.filter { $0.sequence > sequence } }

    /// Answer the next JavaScript dialog this way, once; after it the
    /// cautious default returns.
    public func answerNextDialog(_ answer: RAVEPageDialogAnswer) {
        nextDialogAnswer = answer
    }

    public func clearConsole() { console = [] }
    public func clearNetwork() { network = [] }

    // MARK: - RAVEPageFeature

    public func install(on controller: WKUserContentController) {
        self.controller = controller
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: .page))
        handler.onMessage = { [weak self] body, inFrame in
            MainActor.assumeIsolated { self?.receive(body, inFrame: inFrame) }
        }
        controller.add(handler, contentWorld: .page, name: Self.messageHandler)
    }

    /// An agent drives its tab while the person works elsewhere, so on the
    /// Mac the page keeps rendering when its window is covered
    /// (`RAVEBackgroundWindow`): otherwise WebKit would treat it as hidden and
    /// throttle it mid-task.
    public func attach(to webView: WKWebView?) {
        #if os(macOS)
        if let webView { RAVEBackgroundWindow.keepRenderingWhenCovered(webView) }
        #endif
    }

    public func close() {
        controller?.removeScriptMessageHandler(forName: Self.messageHandler, contentWorld: .page)
        handler.onMessage = nil
    }

    // MARK: - RAVEPageEventHandler

    public func answer(_ dialog: RAVEPageDialog) async -> RAVEPageDialogAnswer? {
        let answer = nextDialogAnswer ?? RAVEBrowserTab.defaultAnswer(dialog)
        nextDialogAnswer = nil
        let said: String
        switch (dialog.kind, answer) {
        case (.alert, _): said = "closed with OK"
        case (.confirm, .accept): said = "answered OK"
        case (.confirm, .dismiss): said = "answered Cancel (answer the next one OK with the dialog tool)"
        case (.prompt, .accept(let text)): said = "answered \"\(text ?? dialog.defaultText ?? "")\""
        case (.prompt, .dismiss): said = "cancelled (answer the next one with the dialog tool)"
        }
        record("dialog", "\(dialog.kind.rawValue) \"\(Self.clip(dialog.message, 300))\" \(said)")
        return answer
    }

    public func decide(_ download: RAVEPageDownload) -> RAVEPageDownloadDecision? {
        guard let downloadDirectory else {
            record("download", "declined \(download.suggestedFilename): no download folder is set")
            return .cancel
        }
        try? FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        let file = RAVEBrowserTab.unusedFile(in: downloadDirectory, named: download.suggestedFilename)
        record("download", "started \(download.suggestedFilename) → \(file.path)")
        return .save(to: file)
    }

    public func downloadEnded(_ download: RAVEPageDownload, file: URL?, error: String?) {
        if let file {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int
            record("download", "finished \(file.path)" + (bytes.map { " (\($0) bytes)" } ?? ""))
        } else {
            record("download", "failed \(download.suggestedFilename): \(error ?? "unknown error")")
        }
    }

    public func choose(_ request: RAVEPageFileRequest) async -> RAVEPageFileChoice? {
        guard let files = stagedFiles, !files.isEmpty else {
            record("fileChooser", "a file chooser opened and was cancelled: use the upload tool on the file field instead")
            return .cancel
        }
        stagedFiles = nil
        record("fileChooser", "a file chooser opened and got \(files.map(\.lastPathComponent).joined(separator: ", "))")
        return .files(request.allowsMultiple ? files : Array(files.prefix(1)))
    }

    public func received(_ response: RAVEPageResponse) {
        guard let url = response.url else { return }
        append(&network, NetworkEntry(type: "document", method: nil, url: url.absoluteString, status: response.status,
                                      durationMs: nil, bytes: nil, error: nil, inFrame: !response.isMainFrame, time: Date()))
        if response.isMainFrame, let status = response.status, status >= 400 {
            record("httpError", "HTTP \(status) for \(url.absoluteString)")
        }
    }

    public func openedWindow(_ url: URL) {
        record("newWindow", "the page opened a new window on \(url.absoluteString)")
    }

    // MARK: - From the page

    private func receive(_ body: [String: Any], inFrame: Bool) {
        let page = body["url"] as? String ?? ""
        guard let entries = body["entries"] as? [[String: Any]] else { return }
        for entry in entries {
            let time = (entry["t"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            switch entry["kind"] as? String {
            case "console":
                let level = entry["level"] as? String ?? "log"
                let text = Self.clip(entry["text"] as? String ?? "", 4000)
                append(&console, ConsoleEntry(level: level, source: "console", text: text, location: nil,
                                              page: page, inFrame: inFrame, time: time))
                if level == "error" { record("consoleError", Self.clip(text, 300)) }
            case "exception", "rejection":
                let source = entry["kind"] as? String ?? "exception"
                let text = Self.clip(entry["text"] as? String ?? "", 4000)
                let location = entry["location"] as? String
                append(&console, ConsoleEntry(level: "error", source: source, text: text, location: location,
                                              page: page, inFrame: inFrame, time: time))
                record("consoleError", (source == "rejection" ? "unhandled rejection: " : "uncaught: ") + Self.clip(text, 300))
            case "net":
                append(&network, NetworkEntry(
                    type: entry["type"] as? String ?? "other", method: entry["method"] as? String,
                    url: Self.clip(entry["url"] as? String ?? "", 2000), status: entry["status"] as? Int,
                    durationMs: entry["ms"] as? Int, bytes: entry["size"] as? Int, error: entry["error"] as? String,
                    inFrame: inFrame, time: time))
            default:
                break
            }
        }
    }

    private func record(_ kind: String, _ text: String) {
        sequence += 1
        append(&events, Event(sequence: sequence, kind: kind, text: text, time: Date()))
    }

    private func append<T>(_ list: inout [T], _ value: T) {
        list.append(value)
        if list.count > limit { list.removeFirst(list.count - limit) }
    }

    private static func clip(_ text: String, _ count: Int) -> String {
        text.count > count ? String(text.prefix(count - 1)) + "…" : text
    }

    final class Handler: NSObject, WKScriptMessageHandler {
        var onMessage: (([String: Any], Bool) -> Void)?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            onMessage?(body, !message.frameInfo.isMainFrame)
        }
    }

    // MARK: - The page's half

    /// In the page's world, in every frame, at document start: wraps
    /// `console`, records uncaught errors and rejections, `fetch` and
    /// `XMLHttpRequest` with their status, resource timing for everything
    /// else, and subresources that failed to load. Entries are batched per
    /// task and capped per document, so a page that logs in a loop costs a
    /// bounded amount.
    static let script = #"""
        (() => {
            if (window.__raveSupport) return;
            window.__raveSupport = true;
            const handlers = window.webkit && window.webkit.messageHandlers;
            const handler = handlers && handlers.raveSupport;
            if (!handler) return;
            // Our own references, so a page replacing these later can't break capture.
            const post = handler.postMessage.bind(handler);
            const LIMIT = 3000;
            let queue = [], scheduled = false, sent = 0;
            const flush = () => {
                scheduled = false;
                if (!queue.length) return;
                const entries = queue;
                queue = [];
                try { post({ url: location.href, entries }); } catch (e) {}
            };
            const record = entry => {
                if (sent >= LIMIT) return;
                sent++;
                entry.t = Date.now();
                queue.push(entry);
                if (!scheduled) { scheduled = true; Promise.resolve().then(flush); }
            };
            addEventListener('pagehide', flush);
            const text = v => {
                try {
                    if (typeof v === 'string') return v;
                    if (v instanceof Error) return v.name + ': ' + v.message;
                    if (v instanceof Node) return '<' + (v.nodeName || '').toLowerCase() + (v.id ? '#' + v.id : '') + '>';
                    if (v === undefined) return 'undefined';
                    if (typeof v === 'function') return '[function ' + (v.name || 'anonymous') + ']';
                    const json = JSON.stringify(v);
                    return json === undefined ? String(v) : json.slice(0, 1000);
                } catch (e) { return String(v); }
            };
            for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
                const original = console[level];
                if (typeof original !== 'function') continue;
                console[level] = function (...args) {
                    try { record({ kind: 'console', level, text: args.map(text).join(' ').slice(0, 4000) }); } catch (e) {}
                    return original.apply(this, args);
                };
            }
            addEventListener('error', e => {
                const t = e.target;
                if (t && t !== window && t.tagName) {
                    const url = t.currentSrc || t.src || t.href;
                    if (url) record({ kind: 'net', type: t.tagName.toLowerCase(), url: String(url), error: 'failed to load' });
                    return;
                }
                // JavaScriptCore's stack holds frames only, not the message.
                const stack = e.error && e.error.stack ? '\n' + String(e.error.stack) : '';
                record({ kind: 'exception', text: (String(e.message) + stack).slice(0, 4000),
                         location: e.filename ? e.filename + ':' + e.lineno + ':' + e.colno : null });
            }, true);
            addEventListener('unhandledrejection', e => record({ kind: 'rejection', text: text(e.reason) }));

            const nativeFetch = window.fetch;
            if (typeof nativeFetch === 'function') {
                window.fetch = function (input, init) {
                    const start = performance.now();
                    const method = String((init && init.method) || (input && input.method) || 'GET').toUpperCase();
                    const url = String((input && input.url) || input);
                    return nativeFetch.apply(this, arguments).then(response => {
                        record({ kind: 'net', type: 'fetch', method, url: response.url || url, status: response.status,
                                 ms: Math.round(performance.now() - start) });
                        return response;
                    }, error => {
                        record({ kind: 'net', type: 'fetch', method, url, error: String(error),
                                 ms: Math.round(performance.now() - start) });
                        throw error;
                    });
                };
            }
            const XHR = window.XMLHttpRequest;
            if (XHR) {
                const open = XHR.prototype.open, send = XHR.prototype.send;
                XHR.prototype.open = function (method, url) {
                    this.__rave = { method: String(method).toUpperCase(), url: String(url) };
                    return open.apply(this, arguments);
                };
                XHR.prototype.send = function () {
                    const info = this.__rave;
                    if (info) {
                        const start = performance.now();
                        this.addEventListener('loadend', () => record({
                            kind: 'net', type: 'xhr', method: info.method, url: this.responseURL || info.url,
                            status: this.status || null, error: this.status ? null : 'failed',
                            ms: Math.round(performance.now() - start) }));
                    }
                    return send.apply(this, arguments);
                };
            }
            try {
                new PerformanceObserver(list => {
                    for (const e of list.getEntries()) {
                        if (e.initiatorType === 'fetch' || e.initiatorType === 'xmlhttprequest') continue;
                        record({ kind: 'net', type: e.initiatorType || 'other', url: e.name, ms: Math.round(e.duration),
                                 size: e.transferSize || null, status: e.responseStatus || null });
                    }
                }).observe({ type: 'resource', buffered: true });
            } catch (e) {}
        })();
        """#
}
#endif
