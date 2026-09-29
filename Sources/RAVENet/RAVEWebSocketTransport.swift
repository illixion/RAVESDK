/*
 RAVENet - WebSocket transport

 The connection-management core extracted from two independently-hardened
 clients: Spatial Stash's `RemoteWebSocketClient` and Spatial Home's
 `HAConnection`. Both had converged on the same ~20 concerns (several
 byte-identical) while drifting apart on the details; this merges them, taking
 each side's stronger half:

   from Spatial Stash — stale-completion guards on BOTH the success and error
     paths after `await receive()`, deliberate socket suspend/revive, deep
     `URLError`/peer-trust/close-reason diagnostics
   from Spatial Home  — an explicit state enum with a distinct handshake step

 The seam that made a shared implementation possible: **the transport never
 decides it is ready.** Stash promotes on the first inbound frame; Home
 promotes on an `auth_ok` frame it has to parse. Neither rule generalises, so
 readiness is declared by the app via `markReady()`, and fatal-vs-retryable is
 decided by the app's `failurePolicy`.

 Protocol framing lives entirely above this type. It moves `String` frames and
 nothing else — even the keepalive ping is app-supplied, because Stash pings
 with `{"action":"ping"}` and Home with `{"id":N,"type":"ping"}`.
 */

import Foundation
import Network

/// Events emitted to the app. Consume via `for await event in transport.events`.
public enum RAVENetEvent: Sendable {
    /// Lifecycle transition. Also delivered for `.failed`.
    case stateChanged(RAVEConnectionState)
    /// An inbound text frame (binary frames are UTF-8 decoded into this case).
    case frame(String)
    /// A receive failure, delivered after the failure policy has been consulted
    /// and the resulting action taken. Informational — do not reconnect from here.
    case failure(RAVETransportFailure)
}

