/*
 RAVEDebugAccess - debugging an app from a paired computer

 An app that ships outside the App Store can offer its debug server
 (DebugTrace) to the person who installed it: they pair a computer with the
 app once, by comparing six digits, and from then on that computer reaches
 the app's debug server over TLS with a key only the two of them hold. No
 bearer token crosses the network and nothing on it can read the traffic.

 It is RAVECompanion's pairing with the roles turned round. There the
 computer is the "host" that approves a device and mints its token; here the
 app on the device approves and mints, and the computer is the one that asks.
 RAVECompanion's wire names keep their Longwave meaning, so in this target:

   RAVECompanion says        here it is
   host / mac / macID        the app on the device (it approves and mints)
   device / headset          the computer (it asks, and later connects)

 The namespace is this target's own (Bonjour stems, key labels, port), so an
 app that offers debug access never answers Longwave or another companion.
 */

import CryptoKit
import Foundation
import Network
import RAVECompanion

/// What a paired computer may do. One thing: reach the debug server.
public enum RAVEDebugGrant: String, Codable, Hashable, Sendable {
    case debug
}

extension RAVECompanionNamespace {
    /// Debug access, shared by every app that offers it: a computer's helper
    /// finds any of them the same way.
    public static let debugAccess = RAVECompanionNamespace(
        serviceStem: "ravedebug", labelPrefix: "RAVEDebug", urlScheme: "ravedebug", defaultPairPort: 8712,
        hostAppName: "the app on the device"
    )
}

public enum RAVEDebugAccessProtocol {
    public static let namespace = RAVECompanionNamespace.debugAccess

    /// The paired listener's Bonjour type. Its record names nothing (see `txtRecord`).
    public static let serviceType = "_ravedebug._tcp"
    /// The pairing listener's, advertised only while the app's pairing screen is open.
    public static var pairServiceType: String { namespace.pairServiceType }
    /// What an app adds to `NSBonjourServices` to offer debug access.
    public static var bonjourServices: [String] { [serviceType, pairServiceType] }

    /// Where the paired listener binds: the first free port. Above DebugTrace's
    /// own plain-HTTP range (8642-8691), so neither takes the other's.
    public static let ports: ClosedRange<UInt16> = 8692...8711

    /// The TLS-PSK key schedule of the paired listener.
    public static let channel = RAVECompanionChannel(identityBase: "RAVEDebug/Server", salt: "RAVEDebug-Server-v1")
    static let exporterLabel = "EXPORTER-RAVEDebug-Server-Device-v1"
    static let maxIdentifyBytes = 1024
    /// A record carries at most this many tags, so the TXT entry stays under 255 bytes.
    static let maxAdvertisedTags = 12

    // MARK: The connection's first message

    /// A connection's opening message: four bytes of length (little-endian),
    /// then the identify proof as JSON. The HTTP request follows on the same
    /// connection.
    public static func frame(_ identify: RAVECompanionIdentify) -> Data {
        let body = identify.encoded()
        var length = UInt32(body.count).littleEndian
        return withUnsafeBytes(of: &length) { Data($0) } + body
    }

    // MARK: The advertisement

    /// base64url of the first 12 bytes of HMAC-SHA256 over the record's nonce,
    /// under a key derived from one paired computer's token. A record carries
    /// one per paired computer, so each can tell the app is its own, and
    /// nobody else learns which app, build or device is behind the record.
    /// Truncated: it identifies, it doesn't authenticate.
    public static func advertisementTag(token: String, nonce: String) -> String {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(token.utf8)),
                                         salt: Data("RAVEDebug-Advert-v1".utf8), info: Data(), outputByteCount: 32)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(nonce.utf8), using: key)
        return Data(mac.prefix(12)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// `v`, a nonce new per listener, and the tags, comma-separated.
    public static func txtRecord(tokens: [String], nonce: String) -> [String: String] {
        let tags = tokens.prefix(maxAdvertisedTags).map { advertisementTag(token: $0, nonce: nonce) }
        return ["v": "1", "n": nonce, "t": tags.joined(separator: ",")]
    }

    /// Whether a record is the app this token was paired with.
    public static func matches(txt: [String: String], token: String) -> Bool {
        guard txt["v"] == "1", let nonce = txt["n"], !nonce.isEmpty, nonce.count <= 64, let tags = txt["t"] else { return false }
        let mine = advertisementTag(token: token, nonce: nonce)
        // Every tag is compared, whichever matches.
        var found = false
        for tag in tags.split(separator: ",") where constantTimeEqual(String(tag), mine) { found = true }
        return found
    }

    /// Now, to the second: what the stored date format keeps, so a record reads back equal.
    static func now() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    static func randomNonce() -> String {
        (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<x.count { difference |= x[index] ^ y[index] }
        return difference == 0
    }

    /// A name as it is safe to show: no control characters, at most 80.
    static func displayName(_ raw: String, fallback: String) -> String {
        let cleaned = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(80))
    }
}

// MARK: - Reading and writing whole messages

enum RAVEDebugIO {
    /// Exactly `count` bytes, or nil when the connection ended first.
    static func read(_ connection: NWConnection, _ count: Int) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, _ in
                continuation.resume(returning: data?.count == count ? data : nil)
            }
        }
    }

    static func send(_ data: Data, on connection: NWConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }
}
