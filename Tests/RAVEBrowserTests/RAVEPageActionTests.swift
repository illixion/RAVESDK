import Foundation
@testable import RAVEBrowser
import Testing
#if canImport(WebKit)
import WebKit
#endif

@Suite struct RAVEPageKeyTests {
    @Test func namedKeysAndChords() throws {
        let enter = try RAVEPageKeyChord.parse("Enter")
        #expect(enter.key == "Enter" && enter.code == "Enter" && enter.keyCode == 13 && enter.macKeyCode == 36)
        #expect(enter.text == nil && enter.modifiers.isEmpty)

        let back = try RAVEPageKeyChord.parse("Shift+Tab")
        #expect(back.key == "Tab" && back.modifiers == .shift)

        let all = try RAVEPageKeyChord.parse("Meta+a")
        #expect(all.key == "a" && all.code == "KeyA" && all.modifiers == .command && all.text == nil)

        let ctrl = try RAVEPageKeyChord.parse("ctrl+shift+k")
        #expect(ctrl.modifiers == [.control, .shift] && ctrl.key == "K")
    }

    @Test func charactersStandForTheirKeys() throws {
        let upper = try RAVEPageKeyChord.parse("A")
        #expect(upper.key == "A" && upper.code == "KeyA" && upper.modifiers == .shift && upper.text == "A")

        let question = try RAVEPageKeyChord.parse("?")
        #expect(question.code == "Slash" && question.modifiers == .shift && question.text == "?")

        let digit = try RAVEPageKeyChord.parse("7")
        #expect(digit.code == "Digit7" && digit.keyCode == 55 && digit.macKeyCode == 26 && digit.text == "7")

        let plus = try RAVEPageKeyChord.parse("Shift++")
        #expect(plus.key == "+" && plus.text == "+")

        let space = try RAVEPageKeyChord.parse("Space")
        #expect(space.key == " " && space.text == " ")
    }

    @Test func sequencesAndMistakes() throws {
        #expect(try RAVEPageKeyChord.parseSequence("ArrowDown down Enter").map(\.key) == ["ArrowDown", "ArrowDown", "Enter"])
        #expect(throws: RAVEPageKeyError.self) { try RAVEPageKeyChord.parse("Hyper+a") }
        #expect(throws: RAVEPageKeyError.self) { try RAVEPageKeyChord.parse("Banana") }
        #expect(throws: RAVEPageKeyError.self) { try RAVEPageKeyChord.parseSequence("  ") }
    }
}

@Suite struct RAVEScriptSyntaxTests {
    @Test func expressionsAndStatementsAreToldApart() {
        let expression = { (source: String) in RAVEScriptSyntax.error(compiling: "return await (\n\(source)\n);") == nil }
        #expect(expression("document.title"))
        #expect(expression("{ a: 1, b: [2, 3] }"))
        #expect(expression("fetch('/x').then(r => r.status)"))
        #expect(!expression("const a = 1; return a"))
        #expect(!expression("document.title; 5"))
        #expect(RAVEScriptSyntax.error(compiling: "const a = 1; return a") == nil)
        #expect(RAVEScriptSyntax.error(compiling: "return (")?.contains("SyntaxError") == true)
    }

    @MainActor
    @Test func sessionConsentAsksOnce() async {
        var asked = 0
        let consent = RAVEScriptSessionConsent { _ in
            asked += 1
            return .allowForSession
        }
        let request = RAVEScriptRequest(origin: "https://example.com", url: "https://example.com/", source: "1")
        #expect(await consent.allows(request))
        #expect(await consent.allows(request))
        #expect(asked == 1)
        consent.reset()
        #expect(await consent.allows(request))
        #expect(asked == 2)
    }

    @MainActor
    @Test func onceAndDenyDoNotStick() async {
        var answers: [RAVEScriptSessionConsent.Answer] = [.allowOnce, .deny, .deny]
        let consent = RAVEScriptSessionConsent { _ in answers.removeFirst() }
        let request = RAVEScriptRequest(origin: "https://example.com", url: "https://example.com/", source: "1")
        #expect(await consent.allows(request))
        #expect(!(await consent.allows(request)))
        #expect(!(await consent.allows(request)))
        #expect(!consent.isGranted)
    }
}

