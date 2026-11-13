/*
 RAVEDebugAccess - the computer's side (macOS)

 What the `rave-debug` helper is made of: the records of the apps this
 computer is paired with, the pairing itself, and a loopback proxy that
 carries plain HTTP from a local tool (DebugTrace's `debugtrace-mcp`, which
 is dependency-free Python and can't do TLS-PSK) to the app over the paired
 channel.

 The proxy listens on 127.0.0.1 only and wants a bearer token of its own,
 made per run and handed to whoever started it. Without that, anything on
 this Mac that can open a socket (another user, a web page through the
 browser) could use the pairing.
 */

#if os(macOS)
import CryptoKit
import DebugLog
import Foundation
import Network
import os
import RAVECompanion

/// An app this computer is paired with.
public struct RAVEDebugPairedApp: Codable, Sendable, Identifiable, Equatable {
    public var id: String { hostID }
    /// The app install's id (`RAVEDebugAccess.hostID`).
    public let hostID: String
    /// What the app called itself: "Apparition on Apple Vision Pro".
    public var name: String
    /// This computer's id towards the app.
    public let computerID: String
    let token: String
    /// The device's addresses when it was paired.
    public var addresses: [String]
    /// An address or name the person gave (a tailnet name), tried first.
    public var host: String?
    /// The paired listener's port the last time it answered.
    public var lastPort: UInt16?
    public let pairedAt: Date

    /// For listings: everything but the token.
    public var summary: [String: Any] {
        var summary: [String: Any] = [
            "id": hostID, "name": name, "addresses": addresses,
            "pairedAt": ISO8601DateFormatter().string(from: pairedAt),
        ]
        if let host { summary["host"] = host }
        if let lastPort { summary["lastPort"] = Int(lastPort) }
        return summary
    }
}

/// The records, one file per app, readable by this user only. They hold each
/// pairing's token: whoever can read one can debug that app.
public struct RAVEDebugPairedApps: Sendable {
    public let directory: URL

    /// `$DEBUGTRACE_STATE_DIR/paired`, else `~/.local/state/debugtrace/paired`:
    /// beside the rest of DebugTrace's Mac-side state, where `debugtrace-mcp` lists them.
    public static var defaultDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        let state = environment["DEBUGTRACE_STATE_DIR"].flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".local/state/debugtrace")
        return URL(fileURLWithPath: state, isDirectory: true).appendingPathComponent("paired", isDirectory: true)
    }

    public init(directory: URL = RAVEDebugPairedApps.defaultDirectory) {
        self.directory = directory
    }

    private func url(_ hostID: String) -> URL {
        // An id is the app's own UUID string; anything else never becomes a path.
        let safe = hostID.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
        return directory.appendingPathComponent("\(safe && !hostID.isEmpty ? hostID : "invalid").json")
    }

    public func all() -> [RAVEDebugPairedApp] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            (try? Data(contentsOf: directory.appendingPathComponent(name))).flatMap { try? decoder.decode(RAVEDebugPairedApp.self, from: $0) }
        }.sorted { $0.pairedAt < $1.pairedAt }
    }

    /// By id, by an id's unique beginning, or by name (case-insensitive): the whole name,
    /// or the app's part of "<app> on <device>".
    public func app(_ reference: String) -> RAVEDebugPairedApp? {
        let apps = all()
        if let exact = apps.first(where: { $0.hostID == reference }) { return exact }
        let folded = reference.lowercased()
        let matches = apps.filter {
            let name = $0.name.lowercased()
            return $0.hostID.lowercased().hasPrefix(folded) || name == folded || name.hasPrefix(folded + " on ")
        }
        return matches.count == 1 ? matches[0] : nil
    }

    public func save(_ app: RAVEDebugPairedApp) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(app)
        // Made with mode 600 before the token is written, then moved into place.
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.write(contentsOf: data)
        try handle.close()
        _ = try FileManager.default.replaceItemAt(url(app.hostID), withItemAt: temporary)
    }

    /// Forgets a pairing here. The app still lists this computer until it is
    /// removed there too; without the token nothing can use that entry.
    @discardableResult
    public func remove(_ hostID: String) -> Bool {
        (try? FileManager.default.removeItem(at: url(hostID))) != nil
    }

    /// This computer's id towards apps: random, made once, the same for every
    /// pairing so pairing again replaces the app's entry for it.
    public func computerID() throws -> String {
        let file = directory.appendingPathComponent("computer-id")
        if let existing = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let id = UUID().uuidString
        try Data(id.utf8).write(to: file, options: .atomic)
        return id
    }
}

// MARK: - Pairing

