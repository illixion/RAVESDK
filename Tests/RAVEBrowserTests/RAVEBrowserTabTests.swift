#if canImport(WebKit)
import Foundation
import Testing
import WebKit
@testable import RAVEBrowser

/// The policy half is pure and is where the rules that matter live — never a
/// visible tab, never a busy one, and a grace period under warning-level
/// pressure so the tab you just switched away from survives.
@Suite("Tab hibernation policy")
struct RAVETabHibernationPolicyTests {
    private func candidate(
        hiddenFor: TimeInterval?,
        blocked: Bool = false
    ) -> RAVETabHibernationPolicy.Candidate {
        RAVETabHibernationPolicy.Candidate(id: UUID(), hiddenFor: hiddenFor, blocked: blocked)
    }

    @Test func idleTakesOnlyLongHiddenTabs() {
        let old = candidate(hiddenFor: RAVETabHibernationPolicy.idleInterval + 1)
        let recent = candidate(hiddenFor: 60)

        let victims = RAVETabHibernationPolicy.victims([old, recent], trigger: .idle)

        #expect(victims == [old.id])
    }

    @Test func aVisibleTabIsNeverAVictim() {
        // Not even under critical pressure: the page someone is reading is
        // worth more than the memory it costs.
        let visible = candidate(hiddenFor: nil)

        #expect(RAVETabHibernationPolicy.victims([visible], trigger: .idle).isEmpty)
        #expect(RAVETabHibernationPolicy.victims([visible], trigger: .pressure(critical: true)).isEmpty)
    }

    @Test func aBusyTabIsNeverAVictim() {
        let busy = candidate(hiddenFor: RAVETabHibernationPolicy.idleInterval * 10, blocked: true)

        #expect(RAVETabHibernationPolicy.victims([busy], trigger: .idle).isEmpty)
        #expect(RAVETabHibernationPolicy.victims([busy], trigger: .pressure(critical: true)).isEmpty)
    }

    @Test func aWarningSparesTheTabJustSwitchedAwayFrom() {
        let justLeft = candidate(hiddenFor: 10)
        let colder = candidate(hiddenFor: RAVETabHibernationPolicy.pressureGrace + 1)

        let victims = RAVETabHibernationPolicy.victims(
            [justLeft, colder], trigger: .pressure(critical: false)
        )

        #expect(victims == [colder.id])
    }

    @Test func criticalPressureTakesEveryHiddenTab() {
        let justLeft = candidate(hiddenFor: 1)
        let colder = candidate(hiddenFor: 600)

        let victims = RAVETabHibernationPolicy.victims(
            [justLeft, colder], trigger: .pressure(critical: true)
        )

        // Coldest first — a caller that stops early gives up the page least
        // likely to be wanted back.
        #expect(victims == [colder.id, justLeft.id])
    }
}

/// The tab core against a real `WKWebView` on the host. Pages are local markup
/// with an https base URL, so nothing here touches the network.
@MainActor
@Suite("Browser tab", .serialized)
struct RAVEBrowserTabTests {
    private let url = URL(string: "https://example.invalid/page")!

    /// Records what the tab does to its features, in order.
    final class Probe: RAVEPageFeature {
        let name: String
        let journal: Journal
        var blocker: String?
        private(set) weak var webView: WKWebView?

        init(_ name: String, journal: Journal) {
            self.name = name
            self.journal = journal
        }

