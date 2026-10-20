#if canImport(WebKit) && os(macOS)
import DebugTrace
import Foundation
@testable import RAVEBrowser
import Testing
import WebKit

/// The tool catalog through a real `DebugSurface`, as a server or a trace
/// would call it: names, validation, replies, events.
@MainActor
@Suite(.serialized) struct RAVEBrowserToolsTests {
    static let page = """
        <!doctype html><html><head><title>Tools</title></head><body>
        <button onclick="document.title = confirm('Sure?') ? 'yes' : 'no'">Ask</button>
        <label for="q">Search</label><input id="q">
        <p>Some text to read about otters.</p>
        <script>console.warn('careful')</script>
        </body></html>
        """

    @MainActor
    final class Fixture {
        let support = RAVEPageSupport()
        let tab: RAVEBrowserTab
        let surface = DebugSurface(includeBuiltins: false)
        private var window: NSWindow?

        init(prefix: String = "", scripting: Bool) {
            tab = RAVEBrowserTab(dataStore: .nonPersistent(), features: [support])
            RAVEBackgroundWindow.enterBackgroundMode()
            window = RAVEBackgroundWindow.show(tab.webView!, size: CGSize(width: 1024, height: 768))
            let tab = tab, support = support
            surface.register(RAVEBrowserTools.endpoints(
                .init(prefix: prefix, context: [.string("tab", "which tab")], scripting: scripting, uploads: true,
                      describe: { _ in ["tab": .string("only")] }, snapshotSensitivity: .none)
            ) { _ in
                guard let driver = tab.driver(scripting: scripting ? .always : .never) else {
                    throw DebugError.failedPrecondition("no page")
                }
                return RAVEBrowserTools.Target(driver: driver, support: support)
            })
        }

        func call(_ name: String, _ arguments: [String: JSONValue] = [:]) async -> Result<DebugResult, DebugError> {
            await surface.call(name, arguments: arguments)
        }

        func json(_ name: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
            try #require(try (await call(name, arguments)).get().json)
        }

        func close() {
            window?.orderOut(nil)
            tab.close()
        }
    }

    @Test func namesFollowThePrefixAndScriptingIsOnlyOfferedWhenAllowed() {
        let plain = Fixture(scripting: false)
        defer { plain.close() }
        let names = Set(plain.surface.catalog.map(\.name))
        #expect(names.isSuperset(of: ["page", "navigate", "read", "elements", "snapshot", "click", "type", "keys", "hover",
                                      "drag", "select", "check", "scroll", "find", "wait", "overlays", "frames", "console",
                                      "network", "dialog", "downloads", "upload"]))
        #expect(!names.contains("evaluate"))

        let prefixed = Fixture(prefix: "web", scripting: true)
        defer { prefixed.close() }
        let webNames = Set(prefixed.surface.catalog.map(\.name))
        #expect(webNames.isSuperset(of: ["web", "webNavigate", "webClick", "webElements", "webEvaluate"]))
        // Every page tool takes the host's context parameter.
        #expect(prefixed.surface.catalog.allSatisfy { $0.parameters.contains { $0.name == "tab" } })
    }

    @Test func readsActsAndReportsWhatThePageDid() async throws {
        let fixture = Fixture(scripting: true)
        defer { fixture.close() }
        _ = try await #require(fixture.tab.driver()).load(html: Self.page, baseURL: URL(string: "https://tools.test/"))

        let page = try await fixture.json("page")
        #expect(page["title"]?.stringValue == "Tools" && page["tab"]?.stringValue == "only")

        let elements = try await fixture.json("elements")
        let outline = try #require(elements["outline"]?.stringValue)
        #expect(outline.contains(#"button "Ask""#))

        let ask = try await fixture.json("find", ["text": "otters"])
        #expect(ask["count"]?.intValue == 1)

        // The action's reply carries the dialog the click opened.
        let refs = Dictionary((elements["elements"]?.arrayValue ?? []).compactMap { element -> (String, Int)? in
            guard let name = element["name"]?.stringValue, let ref = element["ref"]?.intValue else { return nil }
            return (name, ref)
        }, uniquingKeysWith: { first, _ in first })
        let askRef = try #require(refs["Ask"]), searchRef = try #require(refs["Search"])
        let clicked = try await fixture.json("click", ["ref": .int(askRef)])
        #expect(clicked["info"]?["title"]?.stringValue == "no")
        let events = clicked["events"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(events.contains { $0.hasPrefix("dialog: confirm \"Sure?\"") })

        _ = try await fixture.json("dialog", ["accept": true])
        #expect(try await fixture.json("click", ["ref": .int(askRef)])["info"]?["title"]?.stringValue == "yes")

        let typed = try await fixture.json("type", ["ref": .int(searchRef), "text": "seals", "submit": false])
        #expect(typed["target"]?.stringValue?.contains("Search") == true)

        let value = try await fixture.json("evaluate", ["script": "document.getElementById('q').value"])
        #expect(value["value"]?.stringValue == "seals" && value["type"]?.stringValue == "string")

        let console = try await fixture.json("console", ["level": "warn"])
        #expect(console["entries"]?.arrayValue?.contains { $0["text"]?.stringValue == "careful" } == true)

        let read = try await fixture.json("read", ["mode": "page", "max": 100])
        #expect(read["text"]?.stringValue?.contains("otters") == true)
    }

    @Test func mistakesComeBackWithHints() async throws {
        let fixture = Fixture(scripting: false)
        defer { fixture.close() }
        _ = try await #require(fixture.tab.driver()).load(html: Self.page)

        // A model's guess at an argument name.
        guard case .failure(let unknown) = await fixture.call("click", ["element": 1]) else {
            Issue.record("an unknown argument was accepted"); return
        }
        #expect(unknown.code == .invalidArgument && unknown.hint != nil)

        guard case .failure(let stale) = await fixture.call("click", ["ref": 99]) else {
            Issue.record("a ref that never existed was clicked"); return
        }
        #expect(stale.hint?.contains("list elements again") == true)

        guard case .failure(let keys) = await fixture.call("keys", ["keys": "Hyper+q"]) else {
            Issue.record("a bad key was pressed"); return
        }
        #expect(keys.code == .invalidArgument)
    }
}
#endif
