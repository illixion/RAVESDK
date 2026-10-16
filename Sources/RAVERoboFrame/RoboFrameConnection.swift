/*
 RAVERoboFrame - connection

 One WebSocket to a RoboFrame server, shared by every session (window) that
 points at it, each multiplexed under its own sessionId. Connection
 management (backoff, keepalive, path gating, probe-on-wake, suspend/revive)
 is RAVENet's `RAVEWebSocketTransport`; what lives here is RoboFrame-shaped:

 - **Readiness is declared here**, on the first inbound frame: the server
   sends `tagLists` on connect, and the transport has no opinion about when a
   socket becomes usable.
 - **Every (re)connect replays.** The server forgets session bindings and
   scene reports with the socket, so each session's `onConnected` re-sends
   `slideshowConfig`, and then every present/visibility aggregate is
   re-stated — in that order, per the protocol's checklist.
 - **A session speaks only once it has joined.** The server drops a
   session-scoped frame (`present`, `setModTags`, `requestNext`, …) from a
   session it has no `slideshowConfig` for, so until a session's
   `slideshowConfig` has gone out on the current socket its other frames are
   held, and sent right after it. A window opened on a live connection, or a
   call made between a reconnect and the replay, would otherwise be lost.
 - **Frames go out in order.** They funnel through one stream into the
   transport actor; a `Task` per frame would leave ordering to the scheduler,
   and `slideshowConfig` must precede the scene replay.
 - **A rejected token halts.** The broker closes a bad upgrade with 1008;
   reconnecting can't fix that, so the loop stops and sessions get `.halted`.
 */

import Foundation
import Observation
import RAVENet

/// One session's callbacks. `onConnected` fires after every (re)connect:
/// send `slideshowConfig` from it.
@MainActor
public final class RoboFrameSessionHandlers {
    public var onMessage: ((RoboFrameMessage) -> Void)?
    public var onConnected: (() -> Void)?

    public init() {}
}

@MainActor
@Observable
public final class RoboFrameConnection {
    /// Home Assistant sensors the server forwards, by entity id.
    public private(set) var sensors: [String: RoboFrameSensorReading] = [:]

    /// Mirrors the transport, plus the promotion to `.ready` declared here.
    public private(set) var state: RAVEConnectionState = .idle

    /// True once frames are flowing, not merely once the socket upgraded.
    public var isConnected: Bool { state.isReady }

    public let url: URL

    @ObservationIgnored private let logger: any RAVENetLogger
    @ObservationIgnored private var transport: RAVEWebSocketTransport?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var outbound: AsyncStream<String>.Continuation?
    @ObservationIgnored private var outboundTask: Task<Void, Never>?
    @ObservationIgnored private var sessions: [String: RoboFrameSessionHandlers] = [:]
    @ObservationIgnored private var scene = RoboFrameSceneState()
    /// Sessions whose `slideshowConfig` went out on the current socket.
    @ObservationIgnored private var joined: Set<String> = []
    /// Session-scoped frames sent before the session joined, oldest first.
    @ObservationIgnored private var held: [String: [String]] = [:]
    /// The server sends `tagLists` once per socket, on connect; a session
    /// that attaches later gets this copy.
    @ObservationIgnored private var tagLists: [[String]]?
    private static let maxHeldFrames = 32

    /// - Parameters:
    ///   - url: The WebSocket URL, token included (`RoboFrameEndpoint.webSocketURL`).
    ///   - logger: Where transport and protocol lines go. RAVENet logs the
    ///     endpoint without its query, so the token never reaches a log.
    public init(url: URL, logger: any RAVENetLogger = RAVENetOSLogger(subsystem: "pro.rave.roboframe")) {
        self.url = url
        self.logger = logger
    }

    // MARK: - Sessions

