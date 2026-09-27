/*
 RAVEDeviceSetup - the receiving end

 Lives as long as the setup screen: `start()` makes the key pair and
 advertises the Bonjour service, `stop()` tears both down and forgets the
 key. A connection that can't produce a payload sealed to this key (anyone
 who didn't see the QR code) is dropped without a reply and the screen keeps
 waiting; the first one that can is handed to `onPayload` and ends the
 session.
 */

import CryptoKit
import Foundation
import Network
import Observation

@MainActor
@Observable
public final class RAVESetupReceiver<Payload: Decodable & Sendable> {
    public enum Status: Equatable, Sendable {
        case starting
        case waiting
        case received
        /// The local network is unavailable or denied; the string is the
        /// system's reason.
        case failed(String)
    }

    public private(set) var status: Status = .starting
    /// What the QR code shows; nil until `start()`.
    public private(set) var code: RAVESetupCode?

    private let service: RAVESetupService
    private let onPayload: @MainActor (Payload) -> Void
    private var listener: NWListener?
    private var privateKey: Curve25519.KeyAgreement.PrivateKey?

    public init(service: RAVESetupService, onPayload: @escaping @MainActor (Payload) -> Void) {
        self.service = service
        self.onPayload = onPayload
    }

    public func start() {
        guard listener == nil else { return }
        let key = Curve25519.KeyAgreement.PrivateKey()
        var random = SystemRandomNumberGenerator()
        let instance = "Setup " + String(format: "%08X", random.next() as UInt32)
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(name: instance, type: service.bonjourType)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
            privateKey = key
            code = RAVESetupCode(service: service, instance: instance, publicKey: key.publicKey.rawRepresentation)
            status = .starting
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        privateKey = nil
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            if status == .starting { status = .waiting }
        case .waiting(let error), .failed(let error):
            RAVESetupChannel.logger.error("Setup listener: \(error.localizedDescription, privacy: .public)")
            if status != .received { status = .failed(error.localizedDescription) }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard let privateKey, let code else {
            connection.cancel()
            return
        }
        connection.start(queue: .main)
        Task {
            do {
                let (payload, replyKey) = try await withSetupTimeout(15, cancelling: connection) {
                    let envelope = try JSONDecoder().decode(RAVESetupChannel.Envelope.self, from: try await connection.receiveFrame())
                    guard envelope.v == RAVESetupCode.version else { throw RAVESetupError.badFrame }
                    var recipient = try HPKE.Recipient(privateKey: privateKey, ciphersuite: RAVESetupChannel.ciphersuite,
                                                       info: RAVESetupChannel.info(for: code), encapsulatedKey: envelope.enc)
                    let plaintext = try recipient.open(envelope.box)
                    let replyKey = try recipient.exportSecret(context: RAVESetupChannel.replyContext, outputByteCount: 32)
                    return (try JSONDecoder().decode(Payload.self, from: plaintext), replyKey)
                }
                guard received(payload) else {
                    connection.cancel()
                    return
                }
                let reply = RAVESetupChannel.Reply(ok: true, message: "Received")
                let box = try ChaChaPoly.seal(try JSONEncoder().encode(reply), using: replyKey).combined
                try? await connection.sendFrame(box)
                connection.cancel()
            } catch {
                // Not sealed to this screen's key, or not a setup client at all.
                RAVESetupChannel.logger.notice("Dropped a setup connection: \(error.localizedDescription, privacy: .public)")
                connection.cancel()
            }
        }
    }

    /// False when a payload already ended this session.
    private func received(_ payload: Payload) -> Bool {
        guard listener != nil else { return false }
        stop()
        status = .received
        onPayload(payload)
        return true
    }
}
