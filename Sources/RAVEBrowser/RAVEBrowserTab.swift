/*
 RAVEBrowser — one tab: a WKWebView with the quirk handling every app that
 shows web pages runs into, and a seam for what the app does to its pages.

 Raven's `BrowserTab`, split 2026-10-17 into this generic core and Raven's own
 features (`RAVEPageFeature`). The rationale below is Raven's, measured there.

 **A tab owns its WKWebView for its whole life.** That is the single most
 important thing in this file, and it is the pattern Spatial Stash's
 `WebPageWindowModel` established for a different reason: a WebView whose
 lifetime is tied to SwiftUI view identity gets torn down and rebuilt whenever
 the view tree churns, losing scroll position, form state, logins and any
 in-page JS. In a pinned-page app that meant a dashboard reloading when you
 looked away. In a browser it would mean **switching tabs reloads the page**,
 which is not a browser. Show it with `RAVEWebViewHost`, which creates nothing
 and only re-parents whichever web view is current.

 What is deliberately *not* copied from that prior art: the interaction gate.
 Spatial Stash blocks input on a pinned page because visionOS paints gaze-hover
 highlights inside web content and that is distracting on a page used as
 decoration. A browser is the opposite — it is the thing the user is looking
 at, and the highlights are how they know what they are about to click.

 **A tab owns its WKWebView for its whole life — but not necessarily the same
 one.** The sentence above is about view-tree churn, and it still holds: nothing
 SwiftUI does can cost a tab its page. What a tab *does* give up, deliberately,
 is a web view nobody has looked at for half an hour, or one the system is
 under pressure to reclaim (`RAVETabHibernation`). Hibernating archives
 `interactionState`, drops the `WKWebView` — which is what ends its content
 process, the only part of a tab that costs hundreds of megabytes — and builds
 a fresh one on selection, restoring the back/forward list and scroll position
 while the page itself refetches. To the user that is a tab that reloads when
 they come back to it, which is what Safari does and what Raven's jetsam
 report from 2026-09-21 says it should have been doing.

 Three things make that cheap rather than a rebuild of the world:

 - **The `WKUserContentController` is the tab's, not the web view's.** Every
   user script and every feature's message handler is registered on it once,
   at birth, and each new web view is configured with that same controller. So
   hibernation is not a re-injection.
 - **The features outlive the web view.** Each holds it weakly and is handed
   the new one through `attach(to:)`, so they stay the same objects and
   nothing in the app's UI has to know this happened.
 - **A hibernated tab still answers for itself.** `url` and `title` are the
   tab's own state, so a tab chip reads normally and an address bar is right
   before a single byte is fetched — which is also what makes restoring a
   window's tabs lazily possible: a restored tab is simply born hibernated.

 **A same-document navigation fires no navigation-delegate callback** — no
 provisional start, no commit, no finish — so a tab that syncs only from the
 delegate shows the address the document was first loaded with forever. On an
 SPA that is most of the addresses the user ever wants: every YouTube video
 after the first is a `pushState`, and Raven's bar sat on `youtube.com` with no
 way to copy the real link. Hence the KVO on `url`, `title`, `canGoBack`,
 `canGoForward` and `estimatedProgress`; the delegate stays for what KVO
 cannot see (load start and finish, errors, process deaths).
 */

#if canImport(WebKit)
import Foundation
import Observation
import RAVECamera
import WebKit

@MainActor
@Observable
public final class RAVEBrowserTab: Identifiable {
    public let id: UUID

    /// What a tab restored from a previous launch knows before it has a page.
    public struct Snapshot: Equatable, Sendable {
        public var url: URL?
        public var title: String

        public init(url: URL?, title: String = "") {
            self.url = url
            self.title = title
        }
    }

    // MARK: - Observable page state

