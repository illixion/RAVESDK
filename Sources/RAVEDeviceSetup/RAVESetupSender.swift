/*
 RAVEDeviceSetup - the sending end

 Seals the payload to the receiver's key and connects straight to the
 Bonjour instance the code names. No browsing, so nothing else on the
 network is enumerated. Returns once the receiver has confirmed, under the
 reply key only it could have derived.
 */

import CryptoKit
import Foundation
import Network

public enum RAVESetupSender {
    public static func send<Payload: Encodable & Sendable>(
        _ payload: Payload,
        to code: RAVESetupCode,
        timeout: Double = 20
    ) async throws {
        let recipientKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: code.publicKey)
        var sender = try HPKE.Sender(recipientKey: recipientKey, ciphersuite: RAVESetupChannel.ciphersuite,
                                     info: RAVESetupChannel.info(for: code))
        let envelope = RAVESetupChannel.Envelope(v: RAVESetupCode.version, enc: sender.encapsulatedKey,
                                                 box: try sender.seal(try JSONEncoder().encode(payload)))
        let replyKey = try sender.exportSecret(context: RAVESetupChannel.replyContext, outputByteCount: 32)
        let request = try JSONEncoder().encode(envelope)

        let connection = NWConnection(to: .service(name: code.instance, type: code.service.bonjourType,
                                                   domain: "local.", interface: nil),
                                      using: .tcp)
        defer { connection.cancel() }
        let reply = try await withSetupTimeout(timeout, cancelling: connection) {
            try await connection.ready()
            try await connection.sendFrame(request)
            let box = try await connection.receiveFrame()
            let plaintext = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: box), using: replyKey)
            return try JSONDecoder().decode(RAVESetupChannel.Reply.self, from: plaintext)
        }
        guard reply.ok else { throw RAVESetupError.rejected(reply.message) }
    }
}
