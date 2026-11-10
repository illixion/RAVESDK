/*
 RAVEHome - Home Assistant WebSocket connection

 Implements the HA WebSocket API on top of `RAVENet`: the
 `auth_required → auth → auth_ok` handshake, id-correlated commands
 (`get_states`, `call_service`, …), and a `state_changed` event subscription
 that keeps a live entity store.

 The connection-management core that used to live here — ephemeral session,
 exponential backoff, keepalive, NWPathMonitor wake, scene-phase probe,
 halt-on-auth-failure — now lives in `RAVEWebSocketTransport`, shared with
 Spatial Stash's remote viewer, which is where most of it was adapted from in
 the first place.

 What stays here is everything protocol-shaped: framing, the auth handshake,
 request/response correlation, subscriptions, and the HA domain types. In
 particular **readiness is declared from here**, on `auth_ok` — the transport
 deliberately has no opinion about when a socket becomes usable, because
 Spatial Stash promotes on its first inbound frame instead.
 */

import DebugLog
import Foundation
import RAVENet

@MainActor
@Observable
public final class HAConnection: HomeBackend {
    // MARK: - Observable state

    /// Live entity store, keyed by entity id. Updated from the initial
    /// `get_states` snapshot and every `state_changed` event.
    public private(set) var entities: [String: HAEntity] = [:]
    @ObservationIgnored public var onSensorUpdate: ((HAEntity) -> Void)?
    @ObservationIgnored public var onSensorReset: (() -> Void)?
    /// Configuration actually used by this connection, rather than a Settings draft.
    public private(set) var activeConfig: HAConfig?

    /// Mirror of the transport's lifecycle, plus the app-declared transitions
    /// (`handshaking` on `auth_required`, `ready` on `auth_ok`, and recovery on
    /// `auth_invalid`) which are set here the moment they are decided rather
    /// than waiting to hear them back from the transport.
    public private(set) var state: RAVEConnectionState = .idle

    public var isConnected: Bool { state.isReady }

    // MARK: - HomeBackend status bridging

    /// Backend-agnostic status derived from the transport state.
    public var status: HomeBackendStatus {
        switch state {
        case .idle, .suspended: return .idle
        case .connecting, .handshaking: return .connecting
        case .ready: return .connected
        case .failed(let msg): return .unavailable(msg)
        }
    }

    /// The HA version, shown next to the status in Settings.
    public var statusDetail: String? {
        guard isConnected, let haVersion else { return nil }
        return "HA \(haVersion)"
    }

    /// True when it makes sense to kick off a fresh connection: nothing is in
    /// flight and we haven't halted on an auth failure (which lands in
    /// `.failed`, not `.idle`). Lets any window safely call `connect()` on
    /// appear without tearing down a live session.
    public var canStartConnection: Bool { state == .idle }

    /// HA version string reported on `auth_ok`, for display in Settings.
    public private(set) var haVersion: String?

    /// Area (room) registry: area_id → friendly name.
    public private(set) var areaNames: [String: String] = [:]
    /// entity_id → area_id, resolved from the entity registry (with a fallback
    /// to the entity's device area). Empty when the registries aren't available
    /// (e.g. a non-admin token).
    public private(set) var entityAreaId: [String: String] = [:]

    /// The room/area name for an entity, if known.
    public func areaName(forEntity entityId: String) -> String? {
        guard let areaId = entityAreaId[entityId] else { return nil }
        return areaNames[areaId]
    }

    /// The instance's configured name ("Home" unless renamed), from `get_config`.
    public private(set) var locationName: String?

    /// The home an entity belongs to. A Home Assistant instance is one home,
    /// named by its `location_name`; the server's host stands in until that
    /// arrives, or if it's blank.
    public func homeName(forEntity entityId: String) -> String? {
        if let locationName, !locationName.isEmpty { return locationName }
        return activeConfig.flatMap { URL(string: $0.trimmedBaseURL)?.host }
    }

    // MARK: - Connection internals

    private var transport: RAVEWebSocketTransport?
    private var eventTask: Task<Void, Never>?
    private var accessToken: String = ""

