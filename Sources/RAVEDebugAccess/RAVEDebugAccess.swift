/*
 RAVEDebugAccess - the app's side

 Holds the computers the person paired, runs a pairing while the app's
 pairing screen is open, and gives DebugTrace's server the listener those
 computers connect to (`transport`).

 The app owns the screens: it shows `pairing` (the six digits to compare),
 calls `answer` with what the person tapped, and lists `computers` with
 Remove. It also owns when the server runs; this type only supplies the
 transport and says when its keys changed (`onChange`).
 */

import DebugLog
import DebugTraceServer
import Foundation
import Network
import Observation
import os
import RAVECompanion

@MainActor
@Observable
public final class RAVEDebugAccess {
    public enum Pairing: Equatable, Sendable {
        case idle
        /// The pairing screen is open: a computer can start.
        case waiting
        /// A computer started. Show `code` for the person to compare with the
        /// computer's screen, then call `answer`.
        case confirming(code: String, computer: String)
        case paired(computer: String)
        case failed(String)
    }

    /// The computers that may connect, oldest pairing first.
    public private(set) var computers: [RAVEDebugComputer]
    public private(set) var pairing: Pairing = .idle
    /// The port the pairing listener holds while the pairing screen is open,
    /// for a computer that is told the address instead of finding it.
    public private(set) var pairingPort: UInt16?

    /// Called after a computer is paired or removed. The paired listener's
    /// keys are fixed when it is made, so a running server reloads its
    /// transports here (`DebugTraceServer.shared?.reloadTransports()`).
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    /// This install's id towards computers: random, and tied to nothing else.
    public let hostID: String
    private let hostName: @MainActor () -> String
    private let storage: any RAVEDebugAccessStorage
    private let preferredPairPort: UInt16
    private let keyring = RAVECompanionKeyring<RAVEDebugGrant>(.debugAccess)
    /// Read by the transport's check from the network queue.
    private let names = OSAllocatedUnfairLock(initialState: [String: String]())
    private let log = DebugLogger(subsystem: "com.illixion.rave", category: "DebugAccess")

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var server: RAVEPairingServer<RAVEDebugGrant>?
    @ObservationIgnored private var pendingAnswer: CheckedContinuation<RAVEPairingServer<RAVEDebugGrant>.Decision, Never>?
    @ObservationIgnored private var watch: Task<Void, Never>?
    private let queue = DispatchQueue(label: "com.illixion.rave.debug-access.pairing")

    /// - Parameters:
    ///   - hostName: what a computer shows for this app while pairing and in
    ///     its list, e.g. "Apparition on Apple Vision Pro".
    ///   - storage: where the paired computers are kept; `RAVEDebugKeychainStorage` in an app.
    ///   - hostIDKey: the `UserDefaults` key of this install's id.
    ///   - pairPort: the pairing listener's port; nil is the namespace's. If
    ///     it is taken, any free port is used and Bonjour still finds it.
    public init(hostName: @escaping @MainActor () -> String, storage: any RAVEDebugAccessStorage,
                hostIDKey: String = "RAVEDebugAccess.hostID", pairPort: UInt16? = nil) {
        self.hostName = hostName
        self.storage = storage
        self.hostID = RAVECompanionLocator.persistentDeviceID(key: hostIDKey)
        self.preferredPairPort = pairPort ?? RAVECompanionNamespace.debugAccess.defaultPairPort
        self.computers = RAVEDebugComputerList.decode(storage.load())
        publish()
    }

    // MARK: The paired listener

