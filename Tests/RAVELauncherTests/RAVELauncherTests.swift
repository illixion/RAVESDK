import Foundation
import Testing
@testable import RAVELauncher

/// A 1×1 PNG.
private let tinyPNG = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!

@Suite struct ShortcutRequestTests {
    private func request(_ query: String) -> URL { URL(string: "apparition://launcher-shortcut?\(query)")! }

    @Test func parsesAValidRequest() throws {
        let url = request("bundle-id=com.illixion.raven&title=Docs&url=raven://open?url%3Dhttps://example.com/a&icon=https://example.com/i.png")
        let parsed = try #require(RAVELauncherShortcutRequest.parse(url, scheme: "apparition"))
        #expect(parsed.ownerBundleID == "com.illixion.raven")
        #expect(parsed.title == "Docs")
        #expect(parsed.targetURL == "raven://open?url=https://example.com/a")
        #expect(parsed.iconURL == "https://example.com/i.png")
    }

    @Test func roundTripsThroughTheBuilder() throws {
        let url = try #require(RAVELauncherShortcutRequest.url(
            scheme: "apparition", ownerBundleID: "com.illixion.raven", title: "A + B",
            targetURL: URL(string: "raven://open?url=https://example.com")!, iconData: tinyPNG))
        let parsed = try #require(RAVELauncherShortcutRequest.parse(url, scheme: "apparition"))
        #expect(parsed.title == "A + B")
        #expect(parsed.iconData == tinyPNG)
    }

    @Test func refusesTheLaunchersOwnSchemeAndScriptTargets() {
        for target in ["apparition://launch?app=x", "javascript:alert(1)", "file:///etc/passwd", "data:text/html,x"] {
            let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            #expect(RAVELauncherShortcutRequest.parse(
                request("bundle-id=a.b&title=T&url=\(encoded)&icon=https://e.com/i.png"), scheme: "apparition") == nil)
        }
    }

    @Test func needsAnIconAndAnHTTPSOne() {
        #expect(RAVELauncherShortcutRequest.parse(request("bundle-id=a.b&title=T&url=x://open"), scheme: "apparition") == nil)
        #expect(RAVELauncherShortcutRequest.parse(
            request("bundle-id=a.b&title=T&url=x://open&icon=http://e.com/i.png"), scheme: "apparition") == nil)
    }

    @Test func refusesAnIconThatIsNotAnImage() {
        let junk = Data("not an image".utf8).base64EncodedString()
        #expect(RAVELauncherShortcutRequest.parse(
            request("bundle-id=a.b&title=T&url=x://open&icon-data=\(junk)"), scheme: "apparition") == nil)
    }

    @Test func refusesAnotherSchemeOrRoute() {
        #expect(RAVELauncherShortcutRequest.parse(
            URL(string: "other://launcher-shortcut?bundle-id=a.b&title=T&url=x://open&icon=https://e.com/i.png")!,
            scheme: "apparition") == nil)
        #expect(!RAVELauncherShortcutRequest.isRequest(URL(string: "apparition://launch?app=x")!, scheme: "apparition"))
    }
}

@Suite @MainActor struct ShortcutStoreTests {
    private func makeStore(_ defaults: UserDefaults) -> (RAVELauncherShortcutStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (RAVELauncherShortcutStore(defaults: defaults, key: "launcher.shortcuts.v1", iconDirectory: dir), dir)
    }

    private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "RAVELauncherTests.\(UUID().uuidString)")! }

    private func sample(_ title: String, target: String = "raven://open?url=https://e.com", icon: Data? = nil)
        -> RAVELauncherShortcutRequest {
        RAVELauncherShortcutRequest(ownerBundleID: "com.illixion.raven", title: title, targetURL: target,
                                    iconURL: icon == nil ? "https://e.com/i.png" : nil, iconData: icon)
    }

    @Test func addsNewestFirstAndReplacesTheSameTarget() throws {
        let (store, _) = makeStore(freshDefaults())
        try store.add(sample("One"))
        try store.add(sample("Two", target: "raven://open?url=https://f.com"))
        try store.add(sample("One again"))
        #expect(store.shortcuts.map(\.title) == ["One again", "Two"])
    }

    @Test func savesTheIconBesideAndRemovesIt() throws {
        let (store, _) = makeStore(freshDefaults())
        let shortcut = try store.add(sample("Icon", icon: tinyPNG))
        let file = try #require(store.iconFileURL(of: shortcut))
        #expect(FileManager.default.fileExists(atPath: file.path))
        store.remove(id: shortcut.id)
        #expect(store.shortcuts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// The JSON Apparition stored before the lift must keep decoding.
    @Test func readsApparitionsStoredShortcuts() throws {
        let defaults = freshDefaults()
        let json = """
        [{"id":"6E1B9A2C-6E2D-4A55-9C52-0C1D6E3C9F10","ownerBundleID":"com.illixion.raven","title":"Docs",
          "targetURL":"raven://open?url=https://e.com","iconFileName":"6E1B9A2C-6E2D-4A55-9C52-0C1D6E3C9F10.img",
          "createdAt":783000000}]
        """
        defaults.set(Data(json.utf8), forKey: "launcher.shortcuts.v1")
        let (store, dir) = makeStore(defaults)
        #expect(store.shortcuts.map(\.title) == ["Docs"])
        #expect(store.iconFileURL(of: store.shortcuts[0]) == dir.appendingPathComponent("6E1B9A2C-6E2D-4A55-9C52-0C1D6E3C9F10.img"))
    }

    @Test func shortcutTilesOpenAndRemove() throws {
        let (store, _) = makeStore(freshDefaults())
        try store.add(sample("Docs"))
        let item = try #require(store.items().first)
        #expect(item.actions.map(\.id) == ["open"])
        #expect(item.menu.map(\.id) == ["remove"])
    }
}

@Suite struct LaunchLinkTests {
    @Test func acceptsAppAndUniversalLinks() {
        #expect(RAVELaunchLink.validated(" raven://open ")?.absoluteString == "raven://open")
        #expect(RAVELaunchLink.validated("https://example.com/app") != nil)
    }

    @Test func refusesUnsafeOrMalformedLinks() {
        #expect(RAVELaunchLink.validated("javascript:alert(1)") == nil)
        #expect(RAVELaunchLink.validated("no scheme") == nil)
        #expect(RAVELaunchLink.validated("apparition://launch", forbidding: ["Apparition"]) == nil)
    }
}