/// Pairs this computer with an app whose pairing screen is open: finds it
/// (Bonjour, or an address the person gave), runs the exchange, reports the
/// six digits for the person to compare with the device, and stores the
/// pairing once they tap Allow there.
@MainActor
public final class RAVEDebugPairing {
    public enum Event: Sendable, Equatable {
        case searching
        /// Compare with the device's screen; the person answers there.
        case code(String)
        case paired(RAVEDebugPairedApp)
        case failed(String)
    }

    private let apps: RAVEDebugPairedApps
    private let computerName: String
    private let host: String?
    private let port: UInt16?
    private let searchSeconds: Double

    /// - Parameters:
    ///   - host: the device's address or name, for a network where Bonjour
    ///     finds nothing (Tailscale). Nil: browse the local network.
    ///   - port: the pairing port there; nil is the namespace's.
    public init(apps: RAVEDebugPairedApps = RAVEDebugPairedApps(), computerName: String,
                host: String? = nil, port: UInt16? = nil, searchSeconds: Double = 60) {
        self.apps = apps
        self.computerName = computerName
        self.host = host
        self.port = port
        self.searchSeconds = searchSeconds
    }

    public func run(_ report: @escaping @MainActor (Event) -> Void) async -> RAVEDebugPairedApp? {
        let computerID: String
        do {
            computerID = try apps.computerID()
        } catch {
            report(.failed("Couldn't write to \(apps.directory.path): \(error.localizedDescription)"))
            return nil
        }
        let name = computerName
        let locator = RAVECompanionLocator(namespace: .debugAccess, deviceID: computerID, deviceName: { name })
        let client: RAVEPairingClient<RAVEDebugGrant>
        report(.searching)
        if let host {
            let link = RAVECompanionPairLink(.debugAccess, macID: "", name: host, port: port, addresses: [host])
            client = RAVEPairingClient(locator: locator, link: link, deviceName: name, requested: [.debug])
        } else {
            guard let found = await Self.browseForPairing(seconds: searchSeconds) else {
                report(.failed("No app is waiting to be paired on this network. Open the app's pairing screen on the device first. "
                               + "If it is open, macOS may be keeping this tool off the local network "
                               + "(System Settings > Privacy & Security > Local Network), or the device is on another network: "
                               + "pass --host with the device's address or tailnet name."))
                return nil
            }
            client = RAVEPairingClient(locator: locator, endpoint: found.endpoint, hostID: found.hostID,
                                       deviceName: name, requested: [.debug])
        }
        client.start()
        var shownCode: String?
        while true {
            switch client.state {
            case .confirming(let code):
                if shownCode != code {
                    shownCode = code
                    report(.code(RAVEPairingExchange.display(code)))
                }
            case .paired(let grant):
                let app = RAVEDebugPairedApp(
                    hostID: grant.macID, name: RAVEDebugAccessProtocol.displayName(grant.macName, fallback: "An app"),
                    computerID: computerID, token: grant.token, addresses: grant.addresses,
                    host: host ?? client.connectedAddress, lastPort: nil, pairedAt: RAVEDebugAccessProtocol.now())
                do {
                    try apps.save(app)
                } catch {
                    report(.failed("Paired, but the pairing couldn't be stored in \(apps.directory.path): \(error.localizedDescription). Remove this computer in the app and pair again."))
                    return nil
                }
                report(.paired(app))
                return app
            case .failed(let reason):
                report(.failed(Self.inOurWords(reason)))
                return nil
            case .idle, .waitingForHost:
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// RAVECompanion's messages call the approving side "the computer"; here
    /// that side is the device.
    static func inOurWords(_ reason: String) -> String {
        reason.replacingOccurrences(of: "The computer", with: "The device")
            .replacingOccurrences(of: "the computer", with: "the device")
            .replacingOccurrences(of: "that the app on the device is running", with: "that the app is open on its pairing screen")
    }

    struct Found: Sendable {
        let endpoint: NWEndpoint
        let hostID: String
    }

    /// The first app advertising its pairing listener, or nil after `seconds`.
    static func browseForPairing(seconds: Double) async -> Found? {
        await RAVEDebugBrowse.first(type: RAVEDebugAccessProtocol.pairServiceType, seconds: seconds) { result in
            guard case .bonjour(let txt) = result.metadata else { return nil }
            return Found(endpoint: result.endpoint, hostID: txt[RAVECompanionDiscovery.Key.hostID] ?? "")
        }
    }
}

enum RAVEDebugBrowse {
    /// Browses for `type` until `pick` accepts a result or `seconds` pass.
    static func first<T: Sendable>(type: String, seconds: Double,
                                   pick: @escaping @Sendable (NWBrowser.Result) -> T?) async -> T? {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: .tcp)
        let once = OSAllocatedUnfairLock(initialState: false)
        let value: T? = await withCheckedContinuation { continuation in
            let finish: @Sendable (T?) -> Void = { value in
                guard once.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(returning: value)
            }
            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    if let picked = pick(result) { return finish(picked) }
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { finish(nil) }
            }
            browser.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { finish(nil) }
        }
        browser.cancel()
        return value
    }
}

// MARK: - The proxy

/// Listens on 127.0.0.1 and carries each HTTP connection to the paired app
/// over TLS-PSK, proving which computer this is first. One request per
/// connection, as the app's server closes after each reply.
public final class RAVEDebugProxy: @unchecked Sendable {
    public struct Unreachable: Error, CustomStringConvertible {
        public let description: String
    }

