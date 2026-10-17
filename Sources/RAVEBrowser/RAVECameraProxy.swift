/*
 RAVEBrowser — the Swift half of the camera proxy: a page's camera, painted
 from a feed the app chooses.

 Raven's `CameraReplayBridge` relay, lifted 2026-10-17. The replay ring, the
 reverser and the preview window stayed Raven's; they ride on this through
 `RAVECameraProxyTap` (every unit, every configuration, the feed's start and
 stop) and the substitution calls (send the page something else for a while).
 Findings below were measured in Raven.

 One per tab, a `RAVEPageFeature`, and the shape is Raven's screen-share
 bridge: a non-isolated handler forwarding into the main actor, commands
 replayed into the `WKFrameInfo` the page's messages arrived on. Meet's call UI
 can live in an iframe, and a command evaluated against the main frame would
 silently do nothing on exactly the sites this exists for.

 **The feed.** When the page asks (`nativeStart`), this starts a
 `RAVECameraFeed` — the app's own capture session for the Persona, a virtual
 camera's subscription for the avatar or a virtual device — and relays its
 access units into the page as base64 chunks. The frames are a delta chain, so
 the relay never drops one frame: it drops everything until the next keyframe
 and resumes whole. How an ending is handled is the mode's policy:

 - **Persona**: device-exclusive (one live feed per process; a second tab is
   told `nativeEnd` and paints from WebKit's camera), a transient failure gets
   a bounded silent retry, and every final ending is a fallback on the page
   side, never a black tile.
 - **Avatar and virtual device**: shared by every tab that asks, and they
   **fail closed**. On the page a fallback is WebKit's camera, which is the
   face the wearer chose not to send; so every ending is an outage instead.
   The page is told `nativeOffline` (it paints an offline card on the same
   proxy track) and this side subscribes again every `sharedRetryDelay` for as
   long as the page wants the camera, logging the outage once and the
   recovery once.

 **Every millisecond this relay holds a frame is lip desync at the far end.**
 The page's audio goes from WebKit's capture straight into WebRTC; the video
 gets its capture timestamp only when the decoded frame lands on the published
 canvas, and WebRTC syncs the two by those timestamps. So the relay is tuned
 for latency, not throughput, and it differs from Raven's screen-share relay in
 three ways that came out of exactly that symptom:

 - The in-flight window is 3, not 8. The window is a *queue*: once the page's
   main thread lets it fill, it stays full and every frame waits its length —
   at 30 fps eight chunks is a stable quarter second that never drains on its
   own. Three is enough to keep one chunk in each leg of the round trip.
 - Dropping asks the feed for a keyframe *now* instead of waiting out the GOP,
   so recovery is a frame rather than up to a second of freeze. While the page
   is being sent a substitute there is no encoder to ask, so the substitute
   skips to its own next keyframe instead.
 - Chunks go through `callAsyncJavaScript` with the payload as an *argument*,
   not through `evaluateJavaScript` with it embedded in the source: the page
   then receives a string value rather than parsing a 30–300 KB literal as
   JavaScript on every frame.

 The page reports per-stage latency every few seconds (`nativeLatency`), and
 this side folds in what only it can see (encode time, the main-thread hop,
 queue depth, drops). That line is how the tuning above is checked, and how
 the next regression gets localised to a stage instead of argued about.

 **Substitution** is how Raven's instant replay works and why the page cannot
 tell live from loop: between `beginSubstitution` and `endSubstitution` live
 units still reach the tap but not the page, and the app sends its own at its
 own pace through `sendSubstitute`, under the same flow control and with
 monotonic timestamps. Returning to live restores the live configuration if
 the page was left on another, and resumes on a keyframe the feed is asked
 for at once — the relay's ordinary recovery.
 */

#if canImport(WebKit)
import CryptoKit
import Foundation
import Observation
import RAVECamera
import WebKit

/// What the app sees of the relay. Every call is on the main actor, in feed
/// order; all have default empty implementations.
@MainActor
public protocol RAVECameraProxyTap: AnyObject {
    /// A feed was created and started (or, Persona, about to start capturing).
    func cameraProxyFeedDidStart(_ proxy: RAVECameraProxy)
    /// A feed's decoder configuration landed: its first (`previous == nil`),
    /// or a change. Units recorded under a different previous configuration
    /// cannot be decoded with this one. Called before the page is sent it, so
    /// a running substitution can still be ended against the old one.
    func cameraProxy(_ proxy: RAVECameraProxy,
                     didConfigure configuration: RAVEH264Encoder.DecoderConfiguration,
                     width: Int, height: Int,
                     previous: RAVEH264Encoder.DecoderConfiguration?)
    /// Every access unit the feed produced, in order, before the relay decides
    /// whether the page gets it — dropping, substituting, or the page's
    /// camera switched off (`pageCameraEnabled`) notwithstanding.
    func cameraProxy(_ proxy: RAVECameraProxy, didReceive unit: RAVECameraProxy.AccessUnit,
                     ptsMicroseconds: UInt64)
    /// The feed is about to stop, for any reason (the page released it, a
    /// navigation, an outage, a restart, the tab closing). The configuration is
    /// still set; end a substitution here. No units follow until the next start.
    func cameraProxyFeedWillStop(_ proxy: RAVECameraProxy)
    /// The page switched its camera track on or off (`enabled`). Frames from a
    /// camera the page turned off must not be kept anywhere they could be
    /// sent again.
    func cameraProxy(_ proxy: RAVECameraProxy, pageCameraEnabledDidChange enabled: Bool)
    /// `isLive` may have changed.
    func cameraProxyLiveDidChange(_ proxy: RAVECameraProxy)
}