    public private(set) var title: String = ""
    public private(set) var url: URL?
    public private(set) var isLoading = false
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    /// 0...1 while loading. WebKit's estimate is coarse but monotonic, which is
    /// all a progress bar needs.
    public private(set) var progress: Double = 0
    /// Set when a navigation fails, cleared when the next one starts.
    public private(set) var loadError: String?
    /// WebKit's own account of whether this page holds a camera or a
    /// microphone — the only signal that sees a capture WebKit muted without
    /// telling the page. `.none` while there is no page.
    public private(set) var cameraCaptureState: WKMediaCaptureState = .none
    public private(set) var microphoneCaptureState: WKMediaCaptureState = .none

    /// What an address bar shows for this tab while it is not being edited.
    public var displayURL: String { url.map(RAVEAddressInput.displayText) ?? "" }

    /// A tab with no page yet — a freshly opened one, before its first load.
    public var isBlank: Bool { url == nil && !isLoading }

    /// The page, or nil while this tab is hibernated (and before the first
    /// wake of a tab restored from a previous launch).
    ///
    /// Observed: a tab that wakes builds a *different* `WKWebView`, and the
    /// view showing it has to hear about that. Read it in a view's body and
    /// hand it to `RAVEWebViewHost`, so the swap is an ordinary SwiftUI update.
    public private(set) var webView: WKWebView?

    /// Every user script and every feature's message handler lives here, added
    /// once at birth and shared by each `WKWebView` this tab builds — see the
    /// header. Also where an app's compiled content rule lists belong, so
    /// they too survive a hibernation.
    @ObservationIgnored public let controller: WKUserContentController

    /// Fixed at creation: a `WKWebView` cannot change its data store, so
    /// neither can a tab. Kept because every web view this tab builds needs it.
    @ObservationIgnored public let dataStore: WKWebsiteDataStore

    /// The app's features, in the order their scripts were installed.
    @ObservationIgnored public let features: [any RAVEPageFeature]

    // MARK: - Hooks for the app

    /// The page asked for a new tab (`target="_blank"`, `window.open`). Whoever
    /// owns the tab list decides; with no hook the link opens in place, since a
    /// web view that returns no new view silently drops it.
    @ObservationIgnored public var onOpenInNewTab: ((URL) -> Void)?
    /// `url` changed — link clicks and same-document navigations included,
    /// which no navigation-delegate callback sees. `sameDocument` is true for a
    /// `pushState`-style change with no load in flight. Nothing may assume it
    /// is rare: an SPA rewrites its address continuously.
    @ObservationIgnored public var onURLChanged: ((_ sameDocument: Bool) -> Void)?
    /// A navigation started, after the features heard `pageWillNavigate()`.
    @ObservationIgnored public var onLoadStarted: (() -> Void)?
    /// A navigation finished (Raven records history here).
    @ObservationIgnored public var onLoadFinished: (() -> Void)?
    /// The content process died, before the tab reloads or owes the reload.
    @ObservationIgnored public var onContentProcessTerminated: (() -> Void)?
    /// `cameraCaptureState` or `microphoneCaptureState` changed.
    @ObservationIgnored public var onCaptureStateChanged: (() -> Void)?
    /// A page asked for the camera or the microphone. Nil answers `.prompt`:
    /// WebKit's own permission UI, which is what a browser should do, since
    /// the site asking is whatever the user navigated to and deciding on their
    /// behalf would hand any page the camera silently.
    @ObservationIgnored public var mediaCapturePermission: ((
        _ origin: WKSecurityOrigin, _ type: WKMediaCaptureType
    ) -> WKPermissionDecision)?

    /// A reason the app is holding this tab awake (Raven: its assistant is
    /// driving the page), or nil.
    public var hibernationHold: String?

    // MARK: - Lifecycle state

    /// No web view and no content process — see the header.
    public private(set) var isHibernated: Bool

    /// Whether this tab is on screen, as its app reports it (`setVisible`). A
    /// visible tab is never hibernated, and becoming visible is what wakes one.
    public private(set) var isVisible = false

    /// When this tab was last on screen — the clock hibernation runs on. A tab
    /// is born hidden (an app makes it visible a moment later if it is the one
    /// being opened), so this starts set rather than nil.
    @ObservationIgnored public private(set) var hiddenSince: Date? = Date()