    /// Attach a session, connecting on the first one. Wire the returned
    /// handlers synchronously; `onConnected` fires once the connection is
    /// (or already was) carrying frames.
    @discardableResult
    public func attachSession(_ sessionId: String) -> RoboFrameSessionHandlers {
        if let existing = sessions[sessionId] { return existing }
        let handlers = RoboFrameSessionHandlers()
        sessions[sessionId] = handlers

        if transport == nil {
            connect()
        } else if isConnected {
            // A late joiner: deliver onConnected after the caller has wired it.
            // Re-checked when it runs, since a suspend can land in between.
            Task { @MainActor [weak self, weak handlers] in
                guard let self else { return }
                guard self.isConnected else { return self.reviveIfIdle() }
                handlers?.onConnected?()
                if let tagLists = self.tagLists { handlers?.onMessage?(.tagLists(tagLists)) }
            }
        } else {
            // The socket was released (every other session went absent). A
            // new session is its own reason to bring it back; waiting for an
            // unrelated wake left it on a spinner with no slideshowConfig sent.
            reviveIfIdle()
        }
        return handlers
    }

    /// Detach a session, telling the server it left. Returns how many
    /// sessions remain; at zero, call `disconnect()`.
    @discardableResult
    public func detachSession(_ sessionId: String) -> Int {
        guard sessions.removeValue(forKey: sessionId) != nil else { return sessions.count }
        if isConnected {
            if let contribution = scene.contribution(for: sessionId) {
                send("present", sessionId: sessionId, payload: ["deviceId": contribution.deviceId, "present": false])
            }
            send("sessionEnd", sessionId: sessionId)
        }
        scene.remove(sessionId: sessionId)
        joined.remove(sessionId)
        held.removeValue(forKey: sessionId)
        if isConnected { flushScene() }
        return sessions.count
    }

    public var attachedSessionCount: Int { sessions.count }

    // MARK: - Lifecycle