#if canImport(WebKit) && os(macOS)
/// The new actions against a real WKWebView. Native input needs the view in a
/// shown window; a view in none gets synthetic events, so each input test runs
/// both ways and checks what the page saw.
@MainActor
@Suite(.serialized) struct RAVEPageActionTests {
    /// A page that writes what each event told it into `#log`, and its
    /// `isTrusted` into the title.
    static let page = """
        <!doctype html><html><head><title>Actions</title><style>
        body{margin:0;font:16px sans-serif} #hover{width:200px;height:40px;background:#ccc}
        #slider{width:300px;height:30px;background:#eee;touch-action:none}
        #drop{width:200px;height:80px;background:#ddf} #card{width:120px;height:40px;background:#fdd}
        </style></head><body>
        <button id="go" onclick="document.title='clicked ' + event.isTrusted">Go</button>
        <form id="f" onsubmit="event.preventDefault(); document.title='submitted ' + document.getElementById('q').value">
          <label for="q">Search</label><input id="q" name="q"
            oninput="window.lastInputTrusted = event.isTrusted">
        </form>
        <input id="other" aria-label="Other field">
        <div id="hover" role="button" tabindex="0" onmouseenter="document.title='hovered ' + event.isTrusted">Hover me</div>
        <select id="pick" aria-label="Colour"><option value="r">Red</option><option value="g">Green</option></select>
        <label><input type="checkbox" id="agree"> I agree</label>
        <input type="file" id="file" aria-label="Attachment"
          onchange="this.files[0].text().then(t => document.title = 'file ' + this.files[0].name + ' ' + t)">
        <div id="slider" role="slider" tabindex="0" aria-label="Volume"></div>
        <div id="card" draggable="true" role="button" aria-label="Card">Card</div>
        <div id="drop" role="region" tabindex="0" aria-label="Drop zone"
          ondragover="event.preventDefault()" ondrop="document.title='dropped'">Drop here</div>
        <script>
        window.pageValue = 41;
        let moves = 0;
        const s = document.getElementById('slider');
        s.addEventListener('pointerdown', e => { moves = 0; s.setPointerCapture && s.setPointerCapture(e.pointerId); });
        s.addEventListener('pointermove', e => { if (e.buttons) moves++; });
        s.addEventListener('pointerup', e => document.title = 'slid ' + moves + ' ' + e.isTrusted);
        </script></body></html>
        """

    @MainActor
    final class Fixture {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        private var window: NSWindow?

        /// Windowed means behind every other window, in an accessory process:
        /// it renders and takes real input without ever taking focus.
        init(windowed: Bool) {
            guard windowed else { return }
            RAVEBackgroundWindow.enterBackgroundMode()
            window = RAVEBackgroundWindow.show(view, size: CGSize(width: 1024, height: 768))
        }

        func close() { window?.orderOut(nil) }
    }

    private func ref(_ driver: RAVEPageDriver, _ name: String) async throws -> Int {
        let list = try await driver.elements(scope: .page)
        return try #require(list.elements.first { $0.name == name }).ref
    }

    @Test(arguments: [true, false])
    func clicksAreTrustedOnlyWhenNative(windowed: Bool) async throws {
        let fixture = Fixture(windowed: windowed)
        defer { fixture.close() }
        let driver = RAVEPageDriver(webView: fixture.view)
        try await driver.load(html: Self.page)
        let action = try await driver.click(ref: try await ref(driver, "Go"))
        #expect(action.via == (windowed ? "native" : "synthetic"))
        #expect(action.info?.title == "clicked \(windowed)")
    }

    @Test(arguments: [true, false])
    func typesAndSubmits(windowed: Bool) async throws {
        let fixture = Fixture(windowed: windowed)
        defer { fixture.close() }
        let driver = RAVEPageDriver(webView: fixture.view, scripting: .always)
        try await driver.load(html: Self.page)
        let field = try await ref(driver, "Search")
        let action = try await driver.type(ref: field, text: "otters", submit: true)
        #expect(action.via == (windowed ? "native" : "synthetic"))
        #expect(try await driver.info().title == "submitted otters")
        let trusted = try await driver.evaluate("window.lastInputTrusted")
        #expect(trusted.json == (windowed ? "true" : "false"))

        // Replacing, then appending.
        try await driver.type(ref: field, text: "seals")
        try await driver.type(ref: field, text: " too", append: true)
        #expect(try await driver.evaluate("document.getElementById('q').value").json == #""seals too""#)
    }

    @Test(arguments: [true, false])
    func pressesKeys(windowed: Bool) async throws {
        let fixture = Fixture(windowed: windowed)
        defer { fixture.close() }
        let driver = RAVEPageDriver(webView: fixture.view, scripting: .always)
        try await driver.load(html: Self.page)
        let field = try await ref(driver, "Search")
        try await driver.press(keys: "a b Shift+c", ref: field)
        #expect(try await driver.evaluate("document.getElementById('q').value").json == #""abC""#)
        try await driver.press(keys: "Backspace")
        #expect(try await driver.evaluate("document.getElementById('q').value").json == #""ab""#)
        let tabbed = try await driver.press(keys: "Tab")
        #expect(tabbed.target.contains("Other field") || windowed)
        #expect(try await driver.evaluate("document.activeElement.id").json == #""other""#)
        try await driver.press(keys: "Enter", ref: field)
        #expect(try await driver.info().title == "submitted ab")
    }