    @ObservationIgnored private let delegate = Delegate()
    @ObservationIgnored private let userAgentTail: String?
    @ObservationIgnored private let isInspectable: Bool
    /// KVO on the web view's own properties — see the header for why it is not
    /// merely a convenience over the navigation delegate.
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// `WKWebView.interactionState` as of the last hibernation: the
    /// back/forward list and scroll position, handed back to the web view
    /// built on wake. Held in memory only — persisting an opaque blob of
    /// unbounded size that WebKit may stop accepting across OS versions is a
    /// different bargain from minutes of it under one OS build.
    @ObservationIgnored private var archivedInteractionState: Any?
    /// The content process died while this tab was not on screen, so the
    /// reload is owed rather than done — see `contentProcessTerminated`.
    @ObservationIgnored private var needsReload = false
    /// Set by `close()`, so a torn-down tab still held briefly by something
    /// (the hibernator's weak list, an animation) is never revived.
    @ObservationIgnored private var isClosed = false

    /// Appended to WKWebView's default user agent to complete it into Safari's.
    ///
    /// The default ends `… AppleWebKit/605.1.15 (KHTML, like Gecko)`; Safari's
    /// continues `Version/<major>.0 Safari/605.1.15`, and that tail is the whole
    /// difference. Without it the UA names no browser at all, which is how
    /// Google Meet arrives at "your browser doesn't support Meet" for an engine
    /// that is literally Safari's — its capability report shows nothing
    /// functionally missing. `605.1.15` is WebKit's own build number, static
    /// across every Apple platform and not a version to keep current.
    ///
    /// The Safari version is taken from the OS major version because Apple
    /// aligned them at 26, so this tracks OS updates instead of rotting into an
    /// implausibly old claim. If that alignment ever breaks the number goes
    /// slightly wrong in the harmless direction: sniffers threshold on a
    /// minimum, and the name is what they actually key on.
    ///
    /// This is claiming an identity, not just quieting a gate: sites hand the
    /// tab their Safari code paths, which is the intent, because it runs the
    /// engine those paths were written for.
    nonisolated public static var safariUserAgentTail: String {
        "Version/\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).0 Safari/605.1.15"
    }

    deinit { RAVELiveObjects.release("RAVEBrowserTab") }

    /// - Parameters:
    ///   - dataStore: a profile's store (`RAVEBrowserProfile.dataStore`), or
    ///     `.nonPersistent()` for a page that keeps nothing. Shared across
    ///     every tab of a profile, so a login in one tab is a login in all.
    ///   - features: installed in this order, which is the script order — see
    ///     `RAVEPageFeature`. Build them first and keep the references you need.
    ///   - restoring: a tab coming back from a previous launch. It is born
    ///     hibernated — knowing its address and title but holding no web view
    ///     and no content process — and loads the first time it is shown.
    ///     Restoring fifteen tabs must not mean launching fifteen content
    ///     processes, which is exactly what it used to mean in Raven.
    ///   - hibernation: the sweeper that may take this tab's page while it is
    ///     hidden (`.shared`), or nil for a tab that is never hibernated by
    ///     anyone but its app. Only for an app that reports `setVisible`.
    ///   - userAgentTail: appended to WebKit's user agent; nil leaves it alone.
    ///   - isInspectable: from a paired Mac's Safari (Develop menu). The
    ///     instrument that cracked Meet's join-page stall in Raven — a live
    ///     console into the real page beats a build-log-rejoin loop by an order
    ///     of magnitude — so it defaults on, in Release too.
    public init(
        id: UUID = UUID(),
        dataStore: WKWebsiteDataStore,
        features: [any RAVEPageFeature] = [],
        restoring: Snapshot? = nil,
        hibernation: RAVETabHibernation? = nil,
        userAgentTail: String? = RAVEBrowserTab.safariUserAgentTail,
        isInspectable: Bool = true
    ) {
        RAVELiveObjects.retain("RAVEBrowserTab")
        self.id = id
        self.dataStore = dataStore
        self.features = features
        self.userAgentTail = userAgentTail
        self.isInspectable = isInspectable
        self.isHibernated = restoring != nil
        self.url = restoring?.url
        self.title = restoring?.title ?? ""
        let controller = WKUserContentController()
        self.controller = controller

        // In the app's order, once. See `RAVEPageFeature` for why the order is
        // the app's to write down.
        for feature in features { feature.install(on: controller) }

        delegate.onNavigationStateChanged = { [weak self] in self?.syncFromWebView() }
        delegate.onLoadStarted = { [weak self] in self?.loadStarted() }
        delegate.onLoadFinished = { [weak self] in
            guard let self else { return }
            isLoading = false
            progress = 0
            syncFromWebView()
            onLoadFinished?()
        }
        delegate.onLoadFailed = { [weak self] message in
            guard let self else { return }
            isLoading = false
            progress = 0
            loadError = message
            syncFromWebView()
        }
        delegate.onOpenInNewTab = { [weak self] url in
            guard let self else { return }
            if let onOpenInNewTab { onOpenInNewTab(url) } else { webView?.load(URLRequest(url: url)) }
        }
        delegate.onContentProcessTerminated = { [weak self] in self?.contentProcessTerminated() }
        delegate.mediaCapturePermission = { [weak self] origin, type in
            self?.mediaCapturePermission?(origin, type) ?? .prompt
        }

        // A restored tab has no page until it is shown; everything above this
        // line is what it *does* have, which is why a chip and an address bar
        // read correctly in the meantime.
        if restoring == nil { buildPage() }
        // Weakly held, so this is not a reason for a tab to stay alive.
        hibernation?.register(self)
    }