    /// The listener paired computers connect to: TLS 1.2 with one pre-shared
    /// key per computer, then a proof of which computer it is. Give it to
    /// `DebugTraceServer.Configuration.transports`. A computer it lets in is
    /// already allowed debug access: the person compared a code and tapped
    /// Allow when they paired it.
    public var transport: DebugTraceServer.Transport {
        let keyring = keyring
        let names = names
        return DebugTraceServer.Transport(
            name: "paired",
            ports: RAVEDebugAccessProtocol.ports,
            parameters: {
                let parameters = RAVEDebugAccessProtocol.channel.tcpParameters(credentials: keyring.credentials)
                parameters.prohibitedInterfaceTypes = [.cellular]
                return parameters
            },
            service: {
                let nonce = RAVEDebugAccessProtocol.randomNonce()
                let record = RAVEDebugAccessProtocol.txtRecord(tokens: keyring.credentials.map(\.token), nonce: nonce)
                return NWListener.Service(name: "ravedebug-\(nonce.prefix(8))", type: RAVEDebugAccessProtocol.serviceType,
                                          txtRecord: NWTXTRecord(record))
            },
            authenticate: { connection in
                guard let header = await RAVEDebugIO.read(connection, 4) else { return nil }
                let length = header.enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
                guard length > 0, length <= RAVEDebugAccessProtocol.maxIdentifyBytes,
                      let body = await RAVEDebugIO.read(connection, length),
                      let identify = RAVECompanionIdentify.decode(body),
                      let binding = RAVECompanionIdentify.binding(connection, exporterLabel: RAVEDebugAccessProtocol.exporterLabel),
                      let entry = keyring.verify(identify, binding: binding),
                      entry.grants.contains(.debug), let id = entry.credential.deviceID else { return nil }
                let name = names.withLock { $0[id] } ?? "A paired computer"
                return DebugTraceServer.Client(id: id, name: name, approved: true)
            })
    }

    /// Pushes `computers` to what the listener reads.
    private func publish() {
        keyring.replace(computers.map {
            .init(credential: RAVECompanionCredential(token: $0.token, deviceID: $0.id), grants: [.debug])
        })
        let byID = Dictionary(computers.map { ($0.id, $0.name) }, uniquingKeysWith: { _, last in last })
        names.withLock { $0 = byID }
    }