public extension RAVECameraProxyTap {
    func cameraProxyFeedDidStart(_ proxy: RAVECameraProxy) {}
    func cameraProxy(_ proxy: RAVECameraProxy, didConfigure configuration: RAVEH264Encoder.DecoderConfiguration,
                     width: Int, height: Int, previous: RAVEH264Encoder.DecoderConfiguration?) {}
    func cameraProxy(_ proxy: RAVECameraProxy, didReceive unit: RAVECameraProxy.AccessUnit,
                     ptsMicroseconds: UInt64) {}
    func cameraProxyFeedWillStop(_ proxy: RAVECameraProxy) {}
    func cameraProxy(_ proxy: RAVECameraProxy, pageCameraEnabledDidChange enabled: Bool) {}
    func cameraProxyLiveDidChange(_ proxy: RAVECameraProxy) {}
}

/// A camera that exists only in the page: what `enumerateDevices` lists and
/// every getter on the proxy track names, in `RAVECameraProxy.Mode.virtualDevice`.
public struct RAVEVirtualCaptureDevice: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// The only kind implemented. The page script is written generic over
        /// the kind so a microphone could follow.
        case videoInput = "videoinput"
    }

    public var kind: Kind
    public var label: String
    public var deviceId: String
    public var groupId: String

    /// - Parameters:
    ///   - label: what a device picker shows ("Avatar").
    ///   - deviceId: stable across launches, so a site that remembers the
    ///     camera it was last given finds it again. Derived from the label
    ///     when nil.
    public init(kind: Kind = .videoInput, label: String, deviceId: String? = nil, groupId: String? = nil) {
        self.kind = kind
        self.label = label
        self.deviceId = deviceId ?? Self.stableID("rave.virtual-device.\(kind.rawValue).\(label)")
        self.groupId = groupId ?? Self.stableID("rave.virtual-device.group.\(label)")
    }

    /// 64 hex digits, the shape WebKit's own (per-origin salted) ids take.
    private static func stableID(_ seed: String) -> String {
        SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
@Observable
public final class RAVECameraProxy: RAVEPageFeature {
    /// Whose picture the page's camera shows, and what happens when it fails.
    public enum Mode: Equatable, Sendable {
        /// The wearer's own camera. `nativeCapture`: painted from the app's
        /// capture session (the sensor's native 1920×1080) rather than from the
        /// track WebKit grants. Every failure degrades to WebKit's camera.
        case persona(nativeCapture: Bool)
        /// Another app's camera (Raven: spatial-ai-character's avatar on
        /// loopback). The real `getUserMedia` still runs first, for WebKit's
        /// per-site prompt and the track's identity, and its video track is
        /// stopped before the feed starts. Fails closed.
        case avatar
        /// A camera that exists only in the page — see
        /// `RAVEVirtualCaptureDevice`. WebKit is never asked for a camera; a
        /// combined request sends it the audio half only. Fails closed.
        case virtualDevice(RAVEVirtualCaptureDevice)

        /// Not the wearer's camera: never falls back to WebKit's.
        public var failsClosed: Bool {
            if case .persona = self { return false }
            return true
        }

        /// Whether a WebRTC watchdog may probe the real camera under this
        /// proxy (`RAVEWebRTCRecoveryScript(probeCamera:)`). Only the Persona
        /// has one worth probing; the others would keep it running for nothing.
        public var allowsRealCameraProbe: Bool { !failsClosed }
    }

    /// What a fail-closed mode paints on the page's track while its feed is
    /// away: a dark frame, a title and an optional hint. Repainted every
    /// second so a far end that joins late still gets a frame.
    public struct OfflineCard: Equatable, Sendable {
        public var title: String
        public var hint: String

        public init(title: String = "Camera offline", hint: String = "") {
            self.title = title
            self.hint = hint
        }
    }

    /// One encoded frame as the feed produced it, with its base64 form kept
    /// alongside: that is what crosses the JS bridge, and encoding it once,
    /// off the main actor, beats re-encoding a 300 KB keyframe on every pass of
    /// a replay loop.
    public struct AccessUnit: Sendable {
        public let data: Data
        public let base64: String
        public let isKeyframe: Bool

        public init(data: Data, base64: String, isKeyframe: Bool) {
            self.data = data
            self.base64 = base64
            self.isKeyframe = isKeyframe
        }

        public init(data: Data, isKeyframe: Bool) {
            self.init(data: data, base64: data.base64EncodedString(), isKeyframe: isKeyframe)
        }
    }

    public let mode: Mode
    /// Width ÷ height the page publishes at.
    public let framingAspect: Double
    public let offlineCard: OfflineCard

    /// The page is publishing the proxy and this side's feed is wanted: there
    /// is a camera on this tab that the app is painting.
    public private(set) var isLive = false
    /// The page's `enabled` switch on its camera track. Resets to true whenever
    /// the proxy track's life ends.
    public private(set) var pageCameraEnabled = true
    /// The feed's current decoder configuration and frame size — what the
    /// page's decoder holds while live.
    public private(set) var decoderConfiguration: RAVEH264Encoder.DecoderConfiguration?
    @ObservationIgnored public private(set) var frameSize: (width: Int, height: Int)?
    /// Between `beginSubstitution` and `endSubstitution`.
    public private(set) var isSubstituting = false

    /// The app's view of the relay — see `RAVECameraProxyTap`. Weak.
    @ObservationIgnored public weak var tap: (any RAVECameraProxyTap)?

    @ObservationIgnored private let makeFeed: @MainActor () -> any RAVECameraFeed
    /// The tab's current web view, or nil while it is hibernated.
    @ObservationIgnored private weak var webView: WKWebView?
    @ObservationIgnored private weak var controller: WKUserContentController?
    @ObservationIgnored private let handler = Handler()
    /// The frame the proxy lives in. Stored from every inbound message rather
    /// than resolved once: a page may re-grant its camera from a different
    /// frame, and the last one to speak is the one holding the session.
    @ObservationIgnored private var frame: WKFrameInfo?

    @ObservationIgnored private var feed: (any RAVECameraFeed)?
    /// The one proxy allowed to hold the Persona. Weak: a closed tab must not
    /// keep the slot occupied.
    @ObservationIgnored private static weak var personaHolder: RAVECameraProxy?
    /// Whether the page still wants a feed — true from a genuine `nativeStart`
    /// until the page gives up on it (`nativeStop`, `stopped`) or the tab goes
    /// away. A scheduled retry checks this before acting: the delay between
    /// scheduling and firing is exactly the window in which the page can
    /// decide it no longer wants native capture, and a retry firing into that
    /// would restart a camera nobody asked for anymore.
    @ObservationIgnored private var feedWanted = false
    /// The page has handed its proxy stream over and is publishing from it.
    @ObservationIgnored private var pageArmed = false
    /// How many times the current Persona session has retried after a
    /// transient failure. Reset on every genuine `nativeStart` — see
    /// `isRetryablePersonaFailure` for what counts as worth retrying.
    @ObservationIgnored private var retryCount = 0
    private static let maxPersonaRetries = 2
    private static let personaRetryDelay: TimeInterval = 0.75
    /// Fail-closed modes only: the feed is gone (or never came) and the page
    /// has been told to paint its offline card. Set by the first failure of
    /// an outage and cleared by the next configuration, so an outage costs
    /// one log line going down and one coming back, however many attempts
    /// it took.
    @ObservationIgnored private var offline = false
    @ObservationIgnored private var attempts = 0
    /// Identifies the one scheduled re-subscribe that may act; anything that
    /// starts a subscription sooner invalidates the pending one.
    @ObservationIgnored private var retryGeneration = 0
    /// How often an absent shared feed is dialled again. Unbounded on purpose:
    /// the Persona's retry budget exists because it has a fallback to reach;
    /// a fail-closed source has none, so it waits for its publisher for as long
    /// as the page holds the camera. Refusal costs nothing.
    private static let sharedRetryDelay: TimeInterval = 2
    /// Relay flow control — see the header. Counts chunk calls in flight;
    /// past the high-water mark, frames are dropped until a keyframe (which
    /// the feed is asked for immediately) rather than queued into a backlog
    /// that becomes steady-state latency.
    @ObservationIgnored private var chunksInFlight = 0
    @ObservationIgnored private var droppingUntilKeyframe = false
    private static let inFlightHighWaterMark = 3
    /// Swift-side half of the latency report, over the window since the last
    /// page report. See `RelayStats`.
    @ObservationIgnored private var relayStats = RelayStats()
    /// What a running substitution does when the relay has to drop: move its
    /// playhead to its next keyframe.
    @ObservationIgnored private var advanceSubstitute: (@MainActor () -> Void)?
    /// Chunk timestamps must only ever increase across live → substitute →
    /// live. A substitute is stamped at the frame period; when live resumes,
    /// `timestampOffset` lifts the feed's real timestamps past it.
    @ObservationIgnored private var lastSentTimestamp: UInt64 = 0
    @ObservationIgnored private var timestampOffset: UInt64 = 0
    private static let frameStepMicroseconds: UInt64 = 33_333

    struct RelayStats {
        var encodeSumMs = 0.0, encodeMaxMs = 0.0
        var hopSumMs = 0.0, hopMaxMs = 0.0
        var timed = 0
        var relayed = 0
        var inFlightMax = 0
        var dropped = 0
        var dropEvents = 0
        var keyframesRelayed = 0
        var callFailures = 0

        mutating func recordTiming(encodeMs: Double, hopMs: Double) {
            guard encodeMs.isFinite, hopMs.isFinite else { return }
            timed += 1
            encodeSumMs += encodeMs; encodeMaxMs = max(encodeMaxMs, encodeMs)
            hopSumMs += hopMs; hopMaxMs = max(hopMaxMs, hopMs)
        }

        var summary: String {
            let n = max(timed, 1)
            return String(
                format: "encode %.0f/%.0fms hop %.0f/%.0fms inflight max %d relayed %d (%d key) dropped %d in %d events failures %d",
                encodeSumMs / Double(n), encodeMaxMs, hopSumMs / Double(n), hopMaxMs,
                inFlightMax, relayed, keyframesRelayed, dropped, dropEvents, callFailures
            )
        }
    }

    deinit { RAVELiveObjects.release("RAVECameraProxy") }

    /// - Parameters:
    ///   - mode: see `Mode`. Fixed for the tab's life, like the script it is
    ///     injected with — the two must agree, and the script cannot change
    ///     after document start.
    ///   - framingAspect: width ÷ height the page publishes at (3:4 matches
    ///     Meet's tiles; 16:9 fills a pinned one).
    ///   - offlineCard: what a fail-closed mode paints while its feed is away.
    ///   - makeFeed: a fresh feed per subscription. Nil uses the mode's own:
    ///     `RAVEPersonaCameraFeed` for the Persona, the loopback
    ///     `RAVEVirtualCameraFeed` otherwise. For an in-process camera pass
    ///     `{ camera.makeFeed() }`.
    public init(
        mode: Mode,
        framingAspect: Double = 16.0 / 9.0,
        offlineCard: OfflineCard = OfflineCard(),
        makeFeed: (@MainActor () -> any RAVECameraFeed)? = nil
    ) {
        RAVELiveObjects.retain("RAVECameraProxy")
        self.mode = mode
        self.framingAspect = framingAspect
        self.offlineCard = offlineCard
        if let makeFeed {
            self.makeFeed = makeFeed
        } else if case .persona = mode {
            self.makeFeed = { RAVEPersonaCameraFeed() }
        } else {
            self.makeFeed = { RAVEVirtualCameraFeed() }
        }
    }

    // MARK: - RAVEPageFeature

    public func install(on controller: WKUserContentController) {
        self.controller = controller
        controller.addUserScript(
            RAVECameraProxyScript.userScript(aspect: framingAspect, mode: mode, offlineCard: offlineCard))
        handler.onMessage = { [weak self] body, frame in
            MainActor.assumeIsolated { self?.handle(body, from: frame) }
        }
        controller.add(handler, name: RAVECameraProxyScript.messageHandler)
    }

    public func attach(to webView: WKWebView?) {
        self.webView = webView
    }

    /// The document that owns the proxy is going away, and its `pagehide` will
    /// tear the page side down. The camera is released here too rather than
    /// waiting for the page's `nativeStop`, which a dying document may never
    /// send.
    public func pageWillNavigate() {
        feedWanted = false
        pageArmed = false
        pageCameraEnabled = true
        stopFeed(reason: "page navigating")
        frame = nil
        liveChanged()
    }

    /// A tab whose page holds a live proxied camera is on a call.
    public var hibernationBlocker: String? { isLive ? "camera proxy" : nil }

    /// Explicit: the content controller retains the handler and would keep the
    /// chain alive past the tab.
    public func close() {
        feedWanted = false
        pageArmed = false
        pageCameraEnabled = true
        stopFeed(reason: "tab closed")
        controller?.removeScriptMessageHandler(forName: RAVECameraProxyScript.messageHandler)
        handler.onMessage = nil
        frame = nil
        liveChanged()
    }

    // MARK: - The extension point

    /// Asks the feed for a keyframe now.
    public func requestKeyframe() {
        feed?.requestKeyframe()
    }

    /// From now on the page receives what the app sends through
    /// `sendSubstitute` instead of the live units, which keep reaching the tap.
    /// The first substitute must be a keyframe in the page's configuration (or
    /// carry one), as whatever the relay was dropping toward becomes moot.
    ///
    /// - Parameter advanceToNextKeyframe: called when the relay has to drop:
    ///   move your playhead to your next keyframe. There is no encoder to ask.
    public func beginSubstitution(advanceToNextKeyframe: @escaping @MainActor () -> Void) {
        isSubstituting = true
        advanceSubstitute = advanceToNextKeyframe
        droppingUntilKeyframe = false
    }

    /// One substitute unit, at the app's pace (the frame period). Returns
    /// whether it reached the page: false while the relay drops to a keyframe
    /// or is over its in-flight window.
    ///
    /// - Parameter configuration: send this decoder configuration to the page
    ///   first — a substitute encoded by a different session. The unit after
    ///   it must be a keyframe.
    @discardableResult
    public func sendSubstitute(_ unit: AccessUnit,
                               configuration: RAVEH264Encoder.DecoderConfiguration? = nil) -> Bool {
        guard isSubstituting else { return false }
        if let configuration {
            send(RAVECameraProxyScript.command(
                "nativeConfig", arguments: [configuration.codecString, configuration.record.base64EncodedString()]))
        }
        if droppingUntilKeyframe {
            guard unit.isKeyframe else {
                relayStats.dropped += 1
                return false
            }
            droppingUntilKeyframe = false
        }
        if chunksInFlight >= Self.inFlightHighWaterMark, !unit.isKeyframe {
            beginDroppingUntilKeyframe()
            relayStats.dropped += 1
            return false
        }
        let sentAtMs = Date().timeIntervalSince1970 * 1000
        sendChunk(unit, timestamp: nextSyntheticTimestamp(), capturedAtMs: .nan, sentAtMs: sentAtMs)
        return true
    }

    /// Back to live. If the page was left on another configuration
    /// (`pageConfiguration`, the last one the substitute sent), the live one
    /// is restored first; either way live resumes on a keyframe the feed is
    /// asked for now.
    public func endSubstitution(pageConfiguration: RAVEH264Encoder.DecoderConfiguration?) {
        guard isSubstituting else { return }
        isSubstituting = false
        advanceSubstitute = nil
        if let live = decoderConfiguration, pageConfiguration != live {
            send(RAVECameraProxyScript.command(
                "nativeConfig", arguments: [live.codecString, live.record.base64EncodedString()]))
        }
        droppingUntilKeyframe = true
        feed?.requestKeyframe()
    }

    // MARK: - Messages from the page

    private func handle(_ body: [String: Any], from frame: WKFrameInfo?) {
        if let frame { self.frame = frame }
        guard let kind = body["kind"] as? String else { return }
        switch kind {
        case "armed":
            pageArmed = true
            liveChanged()
            RAVEBrowserLog.cameraProxy.info("""
            armed \(body["width"] as? Int ?? 0, privacy: .public)×\
            \(body["height"] as? Int ?? 0, privacy: .public) \
            via=\(RAVELogToken.vet(body["via"]), privacy: .public) \
            live=\(self.isLive ? "yes" : "no", privacy: .public)
            """)

        // What the crop actually resolved to. Worth a line of its own because
        // every number in it is one the code guessed at until a device said
        // otherwise: what the source gave, which rectangle was lifted out of
        // it, and what is on the wire. `via` says which source painted:
        // `native` is the app's own feed; `element` is WebKit's reframed
        // track, by setting or after a fallback; `avatar`/`virtual` the
        // fail-closed sources.
        case "geometry":
            let aspect = body["aspect"] as? Double ?? 0
            RAVEBrowserLog.cameraProxy.info("""
            framing via=\(RAVELogToken.vet(body["via"]), privacy: .public) \
            source=\(RAVELogToken.vet(body["source"]), privacy: .public) \
            crop=\(RAVELogToken.vet(body["crop"]), privacy: .public) \
            published=\(body["width"] as? Int ?? 0, privacy: .public)×\
            \(body["height"] as? Int ?? 0, privacy: .public) \
            target=\(String(format: "%.3f", aspect), privacy: .public)
            """)

        // The page's camera-off switch. On, the feed is asked for a keyframe
        // so anything recording it refills on the next frame rather than at
        // the next natural GOP; the tap hears either way.
        case "enabled":
            let enabled = body["value"] as? Bool ?? true
            guard enabled != pageCameraEnabled else { break }
            pageCameraEnabled = enabled
            if enabled { feed?.requestKeyframe() }
            tap?.cameraProxy(self, pageCameraEnabledDidChange: enabled)
            liveChanged()
            RAVEBrowserLog.cameraProxy.info("camera \(enabled ? "enabled" : "disabled", privacy: .public) by the page")

        case "stopped":
            feedWanted = false
            pageArmed = false
            pageCameraEnabled = true
            stopFeed(reason: "the page stopped its track")
            liveChanged()

        case "nativeStart":
            feedWanted = true
            retryCount = 0
            offline = false
            attempts = 0
            startFeed()

        // Fail-closed modes only: the page could not paint what it was sent —
        // its decoder faulted, or the first frame never came — and, failing
        // closed, is painting its offline card rather than falling back. A
        // fresh subscription brings a fresh configuration and opens on a
        // keyframe, which is the whole cure. Ignored while already
        // reconnecting: that attempt is coming anyway.
        case "avatarFault":
            guard mode.failsClosed, feedWanted, decoderConfiguration != nil else { break }
            sharedFeedWentOffline(
                "the page could not paint it (\(body["reason"] as? String ?? "?"))", tellPage: false)

        case "nativeStop":
            feedWanted = false
            stopFeed(reason: "the page released the native source")
            liveChanged()

        // The page composes these messages from its own state and error
        // names; still page-world text, so the message is private.
        case "error":
            let scope = RAVELogToken.vet(body["scope"])
            let message = body["message"] as? String ?? "?"
            RAVEBrowserLog.cameraProxy.error("""
            \(scope, privacy: .public): \(message, privacy: .private)
            """)
            if scope == "setup" {
                pageArmed = false
                liveChanged()
            }
            // `native` is a fallback in progress — the page keeps its proxy and
            // paints from WebKit's camera; its `nativeStop` follows and takes
            // the proxy down. The line above is the whole record.

        // The page's decoder fell behind and has stopped accepting deltas
        // until a keyframe. Stop relaying what it will only drop, and get it
        // a keyframe now — the natural one is up to a whole GOP away, and the
        // point of this path is that a backlog must not become permanent.
        case "decoderBehind":
            RAVEBrowserLog.cameraProxy.error("""
            page decoder fell behind (queue \(body["queue"] as? Int ?? 0, privacy: .public)) \
            — dropping to the next keyframe
            """)
            beginDroppingUntilKeyframe()

        case "unavailable":
            RAVEBrowserLog.cameraProxy.error("""
            camera proxy not installed: \(body["reason"] as? String ?? "?", privacy: .private)
            """)

        // The page's half of the latency picture, once every few seconds while
        // native frames are painting. Each stage is "mean/max ms" over the
        // window; `total` is sensor to painted canvas, which is the A/V offset
        // the far end will hear, less the canvas-capture tick nobody can
        // observe from either side. Logged together with this side's numbers
        // so one line places the time.
        case "nativeLatency":
            func stage(_ key: String) -> String {
                guard let pair = body[key] as? [Double], pair.count == 2 else { return "?" }
                return String(format: "%.0f/%.0f", pair[0], pair[1])
            }
            RAVEBrowserLog.cameraProxy.info("""
            native latency [\(self.modeLabel, privacy: .public)] \
            (mean/max ms, \(body["frames"] as? Int ?? 0, privacy: .public) frames): \
            total \(stage("total"), privacy: .public) = \
            upstream \(stage("upstream"), privacy: .public) + \
            bridge \(stage("bridge"), privacy: .public) + \
            decode \(stage("decode"), privacy: .public) + \
            paint \(stage("paint"), privacy: .public); \
            decode queue max \(body["queueMax"] as? Int ?? 0, privacy: .public); \
            swift: \(self.relayStats.summary, privacy: .public)
            """)
            relayStats = RelayStats()

        default:
            break
        }
    }

    /// Live follows two facts: the page is publishing the proxy, and this
    /// side's feed is wanted. Either alone is not live — the page on WebKit's
    /// camera is painting nothing this side sends.
    private func liveChanged() {
        let live = pageArmed && feedWanted
        if live != isLive { isLive = live }
        tap?.cameraProxyLiveDidChange(self)
    }

    // MARK: - The feed

    private var modeLabel: String {
        switch mode {
        case .persona: "persona"
        case .avatar: "avatar"
        case .virtualDevice: "virtual"
        }
    }

    private var feedLabel: String {
        switch mode {
        case .persona: "native camera"
        case .avatar: "avatar camera"
        case .virtualDevice: "virtual camera"
        }
    }

    private func startFeed() {
        if case .persona = mode { startPersonaFeed() } else { startSharedFeed() }
    }

    private func startPersonaFeed() {
        // Device-wide resource, process-wide exclusivity. The page falls back
        // to WebKit's camera on `nativeEnd`, which is the right answer for a
        // second call tab: it gets a picture, just not this one.
        if let holder = Self.personaHolder, holder !== self, holder.feed != nil {
            RAVEBrowserLog.cameraProxy.info("native camera: declined, another tab holds it")
            send(RAVECameraProxyScript.command("nativeEnd", arguments: ["the camera is in use by another tab"]))
            return
        }
        stopFeed(reason: "restarting")

        let feed = makeFeed()
        wire(feed)
        self.feed = feed
        Self.personaHolder = self
        tap?.cameraProxyFeedDidStart(self)
        RAVEBrowserLog.cameraProxy.info("native camera: starting")
        feed.start()
    }

    /// No exclusivity: a shared source serves several subscribers, and a
    /// second call tab showing the same avatar is exactly right.
    private func startSharedFeed() {
        retryGeneration += 1
        stopFeed(reason: "restarting")
        let feed = makeFeed()
        wire(feed)
        self.feed = feed
        attempts += 1
        if !offline {
            RAVEBrowserLog.cameraProxy.info("\(self.feedLabel, privacy: .public): subscribing")
        }
        tap?.cameraProxyFeedDidStart(self)
        feed.start()
    }

    /// The callbacks every feed shares: configuration, units and the ending,
    /// each hopped onto the main actor in order.
    private func wire(_ feed: any RAVECameraFeed) {
        // Every feed callback hops to the main actor via DispatchQueue.main,
        // not Task { @MainActor }, and the distinction is load-bearing: the
        // frames form a delta chain, so the relay must preserve arrival
        // order, and unstructured-Task submission order is not contractual
        // where a serial queue's is. Same reasoning pins config before the
        // chunks that depend on it. Identity checks against `feed` keep a
        // stopped feed's stragglers from reaching a fresh one.
        //
        // `feed` is captured weak in every one of these. They are stored *on*
        // the feed, so a strong capture is a cycle, and Raven's first version
        // had exactly that: every feed ever started — the join page's preview,
        // the call's, each camera toggle and each tracking-loss retry — stayed
        // alive with its stopped AVCaptureSession, its input, output and
        // queues, for the life of the process. `RAVELiveObjects` counts them.
        feed.onDecoderConfiguration = { [weak self, weak feed] config, width, height in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let feed, self.feed === feed else { return }
                    self.configured(config, width: width, height: height)
                }
            }
        }
        feed.onAccessUnit = { [weak self, weak feed] data, pts, keyframe, capturedAtMs, encodedAtMs in
            // Encoded here, off the main thread — base64 of a 1080p keyframe is
            // real work that has no business there — and kept with the unit, so
            // a replay never re-encodes it.
            let unit = AccessUnit(data: data, isKeyframe: keyframe)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let feed, self.feed === feed else { return }
                    self.receive(unit, pts: pts, capturedAtMs: capturedAtMs, encodedAtMs: encodedAtMs)
                }
            }
        }
        feed.onEnded = { [weak self, weak feed] reason in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let feed, self.feed === feed else { return }
                    self.feedEnded(reason)
                }
            }
        }
    }

    private func configured(_ config: RAVEH264Encoder.DecoderConfiguration, width: Int, height: Int) {
        let previous = decoderConfiguration
        if mode.failsClosed, previous == nil { sharedFeedConnected() }
        // A new decoder joins at its first keyframe, so whatever the relay was
        // in the middle of dropping no longer matters.
        droppingUntilKeyframe = false
        // Config reaching the page is proof this feed is genuinely alive, not
        // just started — reset the retry budget so a second, unrelated
        // tracking-loss bout later in the same call gets its own full budget
        // rather than inheriting whatever the first bout spent.
        retryCount = 0
        tap?.cameraProxy(self, didConfigure: config, width: width, height: height, previous: previous)
        decoderConfiguration = config
        frameSize = (width, height)
        RAVEBrowserLog.cameraProxy.info("""
        \(self.feedLabel, privacy: .public): \(RAVELogToken.vet(config.codecString), privacy: .public) \
        \(width, privacy: .public)×\(height, privacy: .public)
        """)
        send(RAVECameraProxyScript.command(
            "nativeConfig", arguments: [config.codecString, config.record.base64EncodedString()]))
    }

    // MARK: - Fail-closed outages

    /// The first configuration of a subscription: the source is live. Ends an
    /// outage if there was one.
    private func sharedFeedConnected() {
        if offline {
            RAVEBrowserLog.cameraProxy.info("""
            \(self.feedLabel, privacy: .public): back after \(self.attempts, privacy: .public) attempts
            """)
        } else {
            RAVEBrowserLog.cameraProxy.info("\(self.feedLabel, privacy: .public): connected")
        }
        offline = false
        attempts = 0
    }

    /// Every ending of a fail-closed source, and there is no fallback among
    /// them: on the page a fallback is WebKit's camera, which is the face the
    /// wearer chose not to send. The page keeps its proxy track and paints its
    /// offline card (`nativeOffline`, unless it reported the fault itself);
    /// this side subscribes again after `sharedRetryDelay`, indefinitely,
    /// while the page still wants the camera.
    private func sharedFeedWentOffline(_ reason: String, tellPage: Bool) {
        stopFeed(reason: "feed ended", quiet: decoderConfiguration == nil)
        liveChanged()
        guard feedWanted else { return }
        if !offline {
            offline = true
            RAVEBrowserLog.cameraProxy.error("""
            \(self.feedLabel, privacy: .public) offline: \(reason, privacy: .private) — the page shows \
            its offline card; retrying every \(Int(Self.sharedRetryDelay), privacy: .public) s
            """)
            if tellPage { send(RAVECameraProxyScript.command("nativeOffline")) }
        }
        retryGeneration += 1
        let generation = retryGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sharedRetryDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.retryGeneration == generation,
                      self.feedWanted, self.feed == nil else { return }
                self.startFeed()
            }
        }
    }

    /// The feed died or never started. A transient Persona failure gets a
    /// bounded, silent retry before the page ever hears about it —
    /// `fallBackToElement` on the page side is one-shot for the rest of that
    /// `getUserMedia` grant, so once `nativeEnd` is sent, native capture is off
    /// for the rest of the call even if the camera would have recovered a
    /// second later. Measured case this exists for: a
    /// `VTCompressionSessionEncodeFrame` failure landing right around a
    /// visionOS tracking-loss event, which flips `scenePhase` briefly — the
    /// encoder does not resubscribe to that on its own, so without a retry here
    /// the call is stuck on WebKit's narrower crop (1080×1080 vs. the sensor's
    /// 1920×1080) for every subsequent tracking loss too, which reads as the
    /// picture "zooming in" and staying that way.
    ///
    /// Retrying is silent — the page's proxy track and canvas are untouched
    /// throughout, exactly like an ordinary interruption; only whether frames
    /// are currently arriving changes. Permission and hardware-absence
    /// reasons skip the retry: nothing about a second attempt half a second
    /// later can fix "denied" or "no camera available", so retrying would
    /// only delay the fallback the page needs.
    ///
    /// A feed's reason is code-defined in RAVECamera but may carry a system
    /// error's description, so it is logged private.
    private func feedEnded(_ reason: String) {
        // Fail closed: these never reach the `nativeEnd` below.
        if mode.failsClosed {
            sharedFeedWentOffline(reason, tellPage: true)
            return
        }
        stopFeed(reason: "feed ended")
        if feedWanted, Self.isRetryablePersonaFailure(reason), retryCount < Self.maxPersonaRetries {
            retryCount += 1
            RAVEBrowserLog.cameraProxy.error("""
            native camera ended: \(reason, privacy: .private) — retrying \
            (\(self.retryCount, privacy: .public)/\(Self.maxPersonaRetries, privacy: .public))
            """)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.personaRetryDelay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.feedWanted, self.feed == nil else { return }
                    self.startFeed()
                }
            }
            return
        }
        RAVEBrowserLog.cameraProxy.error("native camera ended: \(reason, privacy: .private)")
        send(RAVECameraProxyScript.command("nativeEnd", arguments: [reason]))
    }

    /// "Denied" (permission) and "no camera available" (hardware) are the two
    /// reasons `RAVEPersonaCameraFeed` reports that a retry cannot possibly
    /// fix; everything else — an encoder or capture-session failure — is the
    /// transient shape a tracking-loss-adjacent glitch takes.
    private static func isRetryablePersonaFailure(_ reason: String) -> Bool {
        !reason.contains("denied") && reason != "no camera available"
    }

    /// Idempotent. Safe to call from every path that ends the proxy — the
    /// page's own `nativeStop`, `stopped`, navigation, tab close. The tap hears
    /// first, while the configuration is still set, so a substitution can end
    /// against it. Logged when there was a feed to stop, with the reason: "is
    /// the camera still running after the call" was unanswerable from the log
    /// before this line existed.
    ///
    /// `quiet` is for a shared subscription that never connected — one per
    /// retry through an outage, which the outage's own line already covers.
    private func stopFeed(reason: String, quiet: Bool = false) {
        tap?.cameraProxyFeedWillStop(self)
        if isSubstituting { endSubstitution(pageConfiguration: decoderConfiguration) }
        if feed != nil, !quiet {
            RAVEBrowserLog.cameraProxy.info("""
            \(self.feedLabel, privacy: .public): stopped (\(reason, privacy: .public)); \
            \(self.relayStats.relayed, privacy: .public) relayed since the last report
            """)
        }
        feed?.stop()
        feed = nil
        decoderConfiguration = nil
        frameSize = nil
        chunksInFlight = 0
        droppingUntilKeyframe = false
        relayStats = RelayStats()
        if Self.personaHolder === self { Self.personaHolder = nil }
    }

    // MARK: - Live units

    /// One access unit from the feed, in order. The tap hears it first — a
    /// recording is the camera's truth, not the page's, so a unit the relay
    /// goes on to drop is still in it — then it is relayed, unless a
    /// substitute currently owns the page.
    private func receive(_ unit: AccessUnit, pts: UInt64, capturedAtMs: Double, encodedAtMs: Double) {
        tap?.cameraProxy(self, didReceive: unit, ptsMicroseconds: pts)
        if isSubstituting { return }

        if droppingUntilKeyframe {
            guard unit.isKeyframe else { relayStats.dropped += 1; return }
            droppingUntilKeyframe = false
        }
        if chunksInFlight >= Self.inFlightHighWaterMark {
            // Overloaded. Never drop a lone delta — that poisons the chain —
            // drop everything up to the next keyframe and resume whole. A
            // keyframe arriving into an overloaded relay is still sent: it is
            // the one frame that lets the page catch up, and holding it back
            // would only mean asking for another.
            if !unit.isKeyframe {
                beginDroppingUntilKeyframe()
                relayStats.dropped += 1
                return
            }
        }

        let sentAtMs = Date().timeIntervalSince1970 * 1000
        relayStats.recordTiming(encodeMs: encodedAtMs - capturedAtMs, hopMs: sentAtMs - encodedAtMs)
        sendChunk(unit, timestamp: monotonic(pts), capturedAtMs: capturedAtMs, sentAtMs: sentAtMs)
    }

    /// Enter drop mode: nothing more reaches the page until a keyframe. Live,
    /// the feed is asked to produce one on its next frame so that wait is one
    /// frame period, not the rest of the GOP; while substituting there is no
    /// encoder, so the substitute jumps to its own next keyframe instead.
    private func beginDroppingUntilKeyframe() {
        guard !droppingUntilKeyframe else { return }
        droppingUntilKeyframe = true
        relayStats.dropEvents += 1
        if isSubstituting {
            advanceSubstitute?()
        } else {
            feed?.requestKeyframe()
        }
    }

    /// The feed's timestamp lifted past whatever was last sent, so the page's
    /// decoder never sees time go backwards after a substitution — or a
    /// shared publisher restarting its clock.
    private func monotonic(_ pts: UInt64) -> UInt64 {
        var stamped = pts &+ timestampOffset
        if stamped <= lastSentTimestamp {
            let floor = lastSentTimestamp &+ Self.frameStepMicroseconds
            timestampOffset &+= floor &- stamped
            stamped = floor
        }
        lastSentTimestamp = stamped
        return stamped
    }

    private func nextSyntheticTimestamp() -> UInt64 {
        lastSentTimestamp &+= Self.frameStepMicroseconds
        return lastSentTimestamp
    }

    private func sendChunk(_ unit: AccessUnit, timestamp: UInt64, capturedAtMs: Double, sentAtMs: Double) {
        relayStats.relayed += 1
        if unit.isKeyframe { relayStats.keyframesRelayed += 1 }
        chunksInFlight += 1
        relayStats.inFlightMax = max(relayStats.inFlightMax, chunksInFlight)

        // The payload travels as an argument value, not as source text — the
        // page must not parse a few hundred kilobytes of base64 as JavaScript
        // on every frame (see the header). `capturedAt` is the wall-clock
        // capture instant the page measures its own stages against; `-1`
        // means there is none — the feed could not place it, or the frame is
        // a substitute — and the page skips those stages.
        webView?.callAsyncJavaScript(
            RAVECameraProxyScript.nativeChunkCall,
            arguments: [
                "b64": unit.base64, "ts": Int(clamping: timestamp), "key": unit.isKeyframe,
                "capturedAt": capturedAtMs.isFinite ? capturedAtMs : -1,
                "sentAt": sentAtMs,
            ],
            in: frame, in: .page
        ) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.chunksInFlight > 0 { self.chunksInFlight -= 1 }
                if case .failure = result, self.feed != nil {
                    // The page never saw this chunk. If it was a delta the
                    // decoder is now poisoned until a keyframe, so treat it as
                    // a drop and recover the same way.
                    self.relayStats.callFailures += 1
                    self.beginDroppingUntilKeyframe()
                }
            }
        }
    }

    private func send(_ javaScript: String) {
        webView?.evaluateJavaScript(javaScript, in: frame, in: .page) { result in
            if case .failure(let error) = result {
                RAVEBrowserLog.cameraProxy.error("""
                command failed: \(error.raveLogCode, privacy: .public) \
                \(error.localizedDescription, privacy: .private)
                """)
            }
        }
    }

    // MARK: - Handler

    final class Handler: NSObject, WKScriptMessageHandler {
        var onMessage: (([String: Any], WKFrameInfo?) -> Void)?

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any] else { return }
            onMessage?(body, message.frameInfo)
        }
    }
}
#endif