    /// Builds this tab's `WKWebView` and everything that hangs off one, and
    /// hands it to the features. Called at birth for an ordinary tab, and again
    /// on every wake — the controller, the features and the delegate are the
    /// tab's, so this really is only the view and its wiring.
    private func buildPage() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        // The one controller this tab ever has: its user scripts and every
        // feature's message handler are already on it.
        configuration.userContentController = controller
        #if !os(macOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        // Raven lifts frames out of a playing <video>; a gesture requirement
        // would mean that extraction could never start itself, and a call
        // page's remote tiles would wait for a tap.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // `.desktop` deliberately. It does *not* change the user agent on
        // visionOS — `.recommended` reports the same "Intel Mac OS X" string,
        // measured — so this is about layout hints, not UA sniffing.
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        // Appended rather than replacing the whole UA via `customUserAgent`, so
        // the platform and WebKit build stay whatever WebKit says they are and
        // keep tracking OS updates on their own.
        if let userAgentTail { configuration.applicationNameForUserAgent = userAgentTail }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = isInspectable
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        webView.allowsBackForwardNavigationGestures = true
        #if canImport(UIKit)
        // Let the page's own background show; a browser should look like the
        // site, not like the app.
        webView.isOpaque = true
        // The system find bar (`presentFind()` below) — its own UIKit chrome,
        // already gaze/pinch-tuned, so there is no SwiftUI overlay to build.
        webView.isFindInteractionEnabled = true
        #endif

