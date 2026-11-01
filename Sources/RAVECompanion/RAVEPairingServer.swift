/*
 RAVECompanion - pairing, the host's side

 Answers one device's pairing request: a plain TCP listener, advertised for
 that device only, that runs `RAVEPairingExchange`, asks the app to show the
 six-digit code for the user to compare and approve, and on approval hands
 over a token minted for the device, sealed under the agreed key.

 The listener lives only as long as the one exchange, and is gone after two
 minutes whatever happens. The bytes are read on the network queue whatever
 the main actor is doing, so a device that hangs up while the approval is up
 is noticed then (`ApprovalRequest.isPeerLost`), and the app's prompt can
 close itself.
 */

import DebugLog
import Foundation
import Network
import os

@MainActor
public final class RAVEPairingServer<Grant: Codable & Hashable & Sendable & RawRepresentable> where Grant.RawValue == String {
    public typealias Message = RAVEPairingMessage<Grant>

    public struct Context {
        public let namespace: RAVECompanionNamespace
        /// Nil when the device dialled the host's direct pairing port (from an
        /// address link): its commit says who it is.
        public let deviceID: String?
        public let deviceName: String
        public let hostID: String
        public let hostName: String
        /// What the device asks for when its commit names nothing.
        public let defaultGrants: Set<Grant>
        /// The host's addresses for the grant, wired first.
        public let addresses: @MainActor () -> [String]
        /// Whether an offered public key line is one the app would install;
        /// one that isn't is dropped before the user sees it.
        public let acceptsPublicKey: @MainActor (String) -> Bool
        /// Called once the user approves: enrolls the device with the grants
        /// they ticked and returns its fresh token (nil if that failed).
        public let enroll: @MainActor (_ id: String, _ name: String, _ grants: Set<Grant>, _ sshPublicKey: String?) -> String?

        public init(namespace: RAVECompanionNamespace, deviceID: String?, deviceName: String, hostID: String,
                    hostName: String, defaultGrants: Set<Grant>, addresses: @escaping @MainActor () -> [String],
                    acceptsPublicKey: @escaping @MainActor (String) -> Bool = { _ in false },
                    enroll: @escaping @MainActor (String, String, Set<Grant>, String?) -> String?) {
            self.namespace = namespace
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.hostID = hostID
            self.hostName = hostName
            self.defaultGrants = defaultGrants
            self.addresses = addresses
            self.acceptsPublicKey = acceptsPublicKey
            self.enroll = enroll
        }
    }

    /// What the app shows the user.
    public struct ApprovalRequest: Sendable {
        public let code: String
        public let deviceName: String
        public let requested: Set<Grant>
        /// The public key line the device offered, already vetted by
        /// `Context.acceptsPublicKey`.
        public let sshPublicKey: String?
        /// The device went away: close the prompt and answer `.abandon`.
        /// Safe to poll from a modal loop's timer.
        public let isPeerLost: @Sendable () -> Bool
        /// The exchange's two-minute limit.
        public let deadline: ContinuousClock.Instant
    }

    public enum Decision: Sendable {
        case pair(Set<Grant>)
        case decline
        /// The user chose to stop being asked for a while.
        case silence
        case abandon
    }

    public enum Outcome: Sendable {
        case paired
        /// The user chose not to pair.
        case declined
        /// The user chose to stop being asked for a while.
        case silenced
        /// Timed out, abandoned or malformed — no answer from the user.
        case abandoned
    }

    /// Asks the user. Required before `start`.
    public var approve: (@MainActor (ApprovalRequest) async -> Decision)?
    /// The exchange ended while the approval was still up: close the prompt
    /// (Longwave: `NSApp.abortModal()`).
    public var onApprovalCancelled: (@MainActor () -> Void)?
    /// Fired once, when the exchange is over either way, with the name the
    /// device gave.
    public var onFinish: ((Outcome, String) -> Void)?

    private let context: Context
    private let log = RAVECompanionLog.pairing
    private let queue = DispatchQueue(label: "com.illixion.rave.companion.pairing")
    private var listener: NWListener?
    private var connection: NWConnection?
    private let exchange = RAVEPairingExchange()
    private var commitment: Data?
    private var deviceID: String?
    private var deviceName: String
    private var requested: Set<Grant>
    private var sshPublicKey: String?
    private var finished = false
    private var timeout: Task<Void, Never>?
    private var approving = false
    private nonisolated let lost = OSAllocatedUnfairLock(initialState: false)
    private nonisolated let inbox = OSAllocatedUnfairLock(initialState: Data())
    private var draining = false
    private let startedAt = ContinuousClock.now

    public init(context: Context) {
        self.context = context
        self.deviceID = context.deviceID
        self.deviceName = context.deviceName
        self.requested = context.defaultGrants
    }

    /// Runs the exchange on a connection the direct pairing listener accepted.
    public func start(accepting connection: NWConnection) {
        startTimeout()
        accept(connection)
    }

    /// Advertises a one-off pairing listener for `Context.deviceID`.
    public func start() throws {
        let deviceID = context.deviceID ?? ""
        let listener = try NWListener(using: .tcp)
        var txt = NWTXTRecord()
        txt[RAVECompanionDiscovery.Key.hostID] = context.hostID
        txt[RAVECompanionDiscovery.Key.deviceID] = deviceID
        listener.service = NWListener.Service(
            name: "\(context.namespace.labelPrefix) pairing \(deviceID.prefix(8))",
            type: context.namespace.pairServiceType,
            txtRecord: txt
        )
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { @MainActor [weak self] in
                    self?.log.error("Pairing listener failed: \(error.localizedDescription)")
                    self?.finish(.abandoned)
                }
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        startTimeout()
    }