    /// Everything this class tells the transport — frames and the handshake
    /// declarations alike — is funnelled through one stream consumed by one
    /// task, so it reaches the transport actor in the order it was decided.
    /// Separate `Task`s would leave that order to the scheduler, and a
    /// `markReady` could overtake the `markHandshaking` before it.
    private var outboundContinuation: AsyncStream<(Outbound, generation: UInt64)>.Continuation?
    private var outboundTask: Task<Void, Never>?

    /// Identity of the socket whose ordered events the app is handling.
    private var socketGeneration: UInt64 = 0
    private var bootstrapTask: Task<Void, Never>?

    private enum Outbound {
        case frame(String)
        case handshake(String)
        case markHandshaking
        case markReady
        case rejectHandshake(String)
    }

    private static let commandTimeout: TimeInterval = 15

    // MARK: - Command id correlation

    private var nextCommandId: Int = 1
    private var pending: [Int: CheckedContinuation<ResultBox, Error>] = [:]

    /// Wraps a command's loosely-typed `result` so it can cross the
    /// continuation's `sending` boundary. Safe because every access happens
    /// on the main actor (this class is `@MainActor`).
    struct ResultBox: @unchecked Sendable {
        let value: Any?
    }

    public enum HAError: LocalizedError {
        case notConnected
        case serverError(String)
        case timeout

        public var errorDescription: String? {
            switch self {
            case .notConnected: return "Not connected to Home Assistant"
            case .serverError(let msg): return msg
            case .timeout: return "Home Assistant did not respond in time"
            }
        }
    }

    public init() {}

    // MARK: - Lifecycle

    /// (Re)configure and connect. Safe to call when the config changes; tears
    /// down any existing connection first, which also clears a previous halt.
    public func connect(config: HAConfig) {
        disconnect()
        if activeConfig != config {
            entities = [:]
            locationName = nil
            onSensorReset?()
        }
        activeConfig = config
        guard let wsURL = config.webSocketURL, config.isConfigured else {
            activeConfig = nil
            state = .idle
            return
        }
        accessToken = config.trimmedToken

        let transport = RAVEWebSocketTransport(
            configuration: .init(url: wsURL, requiresHandshake: true, handshakeRetryLimit: 1),
            logger: HomeTransportLogger(),
            pingFrameProvider: { [weak self] in
                guard let self else { return nil }
                return await self.nextPingFrame()
            }
            // No failure policy: HA signals a bad token with an `auth_invalid`
            // *frame*, not a close code, so the halt is declared from
            // `handleMessage` rather than decided at the socket layer.
        )
        self.transport = transport

        socketGeneration = 0
        let (outbound, continuation) = AsyncStream<(Outbound, generation: UInt64)>.makeStream(bufferingPolicy: .unbounded)
        outboundContinuation = continuation
        outboundTask = Task {
            for await (item, generation) in outbound {
                guard !Task.isCancelled else { return }
                switch item {
                case .frame(let text): await transport.send(text, generation: generation)
                case .markHandshaking: await transport.markHandshaking(generation: generation)
                case .markReady: await transport.markReady(generation: generation)
                case .handshake(let text): await transport.sendHandshake(text, generation: generation)
                case .rejectHandshake(let reason): await transport.rejectHandshake(reason: reason, generation: generation)
                }
            }
        }

        // Inherits this class's main-actor isolation, so `handle` is a direct
        // call — only the stream iteration suspends.
        eventTask = Task { [weak self] in
            for await event in transport.events {
                guard let self, !Task.isCancelled, self.transport === transport else { return }
                self.handle(event)
            }
        }

        Task { await transport.start() }
    }

    public func disconnect() {
        bootstrapTask?.cancel()
        bootstrapTask = nil
        eventTask?.cancel()
        eventTask = nil
        outboundContinuation?.finish()
        outboundContinuation = nil
        outboundTask?.cancel()
        outboundTask = nil
        let outgoing = transport
        transport = nil
        Task { await outgoing?.stop() }
        failAllPending(HAError.notConnected)
        state = .idle
    }