        for feature in features { feature.attach(to: webView) }

        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.progress = webView.estimatedProgress }
            },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.handleURLChanged() }
            },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncFromWebView() }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncFromWebView() }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncFromWebView() }
            },
            // Capture state is WebKit's own account of whether this page holds
            // a camera or a microphone, and it is the only signal that sees a
            // microphone WebKit muted without telling the page.
            webView.observe(\.microphoneCaptureState, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.captureStateChanged(webView) }
            },
            webView.observe(\.cameraCaptureState, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.captureStateChanged(webView) }
            },
        ]

        self.webView = webView
    }

    private func captureStateChanged(_ webView: WKWebView) {
        cameraCaptureState = webView.cameraCaptureState
        microphoneCaptureState = webView.microphoneCaptureState
        onCaptureStateChanged?()
    }

    /// Tear down eagerly rather than waiting for ARC: a live WKWebView keeps a
    /// content process alive, and a window closed with ten tabs open should
    /// give those back immediately.
    public func close() {
        // `unloading:` is what gives a live call its `pagehide` — and there
        // must be no `stopLoading()` after it. The full story is on
        // `releasePage(unloading:)`, which hibernation shares.
        isClosed = true
        releasePage(unloading: true)
        // The controller retains every feature's message handler, so each
        // has to be removed explicitly or the tab's teardown leaks the chain.
        for feature in features { feature.close() }
        onOpenInNewTab = nil
        onURLChanged = nil
        onLoadStarted = nil
        onLoadFinished = nil
        onContentProcessTerminated = nil
        onCaptureStateChanged = nil
    }

    // MARK: - Hibernation

    /// Drop this tab's web view — and with it the content process that is the
    /// only expensive thing about a tab nobody is looking at — keeping enough
    /// to put it back: the address, the title, and `interactionState` for the
    /// back/forward list and scroll position. `RAVETabHibernation` decides
    /// when; this decides whether, because the answer can change between the
    /// sweep and the call.
    ///
    /// Waking is `setVisible(true)`. Nothing wakes a tab to keep it warm —
    /// that would be the whole point, undone.
    @discardableResult
    public func hibernate(reason: String) -> Bool {
        guard !isHibernated, !isClosed, let webView else { return false }
        if let blocker = hibernationBlocker {
            RAVEBrowserLog.browser.info("""
            not hibernating \(self.host, privacy: .private(mask: .hash)): \(blocker, privacy: .public)
            """)
            return false
        }

        // Before anything navigates: this has to be the state of the page the
        // user left, not of the about:blank below.
        archivedInteractionState = webView.interactionState
        // Whatever the features know is about to stop being true — the frame
        // tokens they hold belong to a document that is going away, which is
        // exactly what this hook means everywhere else.
        for feature in features { feature.pageWillNavigate() }

        releasePage(unloading: true)
        isHibernated = true
        isLoading = false
        progress = 0
        canGoBack = false
        canGoForward = false
        needsReload = false
        RAVEBrowserLog.browser.info("""
        hibernated \(self.host, privacy: .private(mask: .hash)) (\(reason, privacy: .public))
        """)
        return true
    }

    /// Build a web view again and put the page back where it was. Cheap on
    /// paper and a full page load in practice — which is the trade hibernation
    /// makes, and why nothing but becoming visible triggers it.
    public func wake(reason: String) {
        resumePage(reason: reason, restoringHistory: true)
    }

    private func resumePage(reason: String, restoringHistory: Bool) {
        guard isHibernated, !isClosed, webView == nil else { return }
        isHibernated = false
        if !restoringHistory { archivedInteractionState = nil }
        buildPage()
        guard let webView else { return }

        if let state = archivedInteractionState {
            webView.interactionState = state
            archivedInteractionState = nil
        }
        RAVEBrowserLog.browser.info("""
        woke \(self.host, privacy: .private(mask: .hash)) (\(reason, privacy: .public))
        """)
        guard restoringHistory else { return }
        // Restoring an interaction state normally starts loading its current
        // item by itself. A restored tab has no state at all (only a URL), and
        // a state WebKit declines leaves nothing in the back/forward list — so
        // check rather than assume, or a woken tab sits blank forever.
        guard !webView.isLoading, webView.url == nil else { return }
        if webView.backForwardList.currentItem != nil {
            isLoading = true
            webView.reload()
        } else if let url {
            isLoading = true
            webView.load(URLRequest(url: url))
        }
    }

    /// Whether this tab is on screen. Hibernation runs off this, and so does
    /// the reload a dead content process left owed. Report a backgrounded
    /// scene as hidden, but an inactive one (a window still on screen) as
    /// visible: putting a page the wearer is reading on the hibernation clock
    /// is the one outcome this must never produce.
    public func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        guard visible else {
            hiddenSince = Date()
            return
        }
        hiddenSince = nil
        if isHibernated {
            wake(reason: "shown")
        } else if needsReload {
            needsReload = false
            RAVEBrowserLog.browser.info("""
            reloading \(self.host, privacy: .private(mask: .hash)) after its content process died
            """)
            reload()
        }
    }

    /// Why this tab must not be hibernated right now, or nil if it may be.
    ///
    /// Everything here is something a hibernation would visibly break, and the
    /// list is the difference between a browser and a memory optimiser: a tab
    /// on a call, presenting, or playing audio is doing work whether or not
    /// anyone is looking at it. The features' reasons come in their order,
    /// after the app's own hold.
    public var hibernationBlocker: String? {
        if isClosed { return "closed" }
        if isVisible { return "visible" }
        if let hibernationHold { return hibernationHold }
        guard let webView else { return "no page" }
        // Nothing to restore and nothing to save: a blank tab has no content
        // process worth speaking of anyway.
        if url == nil { return "blank" }
        for feature in features {
            if let blocker = feature.hibernationBlocker { return blocker }
        }
        if webView.cameraCaptureState != .none { return "camera" }
        if webView.microphoneCaptureState != .none { return "microphone" }
        if Self.isPlayingAudio(webView) { return "playing audio" }
        return nil
    }

    /// A tab playing music in the background is the one case where "nobody is
    /// looking at it" is not the same as "nobody is using it", and WebKit has
    /// no public API for it — `_isPlayingAudio` is SPI, read by key with a
    /// `responds(to:)` guard. A WebKit that stops answering costs a music tab
    /// its page, not a crash.
    private static func isPlayingAudio(_ webView: WKWebView) -> Bool {
        let key = "_isPlayingAudio"
        guard webView.responds(to: NSSelectorFromString(key)) else { return false }
        return (webView.value(forKey: key) as? NSNumber)?.boolValue ?? false
    }

    /// Host only — a log line naming a tab should not carry its query string.
    public var host: String { url?.host() ?? url?.absoluteString ?? "blank tab" }

    /// Everything that belongs to one web view, undone. Shared by `close()`
    /// and `hibernate(reason:)`; what separates them is that the features and
    /// the controller survive a hibernation.
    ///
    /// - Parameter unloading: navigate to `about:blank` first. Deallocating a
    ///   WKWebView out from under a still-loaded document never fires
    ///   pagehide/unload, so a live WebRTC call (Meet, any getUserMedia page)
    ///   never gets the chance to run its own hangup logic and the far end
    ///   sees an abrupt ICE/DTLS timeout instead of a clean disconnect.
    ///   Navigating away first triggers that lifecycle for real, exactly as a
    ///   real browser closing a tab would.
    ///
    ///   There must be no `stopLoading()` anywhere after it. There was one, and
    ///   it canceled this exact navigation before WebKit's out-of-process
    ///   machinery necessarily got to run the old page's unload/pagehide
    ///   handlers — starting a new load already supersedes whatever was in
    ///   flight, so there was never anything left to stop. It went unnoticed
    ///   because the race usually resolved in our favor for the *active* tab
    ///   (its WebContent process is composited and prioritized); closing a
    ///   backgrounded tab — deprioritized, exactly as WebKit does to
    ///   non-visible content — lost that race far more often, which is what a
    ///   call staying live with a black frame until Meet's own timeout
    ///   actually was.
    private func releasePage(unloading: Bool) {
        guard let webView else { return }
        // Before the unload below, not after: `WKWebView.url` changes the
        // instant `load` is called, synchronously, so a live `url` observation
        // would see about:blank, write it into this tab's address and persist
        // it as the page to restore. Measured — it cost a test the URL it had
        // just loaded.
        for observation in observations { observation.invalidate() }
        observations = []
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        if unloading {
            webView.load(URLRequest(url: URL(string: "about:blank")!))
        }
        for feature in features { feature.attach(to: nil) }
        cameraCaptureState = .none
        microphoneCaptureState = .none
        // The last strong reference the tab holds: releasing it is what ends
        // the content process, which is the entire point of hibernating.
        self.webView = nil
    }

    // MARK: - Navigation

    public func load(_ url: URL) {
        loadError = nil
        self.url = url
        // A tab asked to go somewhere is a tab that needs a page — but not the
        // page it was hibernated on: restoring that history first would load a
        // document the user is navigating away from, for nothing.
        resumePage(reason: "navigating", restoringHistory: false)
        isLoading = true
        webView?.load(URLRequest(url: url))
    }

    /// Navigate to whatever the user typed — a URL if it parses as one, a
    /// search otherwise. See `RAVEAddressInput`, which is the security
    /// boundary for what an address bar may load.
    @discardableResult
    public func navigate(toTypedText text: String, searchTemplate: String) -> Bool {
        guard let url = RAVEAddressInput.resolve(text, searchTemplate: searchTemplate) else { return false }
        load(url)
        return true
    }

    public func goBack() { webView?.goBack() }
    public func goForward() { webView?.goForward() }

    public func stop() {
        webView?.stopLoading()
        isLoading = false
        progress = 0
    }

    public func reload() {
        loadError = nil
        // A hibernated tab has no page to reload; waking it *is* the reload,
        // history and all.
        if isHibernated {
            wake(reason: "reload")
            return
        }
        // A failed or never-started load leaves no history entry to reload;
        // re-request the last URL we know about instead of doing nothing.
        if webView?.url == nil, let url {
            load(url)
        } else {
            isLoading = true
            webView?.reload()
        }
    }

    #if canImport(UIKit)
    /// Presents the system find bar over the page — `UIFindInteraction`'s own
    /// UIKit chrome, not a SwiftUI overlay an app would otherwise have to build
    /// and keep gaze/pinch-tuned by hand.
    public func presentFind() {
        webView?.findInteraction?.presentFindNavigator(showingReplace: false)
    }
    #endif

    // MARK: - Internals

    private func loadStarted() {
        isLoading = true
        loadError = nil
        // The page being navigated away from owns everything the features
        // know about it.
        for feature in features { feature.pageWillNavigate() }
        onLoadStarted?()
        syncFromWebView()
    }

    /// The content process died. Reloading it here and now is wrong for a tab
    /// nobody is looking at: WebKit or jetsam just reclaimed a process
    /// precisely because memory was short, and re-spawning it immediately
    /// spends that memory again on a page with no viewer — the pressure that
    /// killed one tab then walks down the rest. Safari reloads a discarded tab
    /// when it comes back on screen, and so does this.
    private func contentProcessTerminated() {
        onContentProcessTerminated?()
        if isVisible {
            reload()
        } else {
            needsReload = true
            isLoading = false
            progress = 0
        }
    }

    /// The address changed. Computed before syncing: a change with a page and
    /// no load in flight is the SPA case, which an app handles differently —
    /// it re-asks the page rather than treating it as a new document.
    private func handleURLChanged() {
        let sameDocument = webView?.url != nil && !isLoading
        syncFromWebView()
        onURLChanged?(sameDocument)
    }

    private func syncFromWebView() {
        guard let webView else { return }
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        // Keep the last good title rather than blanking a tab strip during a
        // load — WebKit reports nil until the new document has a <title>.
        if let pageTitle = webView.title, !pageTitle.isEmpty { title = pageTitle }
        if let current = webView.url { url = current }
    }

    // MARK: - Delegate

    /// Navigation / UI delegate. A separate `NSObject` rather than the model
    /// itself, so `@Observable` never has to sit on an NSObject; it forwards
    /// everything through main-actor closures.
    ///
    /// **The closure attributes on the optional methods are load-bearing.** In
    /// Swift 6 mode the SDK types WebKit's completion handlers `@MainActor
    /// @Sendable`; implement one with a plain closure type and it becomes a
    /// *different* method that "nearly matches" the optional requirement — a
    /// warning buried in build output, no @objc exposure, never called,
    /// everything compiles and tests green. Three methods in Raven shipped that
    /// way (`decidePolicyFor navigationAction`, `navigationResponse`, and the
    /// capture-permission one). When adding any optional ObjC protocol method,
    /// copy the SDK's exact closure attributes and grep full xcodebuild output
    /// for "nearly matches"; a `responds(to:)` probe compiled with
    /// `-swift-version 6` settles any doubt (Swift 5 mode lies).
    final class Delegate: NSObject, WKNavigationDelegate, WKUIDelegate {
        var onNavigationStateChanged: (() -> Void)?
        var onLoadStarted: (() -> Void)?
        var onLoadFinished: (() -> Void)?
        var onLoadFailed: ((String) -> Void)?
        var onOpenInNewTab: ((URL) -> Void)?
        var onContentProcessTerminated: (() -> Void)?
        var mediaCapturePermission: ((WKSecurityOrigin, WKMediaCaptureType) -> WKPermissionDecision)?

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            RAVEBrowserLog.browser.info("load started \(webView.url?.absoluteString ?? "?", privacy: .private)")
            onLoadStarted?()
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            onNavigationStateChanged?()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            RAVEBrowserLog.browser.info("load finished \(webView.url?.absoluteString ?? "?", privacy: .private)")
            onLoadFinished?()
        }

        /// A page whose *document* is a 404 or a 403 still loads, still fires
        /// `didFinish`, and still reports a title — so the status code is the
        /// only place that failure is visible. Subresources do not come through
        /// here; this is the document itself.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
        ) {
            if let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400 {
                RAVEBrowserLog.browser.error("""
                HTTP \(http.statusCode, privacy: .public) for \
                \(http.url?.absoluteString ?? "?", privacy: .private)
                """)
            }
            decisionHandler(.allow)
        }

        /// The content process died — the page goes blank with no navigation
        /// error anywhere, which is indistinguishable from "the site rendered
        /// nothing" unless it is said out loud.
        ///
        /// This is also the only hard evidence of that process running out of
        /// memory: WebKit kills a WebContent process itself past its own limit,
        /// leaving no jetsam report and no crash log. Whether to reload is the
        /// tab's call, not this delegate's: doing it here unconditionally
        /// re-spawned a process the system had just reclaimed, for a page
        /// nobody was looking at.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            RAVEBrowserLog.browser.error("""
            content process terminated for \(webView.url?.absoluteString ?? "?", privacy: .private)
            """)
            onContentProcessTerminated?()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            reportFailure(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            reportFailure(error)
        }

        /// A page asked for the camera or the microphone. The tab's
        /// `mediaCapturePermission` decides; with none, `.prompt`.
        ///
        /// This method spent its first weeks in Raven as a Swift 6 near-miss
        /// (see above) — never called, its log line never printed — and camera
        /// prompts appeared anyway. So WebKit's real default is prompting, not
        /// denying. Kept because "the page asked" belongs in the record, and
        /// because a browser should state this policy rather than inherit it.
        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
        ) {
            let decision = mediaCapturePermission?(origin, type) ?? .prompt
            RAVEBrowserLog.browser.info("""
            capture requested type=\(type.rawValue, privacy: .public) \
            by \(origin.protocol, privacy: .public)://\(origin.host, privacy: .private(mask: .hash)) \
            → \(decision.rawValue, privacy: .public)
            """)
            decisionHandler(decision)
        }

        /// `target="_blank"` and `window.open` — WebKit returns no view by
        /// default, which reads as a dead link. The tab hands the URL to the
        /// app, which has somewhere to put it.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                onOpenInNewTab?(url)
            }
            return nil
        }

        private func reportFailure(_ error: any Error) {
            let nsError = error as NSError
            // Cancelled navigations are routine — a redirect, or the user
            // clicking through before the previous load settled — and are not
            // worth showing anyone.
            guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else {
                return
            }
            // Domain and code alongside the message: `localizedDescription` for
            // a TLS failure and for a refused connection read almost the same,
            // and the numbers are what distinguish them.
            RAVEBrowserLog.browser.error("""
            navigation failed \(nsError.domain, privacy: .public)/\(nsError.code, privacy: .public): \
            \(nsError.localizedDescription, privacy: .private) \
            url=\(nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String ?? "?", privacy: .private)
            """)
            onLoadFailed?(nsError.localizedDescription)
        }
    }
}
#endif