    private func store() -> Bool {
        do {
            try storage.save(RAVEDebugComputerList.encode(computers))
            return true
        } catch {
            log.error("could not save the paired computers: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: Removing

    /// Takes one computer's access away. Its token is the only thing it had.
    public func remove(_ id: String) {
        guard computers.contains(where: { $0.id == id }) else { return }
        computers.removeAll { $0.id == id }
        _ = store()
        publish()
        log.info("removed a paired computer")
        onChange?()
    }

    public func removeAll() {
        guard !computers.isEmpty else { return }
        computers = []
        _ = store()
        publish()
        log.info("removed every paired computer")
        onChange?()
    }

    // MARK: Pairing

    /// Opens the pairing listener and advertises it. Call when the app's
    /// pairing screen appears; `endPairing` when it goes away. While it is
    /// open, a computer on the network can start a pairing, which the person
    /// then sees as six digits to compare: nothing is granted without their
    /// answer.
    public func beginPairing() {
        guard listener == nil else { return }
        pairing = .waiting
        listen(on: preferredPairPort, nonce: RAVEDebugAccessProtocol.randomNonce())
    }

    /// The namespace's fixed port, so a computer told only an address can dial
    /// it; any free port when that one is taken (another app's pairing screen),
    /// which Bonjour still finds.
    private func listen(on port: UInt16, nonce: String) {
        let unavailable = "Couldn't listen for a computer. Check that this app is allowed on the local network."
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.prohibitedInterfaceTypes = [.cellular]
        guard let listener = try? NWListener(using: parameters, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port) ?? .any) else {
            if port != 0 { listen(on: 0, nonce: nonce) } else { pairing = .failed(unavailable) }
            return
        }
        // The record says only that some app is waiting to be paired, and only
        // while the pairing screen is open.
        listener.service = NWListener.Service(
            name: "ravedebug-pair-\(nonce.prefix(8))", type: RAVEDebugAccessProtocol.pairServiceType,
            txtRecord: NWTXTRecord([RAVECompanionDiscovery.Key.hostID: hostID]))
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self else { return connection.cancel() }
                self.accept(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor [weak self] in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.pairingPort = listener.port?.rawValue
                case .failed(let error):
                    self.log.error("pairing listener failed: \(error.localizedDescription, privacy: .public)")
                    listener.cancel()
                    self.listener = nil
                    if port != 0 { self.listen(on: 0, nonce: nonce) } else { self.pairing = .failed(unavailable) }
                default:
                    break
                }
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// Closes the pairing listener and abandons a pairing in progress.
    public func endPairing() {
        listener?.cancel()
        listener = nil
        pairingPort = nil
        server?.cancel()
        server = nil
        resolve(.abandon)
        pairing = .idle
    }

    /// The person's answer to the code on screen.
    public func answer(_ allow: Bool) {
        resolve(allow ? .pair([.debug]) : .decline)
    }

    private func resolve(_ decision: RAVEPairingServer<RAVEDebugGrant>.Decision) {
        watch?.cancel()
        watch = nil
        pendingAnswer?.resume(returning: decision)
        pendingAnswer = nil
    }

    private func accept(_ connection: NWConnection) {
        // One pairing at a time: a second computer waits for the first to finish.
        guard server == nil, listener != nil else { return connection.cancel() }
        let context = RAVEPairingServer<RAVEDebugGrant>.Context(
            namespace: .debugAccess, deviceID: nil, deviceName: "A computer",
            hostID: hostID, hostName: hostName(), defaultGrants: [.debug],
            addresses: { RAVEDebugAccess.localAddresses() },
            enroll: { [weak self] id, name, grants, _ in
                guard let self, grants.contains(.debug) else { return nil }
                return self.enroll(id: id, name: name)
            })
        let server = RAVEPairingServer<RAVEDebugGrant>(context: context)
        server.approve = { [weak self] request in
            guard let self else { return .abandon }
            return await self.ask(request)
        }
        server.onApprovalCancelled = { [weak self] in self?.resolve(.abandon) }
        server.onFinish = { [weak self] outcome, name in
            Task { @MainActor [weak self] in self?.finished(outcome, name: name) }
        }
        self.server = server
        server.start(accepting: connection)
    }

    private func ask(_ request: RAVEPairingServer<RAVEDebugGrant>.ApprovalRequest) async -> RAVEPairingServer<RAVEDebugGrant>.Decision {
        let name = RAVEDebugAccessProtocol.displayName(request.deviceName, fallback: "A computer")
        pairing = .confirming(code: RAVEPairingExchange.display(request.code), computer: name)
        return await withCheckedContinuation { continuation in
            pendingAnswer = continuation
            // The computer hung up, or the exchange ran out of time: stop asking.
            watch = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    if request.isPeerLost() || ContinuousClock.now >= request.deadline {
                        self?.resolve(.abandon)
                        return
                    }
                }
            }
        }
    }

    /// Mints the computer's token and keeps it. Pairing the same computer
    /// again replaces its entry, so its old token stops working.
    private func enroll(id: String, name: String) -> String? {
        guard let token = try? RAVECompanionCredential.generateToken() else { return nil }
        let computer = RAVEDebugComputer(id: id, name: RAVEDebugAccessProtocol.displayName(name, fallback: "A computer"),
                                         pairedAt: RAVEDebugAccessProtocol.now(), token: token)
        let previous = computers
        computers.removeAll { $0.id == id }
        computers.append(computer)
        guard store() else {
            computers = previous
            return nil
        }
        publish()
        onChange?()
        return token
    }

    private func finished(_ outcome: RAVEPairingServer<RAVEDebugGrant>.Outcome, name: String) {
        server = nil
        resolve(.abandon)
        // The pairing screen may have closed meanwhile.
        guard listener != nil else { return }
        let computer = RAVEDebugAccessProtocol.displayName(name, fallback: "A computer")
        switch outcome {
        case .paired:
            log.info("paired a computer")
            pairing = .paired(computer: computer)
        case .declined, .silenced:
            pairing = .waiting
        case .incompatible:
            pairing = .failed("That computer's pairing tool is a different version. Update both and try again.")
        case .abandoned:
            // A computer that connected and left, or timed out, leaves the screen as it was.
            if case .confirming = pairing { pairing = .failed("The computer stopped before the pairing finished. Start it again there.") }
        }
    }

    /// This device's addresses for the computer to remember, wired and Wi-Fi
    /// first. Loopback and link-local ones are left out.
    public nonisolated static func localAddresses() -> [String] {
        var results: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return results }
        defer { freeifaddrs(list) }
        var pointer = list
        while let entry = pointer {
            let interface = entry.pointee
            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
               interface.ifa_flags & UInt32(IFF_UP) != 0, interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if !text.hasPrefix("169.254.") { results.append(text) }
                }
            }
            pointer = interface.ifa_next
        }
        return results
    }
}