    @Test(arguments: [true, false])
    func hovers(windowed: Bool) async throws {
        let fixture = Fixture(windowed: windowed)
        defer { fixture.close() }
        let driver = RAVEPageDriver(webView: fixture.view)
        try await driver.load(html: Self.page)
        let action = try await driver.hover(.ref(try await ref(driver, "Hover me")))
        // A real move reaches the page only in a key window; otherwise the
        // driver falls back and says why.
        #expect(action.info?.title == "hovered \(action.via == "native")")
        if windowed, action.via != "native" { #expect(action.note != nil) }
    }

    @Test func selectsChecksAndUploads() async throws {
        let fixture = Fixture(windowed: true)
        defer { fixture.close() }
        let driver = RAVEPageDriver(webView: fixture.view, scripting: .always)
        try await driver.load(html: Self.page)

        let selection = try await driver.select(ref: try await ref(driver, "Colour"), values: ["green"])
        #expect(selection.selected == ["Green"])
        #expect(try await driver.evaluate("document.getElementById('pick').value").json == #""g""#)
        await #expect(throws: RAVEPageError.self) { try await driver.select(ref: try await ref(driver, "Colour"), values: ["Blue"]) }

        let agree = try await ref(driver, "I agree")
        let checked = try await driver.check(ref: agree)
        #expect(checked.checked && checked.changed)
        let again = try await driver.check(ref: agree)
        #expect(again.checked && !again.changed)
        #expect(!(try await driver.check(ref: agree, checked: false)).checked)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rave-upload-\(UUID().uuidString).txt")
        try Data("hello otters".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let upload = try await driver.upload(ref: try await ref(driver, "Attachment"), files: [file])
        #expect(upload.via == "input" && upload.count == 1)
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await driver.info().title == "file \(file.lastPathComponent) hello otters")
    }

    @Test(arguments: [true, false])
    func drags(windowed: Bool) async throws {
        let fixture = Fixture(windowed: windowed)
        defer { fixture.close() }
        let driver = RAVEPageDriver(webView: fixture.view)
        try await driver.load(html: Self.page)
        let slider = try await ref(driver, "Volume")
        let slid = try await driver.drag(from: .ref(slider), to: .at(x: 290, y: 0), steps: 6)
        #expect(!slid.html5)
        let title = try await driver.info().title
        #expect(title.hasPrefix("slid ") && title.hasSuffix(" \(windowed)"))

        let dropped = try await driver.drag(from: .ref(try await ref(driver, "Card")), to: .ref(try await ref(driver, "Drop zone")))
        #expect(dropped.html5 && dropped.dropped)
        #expect(try await driver.info().title == "dropped")
    }

    @Test func evaluatesAsThePage() async throws {
        let view = WKWebView()
        let driver = RAVEPageDriver(webView: view, scripting: .always)
        try await driver.load(html: Self.page)
        // The page's own globals: this is the page world, not the driver's.
        #expect(try await driver.evaluate("window.pageValue + 1").json == "42")
        let statements = try await driver.evaluate("const n = document.querySelectorAll('button').length; return n * 10")
        #expect(statements.mode == "statements" && statements.json == "10")
        #expect(try await driver.evaluate("new Promise(r => setTimeout(() => r('later'), 20))").json == #""later""#)
        let node = try await driver.evaluate("document.getElementById('go')")
        #expect(node.type == "node" && node.json?.contains("<button#go>") == true)
        let undefined = try await driver.evaluate("undefined")
        #expect(undefined.type == "undefined" && undefined.json == nil)
        let cyclic = try await driver.evaluate("(() => { const a = {}; a.self = a; return a })()")
        #expect(cyclic.json?.contains("[circular]") == true)
        let long = try await driver.evaluate("'x'.repeat(100)", maxCharacters: 10)
        #expect(long.truncated && long.json?.count == 10)
        await #expect(throws: RAVEPageError.self) { try await driver.evaluate("throw new Error('nope')") }
        await #expect(throws: RAVEPageError.self) { try await driver.evaluate("return (") }
    }

    @Test func scriptingFollowsThePolicy() async throws {
        let view = WKWebView()
        let never = RAVEPageDriver(webView: view)
        try await never.load(html: Self.page)
        await #expect(throws: RAVEPageError.scriptingNotAllowed) { try await never.evaluate("1") }

        var asked: [RAVEScriptRequest] = []
        let consent = RAVEScriptSessionConsent { request in
            asked.append(request)
            return .deny
        }
        let ask = RAVEPageDriver(webView: view, scripting: .ask(consent))
        await #expect(throws: RAVEPageError.scriptDeclined) { try await ask.evaluate("document.title = 'ran'") }
        #expect(asked.count == 1 && asked.first?.source == "document.title = 'ran'")
        #expect(try await ask.info().title == "Actions")
    }

    @Test func waitsForText() async throws {
        let fixture = Fixture(windowed: true)
        defer { fixture.close() }
        let driver = RAVEPageDriver(webView: fixture.view)
        // Later than the load's own wait for the page to go quiet (a second).
        try await driver.load(html: """
            <!doctype html><html><body><p id="p">Loading…</p>
            <script>setTimeout(() => document.getElementById('p').textContent = 'Results ready', 2500)</script></body></html>
            """)
        let appeared = try await driver.wait(forText: "results ready", timeout: .seconds(3))
        #expect(appeared.met && appeared.waited >= 100)
        let gone = try await driver.wait(forText: "loading", gone: true, timeout: .milliseconds(500))
        #expect(gone.met)
        let never = try await driver.wait(forText: "nonexistent", timeout: .milliseconds(300))
        #expect(!never.met)
    }
}
#endif