    /// Probe the socket with a ping; reconnect only if it's silent. Call this on
    /// scene-phase wakes — visionOS flutters scenePhase on gaze shifts, so a
    /// healthy socket should be left alone (it answers the ping with a pong).
    public func probeOrReconnect(timeout: TimeInterval = 3) {
        guard let transport else { return }
        Task { await transport.probeOrReconnect(timeout: timeout) }
    }

    public func forceReconnectNow() {
        guard let transport else { return }
        Task { await transport.forceReconnectNow() }
    }

    // MARK: - Transport events

    private func handle(_ event: RAVENetEvent) {
        switch event {
        case .frame(let text, let generation):
            guard generation == socketGeneration else { return }
            handleMessage(text)

        case .stateChanged(let newState, let generation):
            socketGeneration = generation
            // Handshake progress is applied synchronously from frames. A delayed
            // echo must not demote an already-authenticated socket.
            if newState == .handshaking || newState.isReady { return }
            state = newState
            if !newState.isReady {
                bootstrapTask?.cancel()
                bootstrapTask = nil
                failAllPending(HAError.notConnected)
            }

        case .failure:
            // Already logged with full diagnostics by the transport, and the
            // reconnect decision is its own. Nothing to add here.
            break
        }
    }

    // MARK: - Commands