    private func connect() {
        let transport = RAVEWebSocketTransport(
            configuration: .init(url: url),
            logger: logger,
            pingFrameProvider: { #"{"action":"ping"}"# },
            failurePolicy: { failure in
                guard failure.closeCode == .policyViolation else { return .reconnect }
                let reason = failure.closeReason.flatMap { $0.isEmpty ? nil : $0 } ?? "invalid token"
                return .halt("Server rejected the connection: \(reason). Check the access token.")
            }
        )
        self.transport = transport

        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        outbound = continuation
        outboundTask = Task {
            for await frame in stream {
                await transport.send(frame)
            }
        }
        eventTask = Task { [weak self] in
            for await event in transport.events {
                guard let self else { return }
                self.handle(event)
            }
        }
        Task { await transport.start() }
    }

    /// Close the socket and drop the transport. A later attach reconnects.
    public func disconnect() {
        eventTask?.cancel()
        eventTask = nil
        outbound?.finish()
        outbound = nil
        outboundTask?.cancel()
        outboundTask = nil
        let outgoing = transport
        transport = nil
        Task { await outgoing?.stop() }
        state = .idle
        joined.removeAll()
        tagLists = nil
    }

    /// Ping, and reconnect only if nothing answers within `timeout`. The
    /// right call on a wake: a healthy socket is left alone, so peers don't
    /// see a spurious `displayDisconnect`.
    public func probeOrReconnect(timeout: TimeInterval = 3) {
        guard let transport else { return }
        Task { await transport.probeOrReconnect(timeout: timeout) }
    }

    /// Reconnect now, skipping any backoff in progress.
    public func forceReconnectNow() {
        guard let transport else { return }
        Task { await transport.forceReconnectNow() }
    }

    private func reviveIfIdle() {
        guard let transport else { return }
        Task { await transport.reviveIfIdle() }
    }

    /// Flush queued frames (notably a just-reported `present:false`) and, if
    /// no session is present any more, close the socket cleanly. Await it
    /// under a background-task assertion, or the app suspends mid-flush.
    public func flushAndSuspendIfAbsent() async {
        guard let transport else { return }
        await transport.flushAndSuspend { [weak self] in
            await self?.allSessionsAbsent ?? false
        }
    }

    // MARK: - Transport events

    private func handle(_ event: RAVENetEvent) {
        switch event {
        case .frame(let text):
            if !isConnected { promoteToConnected() }
            receive(text)
        case .stateChanged(let newState):
            guard state != newState else { return }
            // Ready is declared here, on a frame, never heard back: a markReady
            // queued for a socket that has since been replaced lands on the new
            // one, and adopting its echo would skip that socket's replay.
            if newState.isReady { return }
            state = newState
            if !newState.isReady {
                joined.removeAll()
                tagLists = nil
            }
            if case .failed(let reason) = newState {
                logger.log(.error, "halted: \(reason)")
                broadcast(.halted(reason: reason))
            }
        case .failure:
            // Logged by the transport; the reconnect-or-halt call was our policy's.
            break
        }
    }

    private func promoteToConnected() {
        // Applied here rather than heard back, because the replay below sends
        // straight away and sends gate on `isConnected`.
        state = .ready
        if let transport { Task { await transport.markReady() } }
        // Each session's slideshowConfig (sent from onConnected) joins it and
        // sends its presence; the closing flush covers the rest.
        joined.removeAll()
        scene.forgetSent()
        for handlers in sessions.values { handlers.onConnected?() }
        flushScene()
    }

    private func receive(_ text: String) {
        guard let inbound = RoboFrameFrames.decode(text) else {
            logger.log(.debug, "rx unparseable frame (\(text.utf8.count) bytes)")
            return
        }
        logger.log(.debug, "rx action=\(inbound.action, privacy: .public)")
        switch inbound.kind {
        case .ping:
            send("pong")
        case .pong:
            break
        case .message(let message):
            deliver(message, sessionIds: inbound.sessionIds)
        case nil:
            logger.log(.debug, "rx ignored action=\(inbound.action, privacy: .public)")
        }
    }

    private func deliver(_ message: RoboFrameMessage, sessionIds: [String]) {
        switch message {
        case .playback, .searchEmpty:
            // Session-scoped. A frame naming no sessions goes to all of them,
            // so something renders.
            guard !sessionIds.isEmpty else { return broadcast(message) }
            for id in sessionIds { sessions[id]?.onMessage?(message) }
        case .tagLists(let lists):
            tagLists = lists
            broadcast(message)
        case .sensor(var reading):
            if reading.isUnavailable {
                guard let known = sensors[reading.entityId] else { return broadcast(message) }
                reading.state = known.state
            }
            sensors[reading.entityId] = reading
            broadcast(.sensor(reading))
        default:
            broadcast(message)
        }
    }

    private func broadcast(_ message: RoboFrameMessage) {
        for handlers in sessions.values { handlers.onMessage?(message) }
    }

    // MARK: - Scene state

    /// Record a session's scene state and send the edges that changed.
    /// `present` drives the slideshow; `visible` is the HA motion telemetry.
    public func reportSceneState(sessionId: String, deviceId: String, present: Bool, visible: Bool) {
        scene.report(sessionId: sessionId, deviceId: deviceId, present: present, visible: visible)
        flushScene()
    }

    /// True when no session on this connection is present.
    public var allSessionsAbsent: Bool { scene.allAbsent }

    private func flushScene(force: Bool = false) {
        // Nothing reaches a dead socket, and the reconnect replays everything,
        // so keep the reports and wait. A present session is a reason to
        // bring the socket back rather than wait for some other wake.
        guard isConnected else {
            if !scene.allAbsent { reviveIfIdle() }
            return
        }
        for report in scene.flush(force: force, joined: joined) {
            switch report {
            case .present(let sessionId, let deviceId, let present):
                logger.log(.info, "tx present sessionId=\(sessionId, privacy: .private(mask: .hash)) deviceId=\(deviceId, privacy: .private(mask: .hash)) present=\(present, privacy: .public)")
                send("present", sessionId: sessionId, payload: ["deviceId": deviceId, "present": present])
            case .visibility(let deviceId, let visible):
                logger.log(.info, "tx visibility deviceId=\(deviceId, privacy: .private(mask: .hash)) visible=\(visible, privacy: .public)")
                send("visibility", payload: ["deviceId": deviceId, "visible": visible])
            }
        }
    }

    // MARK: - Sending

    /// Join (or re-join) the session's channel. Send from `onConnected`.
    public func sendSlideshowConfig(sessionId: String, _ config: RoboFrameSlideshowConfig) {
        send("slideshowConfig", sessionId: sessionId, payload: RoboFrameFrames.slideshowConfigPayload(config))
        // Sent before the socket is ready, it may reach a server that then
        // forgets it; onConnected sends it again, and that one joins.
        guard isConnected, sessions[sessionId] != nil, joined.insert(sessionId).inserted else { return }
        for frame in held.removeValue(forKey: sessionId) ?? [] { outbound?.yield(frame) }
        flushScene()
    }

    /// The session has shown `postId`. Send once per transition, with the id
    /// of the latest `playback.current`. `durationMs` is a video's length:
    /// the server dwells for the longer of it and the interval.
    public func sendImageReady(sessionId: String, postId: Int, durationMs: Int? = nil) {
        var payload: [String: Any] = ["id": postId]
        if let durationMs, durationMs > 0 { payload["durationMs"] = durationMs }
        send("imageReady", sessionId: sessionId, payload: payload)
    }

    /// Advance the channel (the merge driver's, while a displaySync is held).
    public func sendRequestNext(sessionId: String) {
        send("requestNext", sessionId: sessionId)
    }

    public func sendReshuffle(sessionId: String) {
        send("reshuffle", sessionId: sessionId)
    }

    public func sendSetModTags(sessionId: String, tags: [String]) {
        send("setModTags", sessionId: sessionId, payload: ["tags": tags])
    }

    public func sendSetTagList(sessionId: String, listNumber: Int) {
        send("setTagList", sessionId: sessionId, payload: ["listNumber": listNumber])
    }

    /// Claim (`true`) or release the merge: while held, every display mirrors this channel.
    public func sendDisplaySync(sessionId: String, enabled: Bool) {
        send("displaySync", sessionId: sessionId, payload: ["enabled": enabled])
    }

    /// Ask for `target`'s cached panel state; it comes back as `displayState`.
    public func sendGetDisplayState(target: String) {
        send("getDisplayState", payload: ["target": target])
    }

    public func sendBlock(postId: Int) {
        send("block", payload: ["id": postId])
    }

    /// A periodic device sample (`reportMetrics`), connection-wide.
    public func sendReportMetrics(_ payload: [String: Any]) {
        guard isConnected else { return }
        send("reportMetrics", payload: payload)
    }

    /// One event-log line (`reportLog`), connection-wide.
    public func sendReportLog(deviceId: String, app: String, level: String, domain: String, message: String) {
        guard isConnected else { return }
        send("reportLog", payload: [
            "deviceId": deviceId,
            "app": app,
            "level": level,
            "domain": domain,
            "message": message,
            "ts": Int(Date().timeIntervalSince1970 * 1_000),
        ])
    }

    private func send(_ action: String, sessionId: String? = nil, payload: [String: Any]? = nil) {
        guard let frame = RoboFrameFrames.encode(action: action, sessionId: sessionId, payload: payload) else {
            logger.log(.warning, "tx dropped unencodable action=\(action, privacy: .public)")
            return
        }
        if let sessionId, !Self.joinActions.contains(action), !joined.contains(sessionId), sessions[sessionId] != nil {
            var frames = held[sessionId] ?? []
            frames.append(frame)
            if frames.count > Self.maxHeldFrames { frames.removeFirst(frames.count - Self.maxHeldFrames) }
            held[sessionId] = frames
            return
        }
        outbound?.yield(frame)
    }

    /// Session-scoped actions that go out before (or without) a join.
    private static let joinActions: Set<String> = ["slideshowConfig", "present", "sessionEnd"]
}
