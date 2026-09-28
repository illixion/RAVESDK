import CoreGraphics
import Foundation
import JavaScriptCore
@testable import RAVEBrowser
import Testing
#if canImport(WebKit)
import WebKit
#endif

@Suite struct RAVEPageOutlineTests {
    private func element(_ ref: Int, _ role: String, _ name: String, href: String? = nil,
                         value: String? = nil, checked: Bool? = nil, disabled: Bool? = nil) -> RAVEPageElement {
        RAVEPageElement(ref: ref, role: role, name: name, tag: "a", href: href, value: value,
                        checked: checked, disabled: disabled, x: 0, y: 0, w: 10, h: 10)
    }

    @Test func linesCarryWhatAModelNeeds() {
        #expect(element(3, "link", "Top post", href: "https://example.com/p").outlineLine
                == #"[3] link "Top post" → https://example.com/p"#)
        #expect(element(4, "textbox", "Search", value: "cats").outlineLine == #"[4] textbox "Search" = "cats""#)
        #expect(element(5, "checkbox", "Remember me", checked: true).outlineLine == #"[5] checkbox "Remember me" (checked)"#)
        #expect(element(6, "button", "", disabled: true).outlineLine == "[6] button (disabled)")
        #expect(element(7, "link", "Menu", href: "javascript:void(0)").outlineLine == #"[7] link "Menu""#)
    }

