#if canImport(WebKit) && os(macOS)
import Foundation
@testable import RAVEBrowser
import Testing
import WebKit

/// Serves `rave-test://<host>/<path>` from a table, so a page and its
/// iframe can be two real origins with no network.
final class FixtureSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "rave-test"
    let pages: [String: String]

    init(_ pages: [String: String]) { self.pages = pages }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let url = task.request.url!
        let key = (url.host() ?? "") + url.path()
        let body = Data((pages[key] ?? "<!doctype html><title>missing \(key)</title>").utf8)
        task.didReceive(HTTPURLResponse(url: url, statusCode: pages[key] == nil ? 404 : 200, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": "text/html; charset=utf-8"])!)
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

@MainActor
@Suite(.serialized) struct RAVEPageFrameTests {
    static let pages = [
        "top/": """
            <!doctype html><html><head><title>Top</title><style>body{margin:0;font:16px sans-serif}
            iframe{position:absolute;left:100px;top:200px;width:400px;height:200px;border:2px solid #000}</style></head><body>
            <button onclick="document.title='top clicked'">Top button</button>
            <iframe src="rave-test://other/frame"></iframe>
            <script>addEventListener('message', e => document.title = String(e.data))</script>
            </body></html>
            """,
        "other/frame": """
            <!doctype html><html><head><style>body{margin:0;font:16px sans-serif}</style></head><body>
            <button onclick="parent.postMessage('inside ' + event.isTrusted, '*')">Inside</button>
            <input aria-label="Card number" oninput="parent.postMessage('typed ' + this.value, '*')">
            </body></html>
            """,
    ]

    /// A web view with the fixture scheme and a frame registry, in a
    /// background window when `windowed`.
    @MainActor
    final class Fixture {
        let frames = RAVEPageFrames()
        let view: WKWebView
        private var window: NSWindow?
        private let handler = FixtureSchemeHandler(RAVEPageFrameTests.pages)

        init(windowed: Bool) {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.setURLSchemeHandler(handler, forURLScheme: FixtureSchemeHandler.scheme)
            view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
            frames.install(on: view)
            if windowed {
                RAVEBackgroundWindow.enterBackgroundMode()
                window = RAVEBackgroundWindow.show(view, size: CGSize(width: 1024, height: 768))
            }
        }

        func driver(scripting: RAVEScriptPolicy = .never) -> RAVEPageDriver {
            RAVEPageDriver(webView: view, scripting: scripting, frames: frames)
        }

        func close() { window?.orderOut(nil) }
    }

    private func open(_ driver: RAVEPageDriver) async throws {
        try await driver.navigate(to: URL(string: "rave-test://top/")!)
        // The iframe announces itself as its document starts; give it a beat.
        for _ in 0..<20 where driver.frames?.frames.isEmpty != false {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test(arguments: [true, false])
    func listsAndClicksInsideACrossOriginFrame(windowed: Bool) async throws {
        let fixture = Fixture(windowed: windowed)
        defer { fixture.close() }
        let driver = fixture.driver()
        try await open(driver)

        let list = try await driver.elements()
        let inside = try #require(list.elements.first { $0.name == "Inside" })
        #expect(inside.inFrame == "other")
        // Placed in the page's viewport: the iframe's box plus its border.
        #expect(inside.x >= 100 && inside.y >= 200)
        #expect(list.elements.contains { $0.name == "Top button" && $0.inFrame == nil })
        #expect(list.outline().contains("(in frame other)"))

        let action = try await driver.click(ref: inside.ref)
        #expect(action.via == (windowed ? "native" : "synthetic"))
        #expect(try await driver.info().title == "inside \(windowed)")

        let field = try #require(list.elements.first { $0.name == "Card number" })
        try await driver.type(ref: field.ref, text: "4242")
        #expect(try await driver.info().title == "typed 4242")
    }

    @Test func evaluatesInAFrameAndListsFrames() async throws {
        let fixture = Fixture(windowed: true)
        defer { fixture.close() }
        let driver = fixture.driver(scripting: .always)
        try await open(driver)

        let frames = await driver.frames()
        let frame = try #require(frames.first)
        #expect(frame.url == "rave-test://other/frame" && frame.visible)
        #expect(frame.x == 102 && frame.y == 202)
        #expect(try await driver.evaluate("location.host", frame: frame.id).json == #""other""#)
        #expect(try await driver.evaluate("location.host").json == #""top""#)
        await #expect(throws: RAVEPageError.self) { try await driver.evaluate("1", frame: "nope") }
    }

    @Test func aDialogOverTheFrameHidesWhatIsInIt() async throws {
        let fixture = Fixture(windowed: true)
        defer { fixture.close() }
        let driver = fixture.driver(scripting: .always)
        try await open(driver)
        _ = try await driver.evaluate("""
            const d = document.createElement('div');
            d.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.5)';
            document.body.append(d); return true
            """)
        let names = try await driver.elements().elements.map(\.name)
        #expect(!names.contains("Inside"))
        let everything = try await driver.elements(scope: .page).elements.map(\.name)
        #expect(everything.contains("Inside"))
    }
}

@MainActor
@Suite(.serialized) struct RAVEPageSupportTests {
    static let page = """
        <!doctype html><html><head><title>Support</title></head><body>
        <button onclick="document.title = confirm('Delete everything?') ? 'confirmed' : 'kept'">Delete</button>
        <button onclick="document.title = 'name ' + prompt('Name?', 'otter')">Name</button>
        <a download="note.txt" href="data:text/plain,hello%20otters">Save note</a>
        <script>
        console.log('hello', { n: 1 });
        console.error('broken thing');
        fetch('data:text/plain,hi').then(r => r.text());
        setTimeout(() => { throw new Error('late failure') }, 0);
        </script></body></html>
        """

    @MainActor
    final class Fixture {
        let support: RAVEPageSupport
        let tab: RAVEBrowserTab
        let downloads = FileManager.default.temporaryDirectory.appendingPathComponent("rave-downloads-\(UUID().uuidString)")
        private var window: NSWindow?

        init() {
            support = RAVEPageSupport(downloadDirectory: downloads)
            tab = RAVEBrowserTab(dataStore: .nonPersistent(), features: [support])
            RAVEBackgroundWindow.enterBackgroundMode()
            window = RAVEBackgroundWindow.show(tab.webView!, size: CGSize(width: 1024, height: 768))
        }

        func close() {
            window?.orderOut(nil)
            tab.close()
            try? FileManager.default.removeItem(at: downloads)
        }
    }

    private func ref(_ driver: RAVEPageDriver, _ name: String) async throws -> Int {
        try #require(try await driver.elements(scope: .page).elements.first { $0.name == name }).ref
    }

    @Test func capturesConsoleExceptionsAndRequests() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let driver = try #require(fixture.tab.driver())
        // A real origin: a document with none (no base URL) mutes its own
        // errors to "Script error.", as browsers do for cross-origin scripts.
        try await driver.load(html: Self.page, baseURL: URL(string: "https://support.test/"))
        try await Task.sleep(for: .milliseconds(300))
        let console = fixture.support.console
        #expect(console.contains { $0.level == "log" && $0.text == #"hello {"n":1}"# })
        #expect(console.contains { $0.level == "error" && $0.text == "broken thing" })
        #expect(console.contains { $0.source == "exception" && $0.text.contains("late failure") })
        #expect(fixture.support.network.contains { $0.type == "fetch" && $0.url.hasPrefix("data:") && $0.status == 200 })
        #expect(fixture.support.events.contains { $0.kind == "consoleError" && $0.text == "broken thing" })
    }

    @Test func answersDialogsCautiouslyUnlessTold() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let driver = try #require(fixture.tab.driver())
        try await driver.load(html: Self.page)
        let mark = fixture.support.lastSequence

        let delete = try await ref(driver, "Delete")
        #expect(try await driver.click(ref: delete).info?.title == "kept")
        let event = try #require(fixture.support.events(after: mark).first { $0.kind == "dialog" })
        #expect(event.text.contains("Delete everything?") && event.text.contains("Cancel"))

        fixture.support.answerNextDialog(.accept(text: nil))
        #expect(try await driver.click(ref: delete).info?.title == "confirmed")
        // Once only.
        #expect(try await driver.click(ref: delete).info?.title == "kept")

        fixture.support.answerNextDialog(.accept(text: "seal"))
        #expect(try await driver.click(ref: try await ref(driver, "Name")).info?.title == "name seal")
    }

    @Test func savesDownloadsWhereTheAgentCanFindThem() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let driver = try #require(fixture.tab.driver())
        try await driver.load(html: Self.page)
        try await driver.click(ref: try await ref(driver, "Save note"))
        var finished: RAVEPageSupport.Event?
        for _ in 0..<40 where finished == nil {
            finished = fixture.support.events.first { $0.kind == "download" && $0.text.hasPrefix("finished") }
            if finished == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        _ = try #require(finished)
        let saved = fixture.downloads.appendingPathComponent("note.txt")
        #expect(try String(contentsOf: saved, encoding: .utf8) == "hello otters")
    }

    /// Swift 6 near-misses compile and are never called; asking the runtime
    /// is the only proof the delegate methods are the real ones.
    @Test func delegateMethodsAreTheRealOnes() throws {
        let tab = RAVEBrowserTab(dataStore: .nonPersistent())
        defer { tab.close() }
        let webView = try #require(tab.webView)
        let ui = try #require(webView.uiDelegate)
        let navigation = try #require(webView.navigationDelegate)
        for selector in [
            "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
            "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
            "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:",
            "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:",
        ] {
            #expect(ui.responds(to: NSSelectorFromString(selector)), "\(selector)")
        }
        for selector in [
            "webView:decidePolicyForNavigationAction:decisionHandler:",
            "webView:decidePolicyForNavigationResponse:decisionHandler:",
            "webView:navigationAction:didBecomeDownload:",
            "webView:navigationResponse:didBecomeDownload:",
        ] {
            #expect(navigation.responds(to: NSSelectorFromString(selector)), "\(selector)")
        }
    }
}
#endif