    private func startTimeout() {
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.log.info("Pairing timed out")
            self?.finish(.abandoned)
        }
    }

    public func cancel() {
        finish(.abandoned)
    }

    private func accept(_ connection: NWConnection) {
        guard self.connection == nil, !finished else {
            connection.cancel()
            return
        }
        self.connection = connection
        // The record has done its job; nobody else should find it.
        listener?.cancel()
        listener = nil
        let lost = self.lost
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                lost.withLock { $0 = true }
                Task { @MainActor [weak self] in self?.finish(.abandoned) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        Self.receiveLoop(connection, inbox: inbox, lost: lost) { [weak self] in
            Task { @MainActor [weak self] in await self?.drain() }
        }
    }

    private nonisolated static func receiveLoop(
        _ connection: NWConnection,
        inbox: OSAllocatedUnfairLock<Data>,
        lost: OSAllocatedUnfairLock<Bool>,
        onData: @escaping @Sendable () -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, error in
            if let data { inbox.withLock { $0.append(data) } }
            let ended = isComplete || error != nil
            if ended { lost.withLock { $0 = true } }
            onData()
            if !ended { receiveLoop(connection, inbox: inbox, lost: lost, onData: onData) }
        }
    }

    private func drain() async {
        guard !draining, !finished else { return }
        draining = true
        defer { draining = false }
        while !finished {
            let message: Message?
            do {
                message = try inbox.withLock { try Message.take(from: &$0) }
            } catch {
                log.error("Malformed pairing message")
                return finish(.abandoned)
            }
            guard let message else { break }
            await handle(message)
        }
        if lost.withLock({ $0 }) { finish(.abandoned) }
    }

    private func handle(_ message: Message) async {
        switch message {
        case .commit(let deviceID, let deviceName, let commitment, let requested, let sshPublicKey):
            guard self.commitment == nil, !deviceID.isEmpty, deviceID.count <= 64,
                  context.deviceID == nil || deviceID == context.deviceID else { return finish(.abandoned) }
            self.deviceID = deviceID
            if context.deviceID == nil { self.deviceName = String(deviceName.prefix(80)) }
            if let requested { self.requested = Set(requested) }
            self.sshPublicKey = sshPublicKey.flatMap { context.acceptsPublicKey($0) ? $0 : nil }
            self.commitment = commitment
            send(.macHello(macID: context.hostID, macName: context.hostName,
                           publicKey: exchange.publicKey, nonce: exchange.nonce))
        case .reveal(let publicKey, let nonce):
            guard let commitment, let agreement = RAVEPairingExchange.agree(
                context.namespace, mine: exchange, theirPublicKey: publicKey, commitment: commitment,
                devicePublicKey: publicKey, deviceNonce: nonce,
                hostPublicKey: exchange.publicKey, hostNonce: exchange.nonce
            ) else {
                log.error("Pairing reveal didn't match its commitment")
                return finish(.abandoned)
            }
            guard let approve else {
                log.error("Pairing server has no approval handler")
                return finish(.abandoned)
            }
            let lost = self.lost
            approving = true
            let decision = await approve(ApprovalRequest(
                code: agreement.code, deviceName: deviceName, requested: requested, sshPublicKey: sshPublicKey,
                isPeerLost: { lost.withLock { $0 } }, deadline: startedAt + .seconds(120)
            ))
            approving = false
            guard !finished else { return }
            let outcome: Outcome
            var grants: Set<Grant> = []
            switch decision {
            case .pair(let ticked): outcome = lost.withLock({ $0 }) ? .abandoned : .paired; grants = ticked
            case .decline: outcome = .declined
            case .silence: outcome = .silenced
            case .abandon: outcome = .abandoned
            }
            guard outcome == .paired, let deviceID,
                  let token = context.enroll(deviceID, deviceName, grants, sshPublicKey) else {
                log.info("Pairing not approved")
                send(.deny) { [weak self] in self?.finish(outcome == .paired ? .abandoned : outcome) }
                return
            }
            let grant = RAVEPairingGrant(
                token: token, macID: context.hostID, macName: context.hostName,
                addresses: context.addresses(),
                grants: grants.map(\.rawValue).sorted()
            )
            do {
                let sealed = try RAVEPairingExchange.seal(grant, with: agreement.key)
                send(.accept(sealedGrant: sealed)) { [weak self] in
                    self?.log.info("Paired a device")
                    self?.finish(.paired)
                }
            } catch {
                finish(.abandoned)
            }
        case .macHello, .accept, .deny:
            finish(.abandoned)
        }
    }

    private func send(_ message: Message, then completion: (@MainActor () -> Void)? = nil) {
        guard let connection, let frame = try? message.framed() else { return }
        connection.send(content: frame, completion: .contentProcessed { _ in
            guard let completion else { return }
            Task { @MainActor in completion() }
        })
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        if approving { onApprovalCancelled?() }
        timeout?.cancel()
        listener?.cancel()
        listener = nil
        connection?.cancel()
        connection = nil
        onFinish?(outcome, deviceName)
    }
}