    @Test func outlineSaysWhereTheViewportIsAndWhatWasCut() {
        let viewport = RAVEPageViewport(width: 1280, height: 800, scrollX: 0, scrollY: 400,
                                        scrollWidth: 1280, scrollHeight: 5000)
        let list = RAVEPageElements(viewport: viewport, elements: [element(1, "button", "Go")], total: 3, truncated: true)
        #expect(list.outline() == """
            Viewport 1280×800 at y=400 of 5000
            [1] button "Go"
            (2 more not listed)
            """)
    }
}

/// Every script is a `callAsyncJavaScript` body, so each must at least parse
/// as an async function taking its arguments. JavaScriptCore has no DOM, so
/// this catches syntax only; the WebKit suite below runs them for real.
@Suite struct RAVEPageScriptSyntaxTests {
    static let scripts: [(String, String, [String])] = [
        ("elements", RAVEPageScripts.elements, ["scope", "limit"]),
        ("click", RAVEPageScripts.click, ["ref", "x", "y"]),
        ("type", RAVEPageScripts.type, ["ref", "text", "append", "submit"]),
        ("scroll", RAVEPageScripts.scroll, ["by", "to", "ref"]),
        ("find", RAVEPageScripts.find, ["text", "index"]),
        ("dismissOverlays", RAVEPageScripts.dismissOverlays, []),
        ("info", RAVEPageScripts.info, []),
        ("read", RAVEPageScripts.read, ["mode", "maxCharacters"]),
        ("hasReadability", RAVEPageScripts.hasReadability, []),
    ]

    @Test(arguments: scripts.map(\.0))
    func parses(_ name: String) throws {
        let (_, body, arguments) = try #require(Self.scripts.first { $0.0 == name })
        let context = try #require(JSContext())
        context.setObject(body, forKeyedSubscript: "body" as NSString)
        context.setObject(arguments, forKeyedSubscript: "names" as NSString)
        let result = context.evaluateScript("""
            (() => { try {
                const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
                new AsyncFunction(...names, body); return 'ok';
            } catch (e) { return String(e); } })()
            """)
        #expect(result?.toString() == "ok")
    }

    @Test func readabilityIsBundled() throws {
        let url = try #require(Bundle.module.url(forResource: "Readability", withExtension: "js"))
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("function Readability("))
    }
}

#if canImport(WebKit) && os(macOS)
/// The scripts against a real WKWebView on the host. Fixtures are local
/// markup, so nothing here touches the network.
@MainActor
@Suite(.serialized) struct RAVEPageDriverTests {
    let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
    var driver: RAVEPageDriver { RAVEPageDriver(webView: view) }

    static let page = """
        <!doctype html><html><head><title>Fixture</title>
        <style>body{margin:0;font:16px sans-serif} .tall{height:3000px}</style></head><body>
        <a href="#next" id="link">Next page</a>
        <button id="go" onclick="window.clicks=(window.clicks||0)+1;document.title='clicked '+window.clicks">Go</button>
        <label for="q">Search</label><input id="q" oninput="document.title='typed '+this.value">
        <a href="#x"><span role="button">Nested</span></a>
        <button style="display:none">Hidden</button>
        <custom-card></custom-card>
        <div class="tall"></div>
        <button id="below">Far below</button>
        <script>
        customElements.define('custom-card', class extends HTMLElement {
          connectedCallback() { this.attachShadow({mode:'open'}).innerHTML = '<button onclick="document.title=\\'shadow\\'">Shadow button</button>'; }
        });
        </script></body></html>
        """

    @Test func listsWhatIsOnScreenWithNames() async throws {
        try await driver.load(html: Self.page)
        let list = try await driver.elements()
        let names = list.elements.map(\.name)
        #expect(names.contains("Next page"))
        #expect(names.contains("Go"))
        #expect(names.contains("Search"))
        #expect(names.contains("Shadow button"))
        #expect(!names.contains("Hidden"))
        #expect(!names.contains("Far below"))
        // The span inside the link is the same target as the link.
        #expect(names.filter { $0 == "Nested" }.count == 1)
        #expect(list.elements.map(\.ref) == Array(1...list.elements.count))

        let everything = try await driver.elements(scope: .page)
        #expect(everything.elements.map(\.name).contains("Far below"))
    }

    @Test func clicksAndTypesByRef() async throws {
        let driver = driver
        try await driver.load(html: Self.page)
        let list = try await driver.elements()
        let go = try #require(list.elements.first { $0.name == "Go" })
        let action = try await driver.click(ref: go.ref)
        #expect(action.target == #"button "Go""#)
        #expect(action.info?.title == "clicked 1")

        let field = try #require(list.elements.first { $0.name == "Search" })
        try await driver.type(ref: field.ref, text: "cats")
        #expect(try await driver.info().title == "typed cats")

        let shadow = try #require(list.elements.first { $0.name == "Shadow button" })
        try await driver.click(ref: shadow.ref)
        #expect(try await driver.info().title == "shadow")
    }

    /// Client-rendered pages replace nodes between a listing and a click;
    /// the ref follows the element with the same link.
    @Test func refsFollowAReRenderedElement() async throws {
        let driver = driver
        try await driver.load(html: """
            <!doctype html><html><head><title>Feed</title></head><body>
            <div id="feed"><a href="#post-1" onclick="document.title='opened'">First post</a></div>
            </body></html>
            """)
        let link = try #require(try await driver.elements().elements.first { $0.name == "First post" })
        // Re-render the feed, as a framework would.
        try await driver.webView?.evaluateJavaScript(
            "document.getElementById('feed').innerHTML = '<a href=\"#post-1\" onclick=\"document.title=\\'opened\\'\">First post</a>'")
        try await driver.click(ref: link.ref)
        #expect(try await driver.info().title == "opened")
    }

    @Test func refsGoStaleWithTheDocument() async throws {
        let driver = driver
        try await driver.load(html: Self.page)
        _ = try await driver.elements()
        try await driver.load(html: Self.page)
        await #expect(throws: RAVEPageError.self) { try await driver.click(ref: 1) }
    }

    @Test func scrollsAndFinds() async throws {
        let driver = driver
        try await driver.load(html: Self.page)
        let scroll = try await driver.scroll(by: 1)
        #expect(scroll.moved)
        #expect(!scroll.atTop)
        let bottom = try await driver.scroll(to: .bottom)
        #expect(bottom.atBottom)
        try await driver.scroll(to: .top)
        let found = try await driver.find("far below")
        #expect(found.count == 1)
        #expect(try await driver.info().viewport.scrollY > 1000)
    }

    @Test func readsAnArticlePastItsOverlay() async throws {
        let driver = driver
        let paragraph = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 12)
        try await driver.load(html: """
            <!doctype html><html><head><title>Fox news</title></head><body style="overflow:hidden">
            <nav><a href="/">Home</a> <a href="/about">About</a></nav>
            <article><h1>Foxes jump</h1><p>\(paragraph)</p><p>\(paragraph)</p>
            <ul><li>First point</li><li>Second point</li></ul></article>
            <div style="position:fixed;inset:0;background:#000;z-index:99">Sign up to keep reading</div>
            </body></html>
            """)
        let reading = try await driver.read()
        #expect(reading.mode == .reader)
        #expect(reading.text.contains("quick brown fox"))
        #expect(reading.text.contains("- First point"))
        #expect(!reading.text.contains("Sign up"))

        // Hidden by the overlay, the article's links are not listed…
        #expect(try await driver.elements().elements.isEmpty)
        let overlays = try await driver.dismissOverlays()
        #expect(overlays.hidden.count == 1)
        #expect(overlays.unlockedScroll)
        // …and once it is gone they are.
        #expect(try await driver.elements().elements.map(\.name).contains("About"))

        let page = try await driver.read(mode: .page, maxCharacters: 50)
        #expect(page.mode == .page)
        #expect(page.truncated)
        #expect(page.text.count == 50)
    }

    /// The shapes real Reddit showed on the headset (2026-09-28): a fixed
    /// header and sidebar full of "Log in", a cookie dialog in a shadow root,
    /// and a feed card with a transparent link laid over it.
    @Test func keepsSiteChromeAndFindsCardLinks() async throws {
        let driver = driver
        try await driver.load(html: """
            <!doctype html><html><head><title>Feed</title><style>
            body{margin:0;font:16px sans-serif} header{position:fixed;top:0;left:0;right:0;height:56px;background:#eee}
            .side{position:fixed;top:56px;left:0;width:250px;bottom:0;background:#ddd}
            .card{position:relative;margin:100px 0 0 300px;width:600px;height:300px}
            .card .cover{position:absolute;inset:0}
            .card h2,.card img{position:relative;z-index:1}
            .card img{display:block;width:600px;height:200px;background:#999}
            </style></head><body>
            <header><a href="/">Home</a> <a href="/login">Log In</a> <a href="/signup">Sign Up</a></header>
            <div class="side">Join the community. Log in to vote. <a href="/r/a">r/a</a></div>
            <div class="card"><a class="cover" href="/post/1"><span style="position:absolute;left:-9999px">Card title</span></a>
            <h2>Card title</h2><img alt=""></div>
            <cookie-banner></cookie-banner>
            <script>
            customElements.define('cookie-banner', class extends HTMLElement {
              connectedCallback() { this.attachShadow({mode:'open'}).innerHTML =
                '<div style="position:fixed;right:0;bottom:0;width:400px;height:250px;background:#333;color:#fff">'
                + 'We use cookies. <button onclick="document.title=\\'declined\\'">Reject Optional Cookies</button>'
                + '<button>Accept All</button></div>'; }
            });
            </script></body></html>
            """)
        let list = try await driver.elements()
        #expect(list.elements.contains { $0.href?.hasSuffix("/post/1") == true })

        let overlays = try await driver.dismissOverlays()
        #expect(overlays.hidden.count == 1)
        #expect(overlays.hidden.first?.contains("cookies") == true)
        #expect(overlays.declined == "Reject Optional Cookies")
        #expect(try await driver.info().title == "declined")
        let after = try await driver.elements().elements.map(\.name)
        #expect(after.contains("Log In"))
        #expect(after.contains("r/a"))
        #expect(!after.contains("Accept All"))
    }

    @Test func marksLandOnTheSnapshot() async throws {
        let marks = [RAVEPageElement(ref: 1, role: "button", name: "Go", tag: "button",
                                     x: 100, y: 100, w: 200, h: 50)]
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 2048, height: 1536, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2048, height: 1536))
        let blank = try #require(context.makeImage())
        // A 2× snapshot of a 1024-point viewport, drawn 1024 wide: CSS
        // pixels map one to one.
        let drawn = try #require(RAVEMarkedSnapshot.draw(blank, width: 1024, viewportWidth: 1024, marks: marks))
        #expect(drawn.width == 1024 && drawn.height == 768)
        let pixel = try #require(Self.pixel(drawn, x: 100, y: 125))
        #expect(pixel.b > 0.7 && pixel.r < 0.3)   // the box's left edge, in ref 1's blue
        let inside = try #require(Self.pixel(drawn, x: 200, y: 125))
        #expect(inside.r > 0.9 && inside.g > 0.9)  // the box is outlined, not filled
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Double, g: Double, b: Double)? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return (Double(bytes[offset]) / 255, Double(bytes[offset + 1]) / 255, Double(bytes[offset + 2]) / 255)
    }
}
#endif