    private let apps: RAVEDebugPairedApps?
    private let explicitHost: String?
    private let explicitPort: UInt16?
    private let browseSeconds: Double
    private let localToken: String
    private let queue = DispatchQueue(label: "com.illixion.rave.debug-access.proxy")
    private let state: OSAllocatedUnfairLock<State>
    private var listener: NWListener?
    private static let maxHeadBytes = 64 * 1024

    private struct State {
        var app: RAVEDebugPairedApp
        /// Where the app last answered, reused until it stops answering.
        var target: Target?
    }

    private enum Target: Sendable {
        case endpoint(NWEndpoint)
        case address(String, UInt16)
    }

    /// - Parameters:
    ///   - apps: where to write back the address and port that worked; nil keeps them in memory.
    ///   - host, port: where the app is, when the person knows better than the record.
    public init(app: RAVEDebugPairedApp, apps: RAVEDebugPairedApps? = RAVEDebugPairedApps(),
                host: String? = nil, port: UInt16? = nil, browseSeconds: Double = 1.5) throws {
        self.apps = apps
        self.explicitHost = host
        self.explicitPort = port
        self.browseSeconds = browseSeconds
        self.localToken = try RAVECompanionCredential.generateToken()
        self.state = OSAllocatedUnfairLock(initialState: State(app: app))
    }