    /// Send a typed command and await its `result`. Throws on transport
    /// failure, server `success: false`, or timeout.
    @discardableResult
    public func sendCommand(_ type: String, _ extra: [String: Any] = [:]) async throws -> Any? {
        try Task.checkCancellation()
        guard isConnected else { throw HAError.notConnected }
        let id = nextCommandId
        nextCommandId += 1

        var message = extra
        message["id"] = id
        message["type"] = type

        let box: ResultBox = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ResultBox, Error>) in
            pending[id] = cont
            send(message)
            // Timeout guard so a dropped result doesn't leak the continuation.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.commandTimeout))
                guard let self, let cont = self.pending.removeValue(forKey: id) else { return }
                cont.resume(throwing: HAError.timeout)
            }
        }
        try Task.checkCancellation()
        return box.value
    }

    /// Call a Home Assistant service.
    @discardableResult
    public func callService(domain: String, service: String, entityId: String? = nil,
                     data: [String: Any] = [:]) async throws -> Any? {
        var extra: [String: Any] = ["domain": domain, "service": service]
        if let entityId { extra["target"] = ["entity_id": entityId] }
        if !data.isEmpty { extra["service_data"] = data }
        return try await sendCommand("call_service", extra)
    }

    /// Fire-and-forget service call that logs failures (used from UI taps).
    public func callServiceDetached(domain: String, service: String, entityId: String? = nil,
                            data: [String: Any] = [:]) {
        Task { [weak self] in
            do {
                try await self?.callService(domain: domain, service: service, entityId: entityId, data: data)
            } catch {
                HomeLog.entities.error("call_service \(domain, privacy: .public).\(service, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    // MARK: - Convenience actions

    /// Perform the natural "tap" action for an entity's domain.
    public func performDefaultAction(on entity: HAEntity) {
        let id = entity.entityId
        switch entity.domain {
        case "light", "switch", "fan", "input_boolean", "humidifier", "siren", "remote", "automation":
            callServiceDetached(domain: entity.domain, service: "toggle", entityId: id)
        case "climate":
            if entity.state == "off" {
                // Try to turn it on (restore previous mode or auto)
                callServiceDetached(domain: "climate", service: "turn_on", entityId: id)
            } else {
                callServiceDetached(domain: "climate", service: "turn_off", entityId: id)
            }
        case "scene":
            callServiceDetached(domain: "scene", service: "turn_on", entityId: id)
        case "script":
            callServiceDetached(domain: "script", service: "turn_on", entityId: id)
        case "lock":
            callServiceDetached(domain: "lock", service: entity.state == "locked" ? "unlock" : "lock", entityId: id)
        case "cover":
            callServiceDetached(domain: "cover", service: entity.isOn || entity.state == "open" ? "close_cover" : "open_cover", entityId: id)
        case "button", "input_button":
            callServiceDetached(domain: entity.domain, service: "press", entityId: id)
        default:
            // Best-effort: most toggleable HA domains accept "toggle".
            callServiceDetached(domain: "homeassistant", service: "toggle", entityId: id)
        }
    }

    public func setLightBrightness(entityId: String, fraction: Double) {
        let pct = max(0, min(100, Int((fraction * 100).rounded())))
        if pct == 0 {
            callServiceDetached(domain: "light", service: "turn_off", entityId: entityId)
        } else {
            callServiceDetached(domain: "light", service: "turn_on", entityId: entityId,
                               data: ["brightness_pct": pct])
        }
    }

    public func setSliderFraction(entity: HAEntity, fraction: Double) {
        let pct = max(0, min(100, Int((fraction * 100).rounded())))
        let id = entity.entityId

        switch entity.domain {
        case "light":
            setLightBrightness(entityId: id, fraction: fraction)
        case "fan":
            if pct == 0 {
                callServiceDetached(domain: "fan", service: "turn_off", entityId: id)
            } else {
                callServiceDetached(domain: "fan", service: "set_percentage", entityId: id, data: ["percentage": pct])
            }
        case "cover":
            callServiceDetached(domain: "cover", service: "set_cover_position", entityId: id, data: ["position": pct])
        case "media_player":
            let vol = max(0.0, min(1.0, fraction))
            callServiceDetached(domain: "media_player", service: "volume_set", entityId: id, data: ["volume_level": vol])
        case "humidifier":
            callServiceDetached(domain: "humidifier", service: "set_humidity", entityId: id, data: ["humidity": pct])
        case "climate":
            let modes = entity.climateFanModes
            guard !modes.isEmpty else { return }
            // Map the 0.0...1.0 fraction to evenly distributed buckets
            var idx = Int(ceil(fraction * Double(modes.count))) - 1
            if idx < 0 { idx = 0 }
            if idx >= modes.count { idx = modes.count - 1 }
            let mode = modes[idx]
            callServiceDetached(domain: "climate", service: "set_fan_mode", entityId: id, data: ["fan_mode": mode])
        default:
            break
        }
    }

    public func setLightColorTempKelvin(entityId: String, kelvin: Int) {
        callServiceDetached(domain: "light", service: "turn_on", entityId: entityId,
                           data: ["color_temp_kelvin": kelvin])
    }

    // MARK: - Awaitable apply

    /// Put an entity in `desired`, returning when Home Assistant has accepted
    /// the service call (`HomeBackend.apply`).
    public func apply(_ desired: HomeDesiredState, toEntity id: String) async throws {
        let domain = entities[id]?.domain ?? String(id.prefix { $0 != "." })
        let call: (service: String, data: [String: Any])
        switch desired {
        case .on:
            call = ("turn_on", [:])
        case .off:
            call = ("turn_off", [:])
        case .level(let raw):
            let percent = max(0, min(100, raw))
            switch domain {
            case "light":
                call = percent == 0 ? ("turn_off", [:]) : ("turn_on", ["brightness_pct": percent])
            case "fan":
                call = percent == 0 ? ("turn_off", [:]) : ("set_percentage", ["percentage": percent])
            case "cover": call = ("set_cover_position", ["position": percent])
            case "humidifier": call = ("set_humidity", ["humidity": percent])
            case "media_player": call = ("volume_set", ["volume_level": Double(percent) / 100])
            default: throw HomeActionError.unsupported("\(DomainDisplayName.singular(domain)) has no level")
            }
        case .locked:
            call = ("lock", [:])
        case .unlocked:
            call = ("unlock", [:])
        case .open:
            call = ("open_cover", [:])
        case .closed:
            call = ("close_cover", [:])
        case .activate:
            call = (domain == "button" || domain == "input_button" ? "press" : "turn_on", [:])
        }
        do {
            try await callService(domain: domain, service: call.service, entityId: id, data: call.data)
        } catch let error as HAError {
            throw HomeActionError.failed(error.localizedDescription)
        }
    }

    // MARK: - Climate controls

    public func setClimateTemperature(entityId: String, temperature: Double) {
        callServiceDetached(domain: "climate", service: "set_temperature", entityId: entityId,
                            data: ["temperature": temperature])
    }

    public func setClimateHvacMode(entityId: String, mode: String) {
        callServiceDetached(domain: "climate", service: "set_hvac_mode", entityId: entityId,
                            data: ["hvac_mode": mode])
    }

    public func setClimateFanMode(entityId: String, mode: String) {
        callServiceDetached(domain: "climate", service: "set_fan_mode", entityId: entityId,
                            data: ["fan_mode": mode])
    }

    public func setClimatePresetMode(entityId: String, mode: String) {
        callServiceDetached(domain: "climate", service: "set_preset_mode", entityId: entityId,
                            data: ["preset_mode": mode])
    }

    public func setClimateSwingMode(entityId: String, mode: String) {
        callServiceDetached(domain: "climate", service: "set_swing_mode", entityId: entityId,
                            data: ["swing_mode": mode])
    }

    // MARK: - Protocol handling

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            HomeLog.connection.debug("WS rx (unparseable)")
            return
        }
        HomeLog.connection.debug("WS rx type=\(type, privacy: .public)")

        switch type {
        case "auth_required":
            state = .handshaking
            enqueue(.markHandshaking)
            send(["type": "auth", "access_token": accessToken], handshake: true)

        case "auth_ok":
            haVersion = json["ha_version"] as? String
            // Readiness is ours to declare, so apply it here rather than
            // waiting for the transport's echo — `sendCommand` gates on
            // `isConnected`, and the bootstrap below sends immediately.
            state = .ready
            HomeLog.connection.info("WS authenticated (HA \(self.haVersion ?? "?", privacy: .public))")
            // Queued ahead of the bootstrap's commands, so the transport is
            // ready (and the keepalive running) before they go out.
            enqueue(.markReady)
            bootstrapTask?.cancel()
            bootstrapTask = Task { [weak self] in await self?.bootstrapAfterAuth() }

        case "auth_invalid":
            let msg = (json["message"] as? String) ?? "Invalid access token"
            state = .connecting
            HomeLog.connection.error("WS auth invalid: \(msg, privacy: .private)")
            // The transport retries once, then exposes an actionable terminal state.
            enqueue(.rejectHandshake("Authentication rejected. Reconnect or update your Home Assistant token."))

        case "result":
            handleResult(json)

        case "event":
            handleEvent(json)

        case "pong":
            break // liveness already recorded by the transport

        default:
            break
        }
    }

    private func handleResult(_ json: [String: Any]) {
        guard let id = json["id"] as? Int else { return }
        guard let cont = pending.removeValue(forKey: id) else { return }
        let success = (json["success"] as? Bool) ?? true
        if success {
            cont.resume(returning: ResultBox(value: json["result"]))
        } else {
            let errDict = json["error"] as? [String: Any]
            let message = (errDict?["message"] as? String) ?? "Command failed"
            cont.resume(throwing: HAError.serverError(message))
        }
    }

    private func handleEvent(_ json: [String: Any]) {
        guard let event = json["event"] as? [String: Any],
              (event["event_type"] as? String) == "state_changed",
              let dataDict = event["data"] as? [String: Any],
              let entityId = dataDict["entity_id"] as? String else { return }

        if let newState = dataDict["new_state"] as? [String: Any] {
            if let entity = Self.parseEntity(newState) {
                entities[entity.entityId] = entity
                onSensorUpdate?(entity)
            }
        } else {
            // new_state is null → entity removed.
            entities.removeValue(forKey: entityId)
        }
    }

    /// After auth: seed the store with a full snapshot, then subscribe to
    /// state changes so the store stays live.
    private func bootstrapAfterAuth() async {
        do {
            let result = try await sendCommand("get_states")
            if let states = result as? [[String: Any]] {
                var store: [String: HAEntity] = [:]
                store.reserveCapacity(states.count)
                for dict in states {
                    if let entity = Self.parseEntity(dict) {
                        store[entity.entityId] = entity
                    }
                }
                entities = store
                for entity in store.values { onSensorUpdate?(entity) }
                HomeLog.entities.info("Loaded \(store.count) entities")
            }
            try await sendCommand("subscribe_events", ["event_type": "state_changed"])
            HomeLog.connection.info("Subscribed to state_changed")
        } catch {
            HomeLog.connection.error("Bootstrap failed: \(error.localizedDescription, privacy: .private)")
        }
        guard !Task.isCancelled else { return }
        if let config = try? await sendCommand("get_config") as? [String: Any] {
            locationName = (config["location_name"] as? String)?.trimmingCharacters(in: .whitespaces)
        }
        // Registries power room grouping in Browse. They require an admin token;
        // failure degrades gracefully to "no room" grouping.
        await loadAreaRegistry()
    }

    /// Fetch the area, device, and entity registries and build the
    /// entity → area map used for room grouping.
    private func loadAreaRegistry() async {
        do {
            if let areas = try await sendCommand("config/area_registry/list") as? [[String: Any]] {
                var names: [String: String] = [:]
                for a in areas {
                    if let id = a["area_id"] as? String {
                        names[id] = (a["name"] as? String) ?? id
                    }
                }
                areaNames = names
            }

            var deviceArea: [String: String] = [:]
            if let devices = try await sendCommand("config/device_registry/list") as? [[String: Any]] {
                for d in devices {
                    if let id = d["id"] as? String, let area = d["area_id"] as? String {
                        deviceArea[id] = area
                    }
                }
            }

            if let regEntities = try await sendCommand("config/entity_registry/list") as? [[String: Any]] {
                var map: [String: String] = [:]
                for e in regEntities {
                    guard let entityId = e["entity_id"] as? String else { continue }
                    if let area = e["area_id"] as? String {
                        map[entityId] = area
                    } else if let deviceId = e["device_id"] as? String, let area = deviceArea[deviceId] {
                        map[entityId] = area
                    }
                }
                entityAreaId = map
                HomeLog.entities.info("Resolved areas for \(map.count) entities across \(self.areaNames.count) rooms")
            }
        } catch {
            HomeLog.entities.info("Area registry unavailable (\(error.localizedDescription, privacy: .private)) — room grouping disabled")
        }
    }

    public nonisolated static func parseEntity(_ dict: [String: Any]) -> HAEntity? {
        guard let entityId = dict["entity_id"] as? String,
              let state = dict["state"] as? String else { return nil }
        let attributes = (dict["attributes"] as? [String: Any]) ?? [:]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = (dict["last_updated"] as? String).flatMap {
            fractional.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
        }
        return HAEntity(entityId: entityId, state: state, attributes: attributes, lastUpdated: date)
    }

    // MARK: - Send

    private func send(_ dict: [String: Any], handshake: Bool = false) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        let type = dict["type"] as? String ?? "unknown"
        HomeLog.connection.debug("WS tx type=\(type, privacy: .public) generation=\(self.socketGeneration, privacy: .public)")
        enqueue(handshake ? .handshake(text) : .frame(text))
    }

    private func enqueue(_ item: Outbound) {
        outboundContinuation?.yield((item, generation: socketGeneration))
    }

    /// Builds the transport's keepalive frame. Consumes a command id, but the
    /// pong arrives as a bare `{type: pong}` frame (not a `result`), so no
    /// continuation is registered for it — the transport records the liveness.
    private func nextPingFrame() -> String? {
        guard isConnected else { return nil }
        let id = nextCommandId
        nextCommandId += 1
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": id, "type": "ping"]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    // MARK: - Helpers

    private func failAllPending(_ error: Error) {
        guard !pending.isEmpty else { return }
        let conts = pending
        pending.removeAll()
        for (_, cont) in conts { cont.resume(throwing: error) }
    }
}