        func install(on controller: WKUserContentController) {
            controller.addUserScript(WKUserScript(
                source: "window.__order = (window.__order || []).concat('\(name)');",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
            journal.add("\(name).install")
        }

        func attach(to webView: WKWebView?) {
            self.webView = webView
            journal.add("\(name).attach(\(webView == nil ? "nil" : "view"))")
        }

        func pageWillNavigate() { journal.add("\(name).pageWillNavigate") }
        var hibernationBlocker: String? { blocker }
        func close() { journal.add("\(name).close") }
    }

    final class Journal {
        private(set) var entries: [String] = []
        func add(_ entry: String) { entries.append(entry) }
        func clear() { entries.removeAll() }
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func loadPage(_ tab: RAVEBrowserTab, path: String = "/start", title: String = "Fixture") async -> Bool {
        let base = URL(string: "https://example.invalid\(path)")!
        tab.webView?.loadHTMLString("<!doctype html><title>\(title)</title><p>hi</p>", baseURL: base)
        return await waitUntil { tab.url == base && !tab.isLoading && tab.title == title }
    }

    /// The features' scripts run in the order the app listed them — the
    /// contract the call layer's chain depends on — however they were built.
    @Test func featuresInstallInTheirListedOrder() async throws {
        let journal = Journal()
        let second = Probe("second", journal: journal)
        let first = Probe("first", journal: journal)
        let third = Probe("third", journal: journal)
        let tab = RAVEBrowserTab(dataStore: .nonPersistent(), features: [first, second, third])
        defer { tab.close() }
        #expect(journal.entries.prefix(3) == ["first.install", "second.install", "third.install"])
        #expect(Array(journal.entries.dropFirst(3)) == ["first.attach(view)", "second.attach(view)", "third.attach(view)"])
        #expect(await loadPage(tab))
        let order = try await tab.webView?.evaluateJavaScript("window.__order.join()") as? String
        #expect(order == "first,second,third")
    }

    /// A same-document navigation fires no delegate callback; KVO is what
    /// keeps the address right, and the hook says it was same-document.
    @Test func pushStateUpdatesTheAddress() async throws {
        let tab = RAVEBrowserTab(dataStore: .nonPersistent())
        defer { tab.close() }
        var changes: [(String, Bool)] = []
        tab.onURLChanged = { same in changes.append((tab.url?.path ?? "", same)) }
        #expect(await loadPage(tab))
        changes.removeAll()

        _ = try await tab.webView?.evaluateJavaScript("history.pushState({}, '', '/next?x=1'); 0")
        #expect(await waitUntil { tab.url?.path == "/next" })
        #expect(tab.url?.absoluteString == "https://example.invalid/next?x=1")
        #expect(tab.displayURL == "example.invalid/next?x=1")
        #expect(changes.last?.0 == "/next")
        #expect(changes.last?.1 == true)
    }

    @Test func aRestoredTabHoldsNoPageUntilItIsShown() {
        let tab = RAVEBrowserTab(dataStore: .nonPersistent(),
                                 restoring: .init(url: url, title: "Restored"))
        defer { tab.close() }

        // The whole point of lazy restore: address and title without a
        // content process behind them.
        #expect(tab.isHibernated)
        #expect(tab.webView == nil)
        #expect(tab.url == url)
        #expect(tab.title == "Restored")
        #expect(!tab.isBlank)

        tab.setVisible(true)

        #expect(!tab.isHibernated)
        #expect(tab.webView != nil)
    }

    /// Hibernation drops the web view and keeps the tab, its features and its
    /// controller; the features hear the document go and the view come back.
    @Test func hibernatingDropsThePageAndKeepsTheTab() async {
        let journal = Journal()
        let probe = Probe("probe", journal: journal)
        let tab = RAVEBrowserTab(dataStore: .nonPersistent(), features: [probe])
        defer { tab.close() }
        #expect(await loadPage(tab))
        let controller = tab.controller
        journal.clear()

        tab.setVisible(false)
        #expect(tab.hibernate(reason: "test"))
        #expect(tab.isHibernated)
        #expect(tab.webView == nil)
        #expect(probe.webView == nil)
        #expect(tab.url?.host() == "example.invalid")
        #expect(journal.entries == ["probe.pageWillNavigate", "probe.attach(nil)"])

        tab.setVisible(true)
        #expect(!tab.isHibernated)
        #expect(tab.webView != nil)
        #expect(probe.webView === tab.webView)
        #expect(tab.webView?.configuration.userContentController === controller)
    }

    @Test func blockersComeInOrder() async {
        let journal = Journal()
        let first = Probe("first", journal: journal)
        let second = Probe("second", journal: journal)
        let tab = RAVEBrowserTab(dataStore: .nonPersistent(), features: [first, second])
        defer { tab.close() }

        tab.setVisible(false)
        #expect(tab.hibernationBlocker == "blank")
        #expect(await loadPage(tab))
        #expect(tab.hibernationBlocker == nil)

        second.blocker = "sharing"
        first.blocker = "converting"
        #expect(tab.hibernationBlocker == "converting")
        tab.hibernationHold = "assistant"
        #expect(tab.hibernationBlocker == "assistant")
        #expect(!tab.hibernate(reason: "test"))
        tab.setVisible(true)
        #expect(tab.hibernationBlocker == "visible")
    }

    @Test func aClosedTabIsNeverRevivedAndClosesItsFeatures() {
        let journal = Journal()
        let probe = Probe("probe", journal: journal)
        let tab = RAVEBrowserTab(dataStore: .nonPersistent(), features: [probe])
        tab.load(url)
        journal.clear()
        tab.close()
        #expect(journal.entries == ["probe.attach(nil)", "probe.close"])

        tab.setVisible(true)
        #expect(tab.webView == nil)
        #expect(tab.hibernationBlocker == "closed")
    }

    @Test func navigatingAHibernatedTabGoesToTheNewPage() {
        let tab = RAVEBrowserTab(dataStore: .nonPersistent())
        defer { tab.close() }
        tab.load(url)
        tab.setVisible(false)
        tab.hibernate(reason: "test")

        let elsewhere = URL(string: "https://example.invalid/elsewhere")!
        tab.load(elsewhere)

        #expect(!tab.isHibernated)
        #expect(tab.url == elsewhere)
    }

    /// Only a tab whose app passed a sweeper takes part, and only hidden,
    /// idle ones are taken.
    @Test func sweepingHibernatesOnlyTheEligible() async {
        let sweeper = RAVETabHibernation()
        var reported: [Int] = []
        sweeper.onHibernated = { count, _ in reported.append(count) }
        let hidden = RAVEBrowserTab(dataStore: .nonPersistent(), hibernation: sweeper)
        let visible = RAVEBrowserTab(dataStore: .nonPersistent(), hibernation: sweeper)
        let unregistered = RAVEBrowserTab(dataStore: .nonPersistent())
        defer {
            hidden.close()
            visible.close()
            unregistered.close()
        }
        for tab in [hidden, visible, unregistered] { #expect(await loadPage(tab)) }
        hidden.setVisible(false)
        visible.setVisible(true)
        unregistered.setVisible(false)

        let hibernated = sweeper.sweep(
            trigger: .idle, now: Date().addingTimeInterval(RAVETabHibernationPolicy.idleInterval + 60))

        #expect(hibernated == 1)
        #expect(reported == [1])
        #expect(hidden.isHibernated)
        #expect(!visible.isHibernated)
        #expect(!unregistered.isHibernated)
    }

    /// A page's typed text goes through the address boundary with the app's
    /// search template.
    @Test func typedTextSearchesOrNavigates() {
        let tab = RAVEBrowserTab(dataStore: .nonPersistent())
        defer { tab.close() }
        #expect(tab.navigate(toTypedText: "two words", searchTemplate: "https://search.invalid/?q="))
        #expect(tab.url?.absoluteString == "https://search.invalid/?q=two%20words")
        #expect(!tab.navigate(toTypedText: "   ", searchTemplate: "https://search.invalid/?q="))
    }

    @Test func theDefaultProfileIsTheSharedStore() {
        #expect(RAVEBrowserProfile.default.dataStore === WKWebsiteDataStore.default())
        let profile = RAVEBrowserProfile(id: UUID())
        #expect(!profile.isDefault)
        #expect(profile.dataStore !== WKWebsiteDataStore.default())
        #expect(profile.dataStore.isPersistent)
    }
}
#endif
