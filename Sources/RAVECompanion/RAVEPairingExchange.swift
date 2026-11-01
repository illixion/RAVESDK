/*
 RAVECompanion - the pairing exchange

 Numeric comparison. The device commits to its key and nonce before it sees
 the host's and reveals them only after; both ends then show a six-digit code
 drawn from the whole transcript, and the user approves on the host only if
 the codes match. Something sitting between the two would have had to fix its
 keys on each side before learning what the other would contribute, so its two
 codes match by chance one time in a million. The agreed key then seals the
 grant (a token minted for this device alone, and what the user allowed it) on
 its way to the device.

 Messages are length-prefixed JSON on a plain TCP connection: everything that
 needs protecting is protected by the exchange. Field names are the wire
 format (`macID`, `headsetID`…) and stay as Longwave named them.
 */

import CryptoKit
import Foundation

/// What the host hands a device once the user has approved it.
public struct RAVEPairingGrant: Codable, Sendable, Equatable {
    public var token: String
    /// The host's id.
    public var macID: String
    public var macName: String
    /// LAN addresses, wired first, as a starting host for the connection.
    public var addresses: [String]
    /// Raw values of the grants the user allowed this device.
    public var grants: [String]?

    public init(token: String, macID: String, macName: String, addresses: [String], grants: [String]? = nil) {
        self.token = token
        self.macID = macID
        self.macName = macName
        self.addresses = addresses
        self.grants = grants
    }
}

public struct RAVEPairingExchange: Sendable {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey
    public let nonce: Data

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey = .init(),
                nonce: Data = RAVEPairingExchange.randomNonce()) {
        self.privateKey = privateKey
        self.nonce = nonce
    }

    public var publicKey: Data { privateKey.publicKey.rawRepresentation }

    public static func randomNonce() -> Data {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
    }

    /// The device's opening move: a hash binding its key and nonce.
    public static func commitment(publicKey: Data, nonce: Data) -> Data {
        Data(SHA256.hash(data: publicKey + nonce))
    }

    public struct Agreement: Sendable {
        /// Six digits, for both screens.
        public let code: String
        public let key: SymmetricKey
    }

    /// Runs on both ends once all four values are known. Returns nil when the
    /// revealed device values don't match the commitment, or a key is bad.
    public static func agree(
        _ namespace: RAVECompanionNamespace,
        mine: RAVEPairingExchange,
        theirPublicKey: Data,
        commitment: Data,
        devicePublicKey: Data, deviceNonce: Data,
        hostPublicKey: Data, hostNonce: Data
    ) -> Agreement? {
        guard Self.commitment(publicKey: devicePublicKey, nonce: deviceNonce) == commitment,
              let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirPublicKey),
              let shared = try? mine.privateKey.sharedSecretFromKeyAgreement(with: theirs) else {
            return nil
        }
        let transcript = Data(SHA256.hash(data: commitment + hostPublicKey + hostNonce + devicePublicKey + deviceNonce))
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: transcript, sharedInfo: namespace.pairInfo, outputByteCount: 32
        )
        let number = transcript.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        return Agreement(code: String(format: "%06u", number), key: key)
    }

    public static func seal(_ grant: RAVEPairingGrant, with key: SymmetricKey) throws -> Data {
        try ChaChaPoly.seal(JSONEncoder().encode(grant), using: key).combined
    }

    public static func open(_ sealed: Data, with key: SymmetricKey) throws -> RAVEPairingGrant {
        let box = try ChaChaPoly.SealedBox(combined: sealed)
        return try JSONDecoder().decode(RAVEPairingGrant.self, from: ChaChaPoly.open(box, using: key))
    }

    /// "123456" → "123 456".
    public static func display(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}

/// The messages of a pairing, in order: device `commit`, host `macHello`,
/// device `reveal`, host `accept` or `deny`. `Grant` is the app's own set of
/// features (a `String`-backed enum), which is how they travel.
public enum RAVEPairingMessage<Grant: Codable & Hashable & Sendable>: Codable, Sendable, Equatable {
    /// `requested`: the features the device asks for; the host's dialog
    /// starts from them and the user decides. `sshPublicKey`: a public key
    /// line the host may install if the user allows it; a public key, so it
    /// needs no sealing.
    case commit(headsetID: String, headsetName: String, commitment: Data, requested: [Grant]?, sshPublicKey: String? = nil)
    case macHello(macID: String, macName: String, publicKey: Data, nonce: Data)
    case reveal(publicKey: Data, nonce: Data)
    case accept(sealedGrant: Data)
    case deny

    public static var maxBytes: Int { 16 * 1024 }

    public func framed() throws -> Data {
        let body = try JSONEncoder().encode(self)
        var length = UInt32(body.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    /// Pulls one complete message off the front of `buffer`, if it holds one.
    public static func take(from buffer: inout Data) throws -> RAVEPairingMessage? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        guard length <= maxBytes else { throw CocoaError(.coderReadCorrupt) }
        guard buffer.count >= 4 + length else { return nil }
        let body = buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + 4 + length))
        buffer.removeFirst(4 + length)
        return try JSONDecoder().decode(RAVEPairingMessage.self, from: body)
    }
}
