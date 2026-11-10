/*
 RAVECompanion - pairing, the device's side

 Knocks with a pairing request and finds the listener the host opens for it —
 or, from an address link, dials the host's direct pairing port on each
 address in turn — then runs `RAVEPairingExchange`, shows the code for the
 user to compare, and hands back the device's own token and what the user
 allowed it, once they approve on the host.
 */

import Foundation
import Network
import Observation

@MainActor
@Observable
public final class RAVEPairingClient<Grant: Codable & Hashable & Sendable & RawRepresentable> where Grant.RawValue == String {
    public typealias Message = RAVEPairingMessage<Grant>

    public enum State: Equatable {
        case idle
        case waitingForHost
        /// The six digits to compare with the host's screen.
        case confirming(code: String)
        case paired(RAVEPairingGrant)
        case failed(String)
    }

    public private(set) var state: State = .idle

    private enum Target {
        case nearby(RAVECompanionLocator.NearbyHost)
        case direct(RAVECompanionPairLink)
    }

    private let locator: RAVECompanionLocator
    private let target: Target
    private let requested: Set<Grant>
    private let sshPublicKey: String?
    /// The address the exchange ran over, for a direct pairing.
    public private(set) var connectedAddress: String?
    private var remainingAddresses: [String] = []
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var buffer = Data()
    private let exchange = RAVEPairingExchange()
    private var commitment = Data()
    private var agreement: RAVEPairingExchange.Agreement?
    private var timeout: Task<Void, Never>?
    private let deviceName: String

    private var namespace: RAVECompanionNamespace { locator.namespace }

    private var macID: String {
        switch target {
        case .nearby(let host): host.macID
        case .direct(let link): link.macID
        }
    }

    /// - Parameter requested: what to ask the host for; its dialog starts from
    ///   these and the user decides.
    /// - Parameter sshPublicKey: a public key line offered for the host to
    ///   install (Longwave: SSH login); added only if the user allows it.
    public init(locator: RAVECompanionLocator, host: RAVECompanionLocator.NearbyHost, deviceName: String,
                requested: Set<Grant>, sshPublicKey: String? = nil) {
        self.locator = locator
        self.target = .nearby(host)
        self.deviceName = deviceName
        self.requested = requested
        self.sshPublicKey = sshPublicKey
    }

    public init(locator: RAVECompanionLocator, link: RAVECompanionPairLink, deviceName: String,
                requested: Set<Grant>, sshPublicKey: String? = nil) {
        self.locator = locator
        self.target = .direct(link)
        self.deviceName = deviceName
        self.requested = requested
        self.sshPublicKey = sshPublicKey
    }

    public func start() {
        guard state == .idle else { return }
        state = .waitingForHost
        commitment = RAVEPairingExchange.commitment(
            namespace, publicKey: exchange.publicKey, nonce: exchange.nonce,
            deviceID: locator.deviceID, deviceName: deviceName,
            requested: requested.map(\.rawValue).sorted(), sshPublicKey: sshPublicKey
        )
        let hostApp = namespace.hostAppName
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.fail("The computer didn't answer. Check that \(hostApp) is running and allowed on the local network.")
        }
        switch target {
        case .nearby:
            startNearby()
        case .direct(let link):
            remainingAddresses = link.addresses
            dialNext(port: link.port)
        }
    }

    /// Tries the link's addresses one at a time; the first that answers runs
    /// the exchange.
    private func dialNext(port: UInt16) {
        guard !remainingAddresses.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else {
            return fail("None of the computer's addresses answered. Check that \(namespace.hostAppName) is running there and that the link is less than ten minutes old.")
        }
        let address = remainingAddresses.removeFirst()
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 3
        let connection = NWConnection(host: NWEndpoint.Host(address), port: nwPort, using: NWParameters(tls: nil, tcp: tcp))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.connection === connection else { return }
                switch state {
                case .ready:
                    self.connectedAddress = address
                    self.sendCommit()
                    self.receive()
                case .failed, .waiting:
                    guard self.agreement == nil else {
                        return self.fail("Lost the computer while pairing.")
                    }
                    connection.cancel()
                    self.connection = nil
                    self.dialNext(port: port)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func sendCommit() {
        send(.commit(
            headsetID: locator.deviceID,
            headsetName: deviceName,
            commitment: commitment,
            requested: requested.sorted { $0.rawValue < $1.rawValue },
            sshPublicKey: sshPublicKey
        ))
    }

    private func startNearby() {
        locator.requestPairing(macID: macID)
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: namespace.pairServiceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in self?.found(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func cancel() {
        finish()
        if case .paired = state { return }
        state = .idle
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        guard connection == nil else { return }
        let deviceID = locator.deviceID
        let match = results.first { result in
            guard case .bonjour(let txt) = result.metadata else { return false }
            return txt[RAVECompanionDiscovery.Key.hostID] == macID
                && txt[RAVECompanionDiscovery.Key.deviceID] == deviceID
        }
        guard let match else { return }
        browser?.cancel()
        browser = nil
        let connection = NWConnection(to: match.endpoint, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.sendCommit()
                    self.receive()
                case .failed(let error):
                    self.fail("Lost the computer while pairing: \(error.localizedDescription)")
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data {
                    guard data.count <= RAVEPairingLimits.maximumInboxBytes - self.buffer.count else {
                        return self.fail("The computer sent an oversized reply.")
                    }
                    self.buffer.append(data)
                }
                do {
                    while let message = try Message.take(from: &self.buffer) {
                        self.handle(message)
                    }
                } catch {
                    return self.fail("The computer sent something unexpected.")
                }
                if isComplete || error != nil {
                    if case .paired = self.state { return }
                    self.fail("The computer closed the connection.")
                } else if self.connection != nil {
                    self.receive()
                }
            }
        }
    }

    private func handle(_ message: Message) {
        switch message {
        case .macHello(let macID, let macName, let publicKey, let nonce):
            // A typed address names no host id up front: the first answer is it.
            guard self.macID.isEmpty || macID == self.macID, let agreement = RAVEPairingExchange.agree(
                namespace, mine: exchange, theirPublicKey: publicKey, commitment: commitment,
                devicePublicKey: exchange.publicKey, deviceNonce: exchange.nonce,
                hostPublicKey: publicKey, hostNonce: nonce,
                hostID: macID, hostName: macName,
                deviceID: locator.deviceID, deviceName: deviceName,
                requested: requested.map(\.rawValue).sorted(), sshPublicKey: sshPublicKey
            ) else {
                return fail("The computer's reply didn't check out.")
            }
            self.agreement = agreement
            send(.reveal(publicKey: exchange.publicKey, nonce: exchange.nonce))
            state = .confirming(code: agreement.code)
        case .accept(let sealed):
            guard let agreement, let grant = try? RAVEPairingExchange.open(sealed, with: agreement.key) else {
                return fail("The computer's answer couldn't be opened.")
            }
            state = .paired(grant)
            finish()
        case .deny:
            fail("Pairing was declined on the computer.")
        case .commit, .reveal:
            fail("The computer sent something unexpected.")
        }
    }

    private func send(_ message: Message) {
        guard let connection, let frame = try? message.framed() else { return }
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func fail(_ reason: String) {
        guard state != .idle else { return }
        if case .paired = state { return }
        finish()
        state = .failed(reason)
    }

    private func finish() {
        timeout?.cancel()
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        if case .nearby = target { locator.endKnock(macID: macID) }
    }
}