    /// Starts listening. The port is any free one; the token is what a local
    /// client sends as `Authorization: Bearer`.
    public func start() async throws -> (port: UInt16, token: String) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] local in
            guard let self else { return local.cancel() }
            local.start(queue: self.queue)
            Task { await self.serve(local) }
        }
        let once = OSAllocatedUnfairLock(initialState: false)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                let outcome: Result<UInt16, any Error>?
                switch state {
                case .ready: outcome = .success(listener.port?.rawValue ?? 0)
                case .failed(let error): outcome = .failure(error)
                case .cancelled: outcome = .failure(CancellationError())
                default: outcome = nil
                }
                guard let outcome, once.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(with: outcome)
            }
            listener.start(queue: queue)
        }
        return (port, localToken)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ local: NWConnection) async {
        defer { local.cancel() }
        guard let head = await readHead(local) else { return }
        guard Self.authorized(head, token: localToken) else {
            return await reply(local, status: 401, code: "unauthenticated",
                               message: "this proxy wants its own bearer token",
                               hint: "use the token `rave-debug proxy` printed when it started; debugtrace-mcp does this for you")
        }
        let remote: NWConnection
        do {
            remote = try await connect()
        } catch {
            return await reply(local, status: 502, code: "unavailable", message: String(describing: error),
                               hint: "on the device, check that the app is open and that Allow debugging from a computer is on; "
                                   + "if the device is on another network, give its address or tailnet name with --host")
        }
        defer { remote.cancel() }
        guard await RAVEDebugIO.send(head, on: remote) else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await Self.pipe(from: local, to: remote) }
            group.addTask { await Self.pipe(from: remote, to: local) }
            // Either side ending ends the request.
            await group.next()
            local.cancel()
            remote.cancel()
        }
    }

    /// Everything up to the end of the header block, plus whatever of the body
    /// arrived with it. Nil for a client that sent no complete header.
    private func readHead(_ connection: NWConnection) async -> Data? {
        var buffer = Data()
        let end = Data("\r\n\r\n".utf8)
        while buffer.range(of: end) == nil {
            guard buffer.count <= Self.maxHeadBytes else { return nil }
            let (data, ended): (Data?, Bool) = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, isComplete, error in
                    continuation.resume(returning: (data, isComplete || error != nil))
                }
            }
            if let data { buffer.append(data) }
            if ended, buffer.range(of: end) == nil { return nil }
        }
        return buffer
    }

    static func authorized(_ head: Data, token: String) -> Bool {
        guard let end = head.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let lines = String(decoding: head[head.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n").dropFirst()
        for line in lines {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "authorization" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard value.lowercased().hasPrefix("bearer ") else { return false }
            let presented = String(value.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
            return RAVEDebugAccessProtocol.constantTimeEqual(presented, token)
        }
        return false
    }

    private func reply(_ connection: NWConnection, status: Int, code: String, message: String, hint: String) async {
        let body = (try? JSONSerialization.data(withJSONObject: [
            "ok": false, "error": ["code": code, "message": message, "hint": hint],
        ])) ?? Data()
        let reason = status == 401 ? "Unauthorized" : "Bad Gateway"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        _ = await RAVEDebugIO.send(Data(head.utf8) + body, on: connection)
    }

    private static func pipe(from source: NWConnection, to sink: NWConnection) async {
        while true {
            let (data, ended): (Data?, Bool) = await withCheckedContinuation { continuation in
                source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    continuation.resume(returning: (data, isComplete || error != nil))
                }
            }
            if let data, !data.isEmpty, !(await RAVEDebugIO.send(data, on: sink)) { return }
            if ended { return }
        }
    }

    // MARK: Reaching the app

    /// A connection to the app, identified. Tries where it last answered,
    /// then its Bonjour record, then the addresses on record.
    private func connect() async throws -> NWConnection {
        let (app, cached) = state.withLock { ($0.app, $0.target) }
        if let cached, let connection = await open(cached, app: app) { return connection }
        state.withLock { $0.target = nil }

        let token = app.token
        if explicitHost == nil,
           let endpoint: NWEndpoint = await RAVEDebugBrowse.first(type: RAVEDebugAccessProtocol.serviceType, seconds: browseSeconds, pick: { result in
               guard case .bonjour(let txt) = result.metadata,
                     RAVEDebugAccessProtocol.matches(txt: txt.dictionary, token: token) else { return nil }
               return result.endpoint
           }), let connection = await open(.endpoint(endpoint), app: app) {
            state.withLock { $0.target = .endpoint(endpoint) }
            return connection
        }

        var hosts: [String] = []
        for host in [explicitHost, app.host].compactMap({ $0 }) + app.addresses where !hosts.contains(host) { hosts.append(host) }
        var ports: [UInt16] = []
        let first = RAVEDebugAccessProtocol.ports.lowerBound
        for port in [explicitPort, app.lastPort, first, first + 1, first + 2].compactMap({ $0 }) where !ports.contains(port) { ports.append(port) }
        for host in hosts {
            for port in ports {
                guard let connection = await open(.address(host, port), app: app) else { continue }
                var changed = app
                changed.host = host
                changed.lastPort = port
                let updated = changed
                state.withLock { $0.app = updated; $0.target = .address(host, port) }
                if updated != app { try? apps?.save(updated) }
                return connection
            }
        }
        throw Unreachable(description: "\(app.name) did not answer"
            + (hosts.isEmpty ? "" : " at \(hosts.joined(separator: ", "))"))
    }

    /// TLS with this pairing's key, then the identify proof. Nil when nothing
    /// answers there, or what answers is not this app.
    private func open(_ target: Target, app: RAVEDebugPairedApp) async -> NWConnection? {
        let credential = RAVECompanionCredential(token: app.token, deviceID: app.computerID)
        let parameters = RAVEDebugAccessProtocol.channel.tcpParameters(credentials: [credential], connectionTimeout: 4)
        let connection: NWConnection
        switch target {
        case .endpoint(let endpoint):
            connection = NWConnection(to: endpoint, using: parameters)
        case .address(let host, let port):
            guard let port = NWEndpoint.Port(rawValue: port) else { return nil }
            connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        }
        let once = OSAllocatedUnfairLock(initialState: false)
        let ready: Bool = await withCheckedContinuation { continuation in
            let finish: @Sendable (Bool) -> Void = { value in
                guard once.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                // `.waiting` is a host that is not there right now: don't sit on it.
                case .failed, .cancelled, .waiting: finish(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 6) { finish(false) }
        }
        guard ready,
              let identify = RAVECompanionIdentify.make(.debugAccess, credential: credential,
                                                        exporterLabel: RAVEDebugAccessProtocol.exporterLabel, connection: connection),
              await RAVEDebugIO.send(RAVEDebugAccessProtocol.frame(identify), on: connection) else {
            connection.cancel()
            return nil
        }
        return connection
    }
}
#endif