/// Drives one `URLSessionWebSocketTask` with reconnect, keepalive, network-path
/// gating and wake probing.
///
/// Isolation: an `actor`, so it serves consumers in either of the codebase's
/// two concurrency conventions — `@MainActor @Observable` models await it, and
/// non-main-actor callers use it without hopping through the main thread.
public actor RAVEWebSocketTransport {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// Endpoint to connect to.
        public var url: URL
        /// Reconnect backoff. See `RAVEBackoffPolicy` for why both floors exist.
        public var backoff: RAVEBackoffPolicy
        /// Gap between keepalive pings. Started only once the app calls
        /// `markReady()` — pinging a socket that has not finished its handshake
        /// is at best wasted and at worst confuses a strict server.
        public var pingInterval: TimeInterval
        /// How long to wait for *any* inbound traffic after a ping before
        /// declaring the socket dead. Individual pings are not matched to
        /// pongs — any frame counts as liveness.
        public var pongTimeout: TimeInterval
        public var requestTimeout: TimeInterval
        public var resourceTimeout: TimeInterval

        public init(
            url: URL,
            backoff: RAVEBackoffPolicy = RAVEBackoffPolicy(),
            pingInterval: TimeInterval = 25,
            pongTimeout: TimeInterval = 10,
            requestTimeout: TimeInterval = 15,
            resourceTimeout: TimeInterval = 30
        ) {
            self.url = url
            self.backoff = backoff
            self.pingInterval = pingInterval
            self.pongTimeout = pongTimeout
            self.requestTimeout = requestTimeout
            self.resourceTimeout = resourceTimeout
        }
    }

    // MARK: - Stored state

    private let configuration: Configuration
    private let logger: any RAVENetLogger
    /// Builds the next keepalive/probe frame. Async because Home Assistant's
    /// ping consumes a command id owned by a `@MainActor` model.
    private let pingFrameProvider: @Sendable () async -> String?
    /// Consulted on every receive failure to choose reconnect vs. permanent halt.
    private let failurePolicy: @Sendable (RAVETransportFailure) -> RAVEFailureDecision

    private var session: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var state: RAVEConnectionState = .idle
    private var retryCount: Int = 0
    /// Start time of the most recent connect attempt, used to floor the
    /// reconnect interval when a socket fails inside a millisecond.
    private var lastConnectAttemptAt: Date = .distantPast
    /// Timestamp of the last inbound frame — the liveness signal the keepalive
    /// and probe paths both test against.
    private var lastReceiveAt: Date = .distantPast
    /// Set by a `.halt` failure decision or by `halt(reason:)`. Suppresses every
    /// reconnect path until the next explicit `start()`.
    private var halted: Bool = false

    private var pathMonitor: NWPathMonitor?
    private var lastPathSatisfied: Bool = true

    private let eventContinuation: AsyncStream<RAVENetEvent>.Continuation
    /// Ordered stream of transport events. Single-consumer.
    public nonisolated let events: AsyncStream<RAVENetEvent>

    // MARK: - Init

    /// - Parameters:
    ///   - pingFrameProvider: Returns the next keepalive frame, or `nil` to skip
    ///     this round (e.g. the app is not in a state where a ping is meaningful).
    ///   - failurePolicy: Decides reconnect vs. halt for each receive failure.
    ///     Defaults to always reconnecting.
    public init(
        configuration: Configuration,
        logger: any RAVENetLogger = RAVENetOSLogger(),
        pingFrameProvider: @escaping @Sendable () async -> String?,
        failurePolicy: @escaping @Sendable (RAVETransportFailure) -> RAVEFailureDecision = { _ in .reconnect }
    ) {
        self.configuration = configuration
        self.logger = logger
        self.pingFrameProvider = pingFrameProvider
        self.failurePolicy = failurePolicy
        let (stream, continuation) = AsyncStream<RAVENetEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.eventContinuation = continuation
    }

    deinit {
        eventContinuation.finish()
    }

    // MARK: - Public API

    public var currentState: RAVEConnectionState { state }
    public var isReady: Bool { state.isReady }

    /// Begin connecting, clearing any previous halt. Idempotent enough to call
    /// on config change — tears down first.
    public func start() {
        teardownSocket()
        halted = false
        retryCount = 0
        startPathMonitor()
        doConnect()
    }

    /// Full teardown: socket, tasks, URLSession and path monitor. The transport
    /// is reusable afterwards via `start()`.
    public func stop() {
        teardownSocket()
        stopPathMonitor()
        session?.invalidateAndCancel()
        session = nil
        retryCount = 0
        transition(to: .idle)
    }

    /// Fire-and-forget send. Failures are logged, not thrown — every caller in
    /// both source implementations ignored the result, and a send error is
    /// always followed by a receive error that drives the real recovery.
    public func send(_ text: String) {
        guard let task = webSocketTask else { return }
        task.send(.string(text)) { [logger] error in
            if let error {
                logger.log(.warning, "send error: \(error)")
            }
        }
    }

    /// Declare that a protocol-level handshake is underway (Home Assistant's
    /// `auth_required`). Optional — apps without a handshake never call it.
    public func markHandshaking() {
        guard state == .connecting else { return }
        transition(to: .handshaking)
    }

    /// Declare the connection usable. Resets backoff (this is the *only* place
    /// that does — a wake or path-up edge does not prove a connection works)
    /// and starts the keepalive loop.
    public func markReady() {
        guard state == .connecting || state == .handshaking else { return }
        retryCount = 0
        transition(to: .ready)
        startKeepalive()
    }

    /// Stop permanently with a reason. Used for protocol-level fatalities the
    /// transport cannot see — Home Assistant's `auth_invalid` arrives as an
    /// ordinary frame, not a socket error.
    public func halt(reason: String) {
        halted = true
        teardownSocket()
        logger.log(.error, "halted: \(reason)")
        transition(to: .failed(reason))
    }

    /// Probe with a ping and reconnect only if nothing arrives within `timeout`.
    ///
    /// This is the correct thing to call on a scene-phase wake. visionOS
    /// flutters `scenePhase` on gaze shifts, and unconditionally reconnecting
    /// there churns the server; a healthy socket answers the ping and is left
    /// alone.
    public func probeOrReconnect(timeout: TimeInterval = 3) async {
        if halted { return }
        guard state.isReady, webSocketTask != nil else {
            forceReconnectNow()
            return
        }
        let sentAt = Date()
        logger.log(.info, "probe ping (timeout=\(timeout)s)")
        if let frame = await pingFrameProvider() { send(frame) }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self else { return }
            await self.failProbeIfSilent(since: sentAt)
        }
    }

    /// Tear down and reconnect immediately, cancelling any sleeping backoff.
    ///
    /// Always tears down rather than testing liveness first: `isReady` and a
    /// non-nil task can both look healthy while the TCP path is dead — the
    /// classic sleep/wake zombie socket, where `receive()` does not error until
    /// the OS finally tries to deliver a frame, which can take minutes.
    public func forceReconnectNow() {
        if halted { return }
        guard session != nil else { return }
        teardownSocket()
        // Deliberately NOT resetting retryCount. This fires on path-up and wake
        // edges, neither of which proves the next attempt succeeds. Resetting
        // here produced a reconnect storm: instant ENOTCONN → scheduleReconnect,
        // some other caller forces a reconnect, retryCount returns to 0, repeat.
        logger.log(.info, "force reconnect requested")
        doConnect()
    }

    /// Flush anything queued behind a trailing frame, then release the socket if
    /// the app still wants it released.
    ///
    /// Two problems this solves when backgrounding. `send` is fire-and-forget and
    /// the app can suspend before a final frame reaches the transport; WebSocket
    /// sends complete in order, so awaiting a trailing frame proves the ones
    /// ahead of it went out. And a suspended client leaves the socket half-open,
    /// so the peer only notices when its own liveness timer reaps us — closing
    /// explicitly is immediate.
    ///
    /// Must be awaited under a background-task assertion, or the app suspends
    /// mid-flush and nothing was gained.
    ///
    /// - Parameter shouldSuspend: Re-checked *after* the flush completes, so a
    ///   window that came back during the flush keeps its socket.
    public func flushAndSuspend(shouldSuspend: @Sendable () async -> Bool) async {
        guard let task = webSocketTask else { return }
        if let frame = await pingFrameProvider() {
            await withCheckedContinuation { continuation in
                task.send(.string(frame)) { _ in continuation.resume() }
            }
        }
        guard await shouldSuspend(), task === webSocketTask else { return }
        logger.log(.info, "suspending — releasing socket for background")
        teardownSocket()
        // This close is ours by choice, not a failure, so the return path must
        // not inherit somebody else's backoff.
        retryCount = 0
        transition(to: .suspended)
    }

    /// Bring a suspended/idle connection back up.
    ///
    /// Deliberately does nothing when an upgrade or a backoff retry is already
    /// in flight — tearing those down is `forceReconnectNow()`'s job, and doing
    /// it here would turn several windows attaching at once into a stampede.
    public func reviveIfIdle() {
        guard !halted, session != nil else { return }
        guard webSocketTask == nil, reconnectTask == nil else { return }
        logger.log(.info, "revive — reconnecting a released socket")
        doConnect()
    }

    // MARK: - Connect

    /// Fresh `URLSession` only when we have none. An earlier version of the
    /// Stash client rebuilt it on every connect to clear stale HTTP/2 multiplex
    /// state; that produced a worse failure — invalidating the old session while
    /// immediately resuming a task on a new one races kernel socket teardown and
    /// the new task throws `ENOTCONN` inside a millisecond. WebSocket tasks are
    /// HTTP/1.1, so there is no multiplex state to clear in the first place.
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = self.configuration.requestTimeout
        configuration.timeoutIntervalForResource = self.configuration.resourceTimeout
        return URLSession(configuration: configuration)
    }

    private func doConnect() {
        if session == nil { session = makeSession() }
        guard let session else { return }

        let task = session.webSocketTask(with: configuration.url)
        webSocketTask = task
        task.resume()
        lastConnectAttemptAt = Date()
        lastReceiveAt = Date()
        transition(to: .connecting)

        logger.log(.info, "connecting to \(configuration.url.scheme ?? "?", privacy: .public)://\(Self.loggableEndpoint(configuration.url), privacy: .private(mask: .hash))")

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task: task)
        }
    }

    private func receiveLoop(task: URLSessionWebSocketTask) async {
        logger.log(.info, "receive loop entered")
        defer { logger.log(.info, "receive loop exited") }

        while !Task.isCancelled {
            guard task === webSocketTask else {
                logger.log(.info, "receive loop: task no longer current, exiting")
                return
            }

            do {
                let message = try await task.receive()
                // Cancellation does not guarantee URLSession's pending receive
                // stops before returning. A suspend or force-reconnect may have
                // replaced the task while this await was in flight; accepting
                // that stale completion resurrects a connection with no
                // transport behind it.
                guard !Task.isCancelled, task === webSocketTask else {
                    logger.log(.info, "stale receive completion discarded")
                    return
                }
                lastReceiveAt = Date()
                switch message {
                case .string(let text):
                    eventContinuation.yield(.frame(text))
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        eventContinuation.yield(.frame(text))
                    }
                @unknown default:
                    break
                }
            } catch {
                // Same guard on the error path. Without it both loops race
                // scheduleReconnect, the second cancels the first's backoff
                // timer, and retryCount effectively never climbs.
                guard !Task.isCancelled, task === webSocketTask else {
                    logger.log(.info, "stale receive loop exiting (task swapped)")
                    return
                }
                handleReceiveFailure(error, task: task)
                return
            }
        }
    }

    private func handleReceiveFailure(_ error: any Error, task: URLSessionWebSocketTask) {
        let failure = Self.describeFailure(error, task: task)
        logger.log(.warning, "receive error: \(failure.errorDomain, privacy: .public) \(failure.errorCode) closeCode=\(failure.closeCode.rawValue) — \(failure.diagnostic)")

        keepaliveTask?.cancel()
        keepaliveTask = nil
        webSocketTask = nil

        switch failurePolicy(failure) {
        case .halt(let reason):
            halted = true
            logger.log(.error, "halted: \(reason)")
            transition(to: .failed(reason))
        case .reconnect:
            transition(to: .connecting)
            scheduleReconnect()
        }
        eventContinuation.yield(.failure(failure))
    }

    /// Dump enough detail that a failed receive can be told apart: a proxy
    /// returning 4xx/5xx, a non-Upgrade response, or an unhappy TLS layer.
    private static func describeFailure(_ error: any Error, task: URLSessionWebSocketTask) -> RAVETransportFailure {
        let nsError = error as NSError
        var detail = "domain=\(nsError.domain) code=\(nsError.code) desc=\(error.localizedDescription)"
        if let urlError = error as? URLError {
            detail += " urlErrorCode=\(urlError.code.rawValue)"
            if let peerTrust = urlError.userInfo[NSURLErrorFailingURLPeerTrustErrorKey] {
                detail += " peerTrust=\(peerTrust)"
            }
            // Endpoint only: the query can hold a token, and this string
            // ends up in logs and in the connection state.
            if let failing = urlError.failingURL {
                detail += " url=\(loggableEndpoint(failing))"
            }
        }
        if task.closeCode != .invalid {
            detail += " closeCode=\(task.closeCode.rawValue)"
        }
        var reasonText: String?
        if let reason = task.closeReason,
           let decoded = String(data: reason, encoding: .utf8), !decoded.isEmpty {
            reasonText = decoded
            detail += " closeReason=\(decoded)"
        }
        return RAVETransportFailure(
            errorDomain: nsError.domain,
            errorCode: nsError.code,
            errorDescription: error.localizedDescription,
            closeCode: task.closeCode,
            closeReason: reasonText,
            diagnostic: detail
        )
    }

    /// Host, port and path only. The query and any credentials are dropped
    /// before the URL reaches a log at all, so a token in the query can't
    /// show up even on the device's own console.
    static func loggableEndpoint(_ url: URL) -> String {
        var endpoint = url.host ?? "?"
        if let port = url.port { endpoint += ":\(port)" }
        return endpoint + url.path
    }

    // MARK: - Keepalive

    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            await self?.keepaliveLoop()
        }
    }

    /// Periodic ping. Pings are not matched to pongs — any inbound frame counts
    /// as liveness, so the test is "did *anything* arrive within `pongTimeout`
    /// of the last ping?". This is the primary detector for half-open sockets
    /// after sleep/wake.
    private func keepaliveLoop() async {
        logger.log(.info, "keepalive loop entered")
        defer { logger.log(.info, "keepalive loop exited") }

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(configuration.pingInterval))
            if Task.isCancelled { return }
            guard webSocketTask != nil, state.isReady else { return }

            let sentAt = Date()
            if let frame = await pingFrameProvider() { send(frame) }

            try? await Task.sleep(for: .seconds(configuration.pongTimeout))
            if Task.isCancelled { return }
            if lastReceiveAt < sentAt {
                logger.log(.warning, "pong timeout (last rx \(-lastReceiveAt.timeIntervalSinceNow)s ago) — forcing reconnect")
                forceReconnectNow()
                return
            }
        }
    }

    private func failProbeIfSilent(since sentAt: Date) {
        guard lastReceiveAt < sentAt else { return }
        logger.log(.warning, "probe timed out — forcing reconnect")
        forceReconnectNow()
    }

    // MARK: - Reconnect

    private func scheduleReconnect() {
        if halted { return }
        // Retrying while the OS reports the path unsatisfied just produces an
        // immediate ENOTCONN every attempt and burns battery for the whole
        // outage. Park and let the path monitor's unsatisfied → satisfied
        // callback wake us.
        if !lastPathSatisfied {
            logger.log(.info, "reconnect deferred — network path unsatisfied")
            reconnectTask?.cancel()
            reconnectTask = nil
            return
        }
        reconnectTask?.cancel()
        let attempt = retryCount
        retryCount += 1
        let delay = configuration.backoff.delay(
            forAttempt: attempt,
            secondsSinceLastAttempt: Date().timeIntervalSince(lastConnectAttemptAt)
        )
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            await self.logReconnect(delay: delay, attempt: attempt)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self.performScheduledReconnect()
        }
    }

    private func logReconnect(delay: TimeInterval, attempt: Int) {
        logger.log(.info, "reconnecting in \(delay, privacy: .public)s (attempt=\(attempt))")
    }

    private func performScheduledReconnect() {
        reconnectTask = nil
        guard !halted else { return }
        // Re-check the path — it may have flipped during the backoff sleep.
        guard lastPathSatisfied else {
            logger.log(.info, "reconnect aborted — path went unsatisfied during backoff")
            return
        }
        doConnect()
    }

    // MARK: - Network path

    private func startPathMonitor() {
        if pathMonitor != nil { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = (path.status == .satisfied)
            Task { [weak self] in
                await self?.handlePathUpdate(satisfied: satisfied)
            }
        }
        monitor.start(queue: DispatchQueue(label: "pro.rave.net.path"))
    }

    private func handlePathUpdate(satisfied: Bool) {
        let wasSatisfied = lastPathSatisfied
        lastPathSatisfied = satisfied
        // Only react to unsatisfied → satisfied. The initial callback is
        // usually `.satisfied` and must not tear down a healthy connection.
        guard satisfied, !wasSatisfied else { return }
        logger.log(.info, "network path satisfied — forcing reconnect")
        forceReconnectNow()
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    // MARK: - Helpers

    private func teardownSocket() {
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    private func transition(to newState: RAVEConnectionState) {
        guard state != newState else { return }
        state = newState
        eventContinuation.yield(.stateChanged(newState))
    }
}
