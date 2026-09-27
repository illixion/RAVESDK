/*
 RAVEDeviceSetup - hand one app's configuration, secrets included, to the
 same app on another device by showing a QR code

 Built for an Apple TV, which can't receive AirDrop, has no Files app and
 makes typing an API key with a Siri Remote miserable; nothing in it is
 tvOS-specific. The app on each end is the same app, over the local network:

 1. The receiving device makes a fresh Curve25519 key pair, advertises a
    Bonjour service under a random instance name, and shows a QR code of
    `<scheme>://setup?v=1&s=<instance>&k=<public key>` (`RAVESetupReceiver`,
    `RAVESetupQRCodeView`).
 2. The sender gets that link without camera or photo-library permission:
    the system Camera opens the app's own URL scheme straight into the app
    (iPhone/iPad), and a photo of the code can be picked with the
    out-of-process photo picker and decoded with Vision on every platform
    (`RAVESetupScanPhotoButton`).
 3. The sender seals its payload to the receiver's public key with HPKE
    (RFC 9180: X25519, HKDF-SHA256, ChaCha20-Poly1305) and connects directly
    to the Bonjour instance the code names (`RAVESetupSender`). The receiver
    opens it and replies under a key both sides export from the same HPKE
    context.

 The public key appears only in the QR code, never in the Bonjour record, so
 only someone who saw the screen can produce a payload the receiver accepts.
 Every setup screen's key pair is new and is discarded when it closes.

 The payload type is the app's: any `Codable`.

 Each app lists its `bonjourType` under `NSBonjourServices` in Info.plist
 (and needs `NSLocalNetworkUsageDescription`); without it the receiver can't
 advertise and the sender can't resolve.
 */

import CryptoKit
import Foundation

/// Which app's setup this is: its URL scheme and Bonjour service type.
public struct RAVESetupService: Sendable, Hashable {
    /// The app's registered URL scheme, e.g. `hypnos`.
    public let urlScheme: String
    /// e.g. `_hypnos-setup._tcp`.
    public let bonjourType: String

    public init(urlScheme: String, bonjourType: String) {
        self.urlScheme = urlScheme.lowercased()
        self.bonjourType = bonjourType
    }
}

/// What a sender reads from the receiver's QR code.
public struct RAVESetupCode: Identifiable, Hashable, Sendable {
    public static let version = 1

    public let service: RAVESetupService
    /// The Bonjour instance name to connect to.
    public let instance: String
    /// The receiver's X25519 public key, raw.
    public let publicKey: Data

    public var id: String { instance }

    public init(service: RAVESetupService, instance: String, publicKey: Data) {
        self.service = service
        self.instance = instance
        self.publicKey = publicKey
    }

    /// Parses `<scheme>://setup?v=1&s=<instance>&k=<base64url key>`; nil for
    /// anything else, including another app's setup code.
    public init?(url: URL, service: RAVESetupService) {
        guard url.scheme?.lowercased() == service.urlScheme, url.host?.lowercased() == "setup",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.first(where: { $0.name == "v" })?.value == String(Self.version),
              let instance = items.first(where: { $0.name == "s" })?.value, !instance.isEmpty,
              let key = items.first(where: { $0.name == "k" })?.value.flatMap(Data.init(base64URLEncoded:)),
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: key)) != nil
        else { return nil }
        self.init(service: service, instance: instance, publicKey: key)
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = service.urlScheme
        components.host = "setup"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(Self.version)),
            URLQueryItem(name: "s", value: instance),
            URLQueryItem(name: "k", value: publicKey.base64URLEncodedString()),
        ]
        return components.url!
    }
}

public enum RAVESetupError: LocalizedError, Equatable {
    case badFrame
    case timedOut
    case closed
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .badFrame: "The other device sent something unexpected."
        case .timedOut: "The other device didn't answer. Make sure it still shows the setup code and both are on the same network."
        case .closed: "The connection closed before the transfer finished."
        case .rejected(let message): message
        }
    }
}

extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
