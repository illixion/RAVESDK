/*
 RAVECompanion - per-device credentials and channels

 Every pairing mints a token for that one device, and the host keeps which
 features ("grants") the user allowed it. Each channel derives its own TLS-PSK
 from the token with its own salt; the PSK identity names the device, so a
 listener can hold every enrolled device's key at once. Because
 Network.framework can't tell a server which PSK a connection used, each
 connection then identifies itself: the device id and an HMAC under its token
 over a TLS exporter value, so a device can neither claim another device's
 grants nor replay the proof on another connection.

 TLS 1.2 with `TLS_PSK_WITH_AES_128_GCM_SHA256`: Network.framework's
 boringssl silently discards an external PSK under TLS 1.3 ("Clearing PSK
 identity/data"), so every channel pins 1.2 (DTLS 1.2 over UDP) and this
 suite, which it honours by raw value.
 */

import CryptoKit
import Foundation
import Network
import Security

/// The secret a device presents to a host. `deviceID` is nil for a host's
/// older shared token (Longwave's, before per-device pairing), which used
/// fixed PSK identities.
public struct RAVECompanionCredential: Sendable, Equatable, Hashable {
    public let token: String
    public let deviceID: String?

    public init(token: String, deviceID: String?) {
        self.token = token
        self.deviceID = deviceID
    }

    public var isLegacy: Bool { deviceID == nil }

    /// `<base>` for a shared token, `<base>/<device id>` for a device token.
    public func pskIdentity(base: String) -> Data {
        Data((deviceID.map { "\(base)/\($0)" } ?? base).utf8)
    }

    /// 256-bit URL-safe token.
    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A connection's first message: who it is, bound to this TLS session.
public struct RAVECompanionIdentify: Codable, Sendable, Equatable {
    /// Nil: a shared token.
    public var deviceID: String?
    public var proof: Data

    public init(deviceID: String?, proof: Data) {
        self.deviceID = deviceID
        self.proof = proof
    }

    /// `exporterLabel` is the channel's own (`EXPORTER-<App>-<Channel>-Device-v1`),
    /// so a proof made for one channel is useless on another.
    public static func make(_ namespace: RAVECompanionNamespace, credential: RAVECompanionCredential,
                            exporterLabel: String, connection: NWConnection) -> RAVECompanionIdentify? {
        guard let binding = binding(connection, exporterLabel: exporterLabel) else { return nil }
        return RAVECompanionIdentify(deviceID: credential.deviceID,
                                     proof: proof(namespace, token: credential.token, binding: binding))
    }

    /// RFC 5705 keying material with an **empty** context — what
    /// `sec_protocol_metadata_create_secret` exports, and what a non-Apple
    /// peer must ask for (BouncyCastle: a zero-length array, not null).
    public static func binding(_ connection: NWConnection, exporterLabel label: String) -> Data? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        else { return nil }
        guard let secret = label.withCString({
            sec_protocol_metadata_create_secret(metadata.securityProtocolMetadata, label.utf8.count, $0, 32)
        }) else { return nil }
        return Data(secret as DispatchData)
    }

    public static func proof(_ namespace: RAVECompanionNamespace, token: String, binding: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: binding, using: proofKey(namespace, token)))
    }

    public static func validates(_ namespace: RAVECompanionNamespace, proof: Data, token: String,
                                 binding: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: binding, using: proofKey(namespace, token))
    }

    private static func proofKey(_ namespace: RAVECompanionNamespace, _ token: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(token.utf8)),
                               salt: namespace.proofSalt, info: Data(), outputByteCount: 32)
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public static func decode(_ data: Data) -> RAVECompanionIdentify? { try? JSONDecoder().decode(Self.self, from: data) }
}

/// The host's current set of enrolled devices, as its servers read it from
/// their own queues: a lock-protected snapshot rather than an actor.
public final class RAVECompanionKeyring<Grant: Hashable & Sendable>: @unchecked Sendable {
    public struct Entry: Sendable, Equatable {
        public let credential: RAVECompanionCredential
        public let grants: Set<Grant>

        public init(credential: RAVECompanionCredential, grants: Set<Grant>) {
            self.credential = credential
            self.grants = grants
        }
    }

    public let namespace: RAVECompanionNamespace
    private let lock = NSLock()
    private var entries: [Entry] = []

    public init(_ namespace: RAVECompanionNamespace, entries: [Entry] = []) {
        self.namespace = namespace
        self.entries = entries
    }

    public func replace(_ entries: [Entry]) {
        lock.lock(); defer { lock.unlock() }
        self.entries = entries
    }

    /// Every credential a listener should accept.
    public var credentials: [RAVECompanionCredential] {
        lock.lock(); defer { lock.unlock() }
        return entries.map(\.credential)
    }

    /// Enrolled devices holding a grant.
    public func entries(with grant: Grant) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.grants.contains(grant) }
    }

    public func entry(deviceID: String?) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.credential.deviceID == deviceID }
    }

    /// Checks a connection's identify message. Returns the entry it proves.
    public func verify(_ identify: RAVECompanionIdentify, binding: Data) -> Entry? {
        guard let entry = entry(deviceID: identify.deviceID),
              RAVECompanionIdentify.validates(namespace, proof: identify.proof, token: entry.credential.token,
                                              binding: binding) else { return nil }
        return entry
    }

    /// Whether this device (nil: the shared token) is still enrolled with the grant.
    public func allows(_ deviceID: String?, _ grant: Grant) -> Bool {
        entry(deviceID: deviceID)?.grants.contains(grant) == true
    }
}

/// One channel's TLS-PSK key schedule: its PSK identity base and HKDF salt,
/// which keep each channel's keys independent though all come from the token.
public struct RAVECompanionChannel: Sendable, Equatable {
    public var identityBase: String
    public var salt: Data
    public var info: Data

    public init(identityBase: String, salt: String, info: String = "psk") {
        self.identityBase = identityBase
        self.salt = Data(salt.utf8)
        self.info = Data(info.utf8)
    }

    /// `TLS_PSK_WITH_AES_128_GCM_SHA256`.
    public static let pskCiphersuite = tls_ciphersuite_t(rawValue: 0x00A8)!

    public func derive(token: String) -> DispatchData {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(token.utf8)),
                                         salt: salt, info: info, outputByteCount: 32)
        return key.withUnsafeBytes { DispatchData(bytes: $0) }
    }

    /// One PSK per credential (a client: its own; a server: every enrolled
    /// device's), pinned to (D)TLS 1.2 and the PSK suite.
    public func configure(_ options: sec_protocol_options_t, credentials: [RAVECompanionCredential], dtls: Bool = false) {
        for credential in credentials {
            let identity = credential.pskIdentity(base: identityBase)
            sec_protocol_options_add_pre_shared_key(
                options,
                derive(token: credential.token) as __DispatchData,
                identity.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
            )
        }
        let version: tls_protocol_version_t = dtls ? .DTLSv12 : .TLSv12
        sec_protocol_options_set_min_tls_protocol_version(options, version)
        sec_protocol_options_set_max_tls_protocol_version(options, version)
        sec_protocol_options_append_tls_ciphersuite(options, Self.pskCiphersuite)
    }

    /// TLS 1.2-PSK over TCP, Nagle off.
    public func tcpParameters(credentials: [RAVECompanionCredential], connectionTimeout: Int? = nil,
                              serviceClass: NWParameters.ServiceClass? = nil) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        configure(tls.securityProtocolOptions, credentials: credentials)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        if let connectionTimeout { tcp.connectionTimeout = connectionTimeout }
        let parameters = NWParameters(tls: tls, tcp: tcp)
        if let serviceClass { parameters.serviceClass = serviceClass }
        return parameters
    }

    /// DTLS 1.2-PSK over UDP.
    public func udpParameters(credentials: [RAVECompanionCredential],
                              serviceClass: NWParameters.ServiceClass? = nil) -> NWParameters {
        let dtls = NWProtocolTLS.Options()
        configure(dtls.securityProtocolOptions, credentials: credentials, dtls: true)
        let parameters = NWParameters(dtls: dtls, udp: NWProtocolUDP.Options())
        if let serviceClass { parameters.serviceClass = serviceClass }
        return parameters
    }
}

/// The address hint a host AirDrops (or copies) to a device that can't see it
/// over Bonjour: the host's id, name, every address it has, and the port its
/// direct pairing listener uses. **It carries no secret**: anyone could write
/// one, and it grants nothing. The device tries each address and runs the
/// normal six-digit pairing over the first that answers.
///
///   <scheme>://pair?mac=<id>&name=<name>&port=4859&addr=192.168.1.5&addr=100.64.0.3
public struct RAVECompanionPairLink: Equatable, Sendable {
    public static let action = "pair"

    public var namespace: RAVECompanionNamespace
    public var macID: String
    public var name: String
    public var port: UInt16
    public var addresses: [String]

    public init(_ namespace: RAVECompanionNamespace, macID: String, name: String, port: UInt16? = nil,
                addresses: [String]) {
        self.namespace = namespace
        self.macID = macID
        self.name = name
        self.port = port ?? namespace.defaultPairPort
        self.addresses = addresses
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = namespace.urlScheme
        components.host = Self.action
        components.queryItems = [
            URLQueryItem(name: "mac", value: macID),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "port", value: String(port)),
        ] + addresses.map { URLQueryItem(name: "addr", value: $0) }
        return components.url
    }

    public init?(_ namespace: RAVECompanionNamespace, url: URL) {
        guard url.scheme?.lowercased() == namespace.urlScheme, url.host?.lowercased() == Self.action,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let mac = items.first(where: { $0.name == "mac" })?.value, !mac.isEmpty, mac.count <= 64 else { return nil }
        let addresses = items.filter { $0.name == "addr" }.compactMap(\.value)
            .filter { !$0.isEmpty && $0.count < 64 }.prefix(12)
        guard !addresses.isEmpty else { return nil }
        self.namespace = namespace
        self.macID = mac
        self.name = String((items.first { $0.name == "name" }?.value ?? "Mac").prefix(80))
        self.port = items.first { $0.name == "port" }?.value.flatMap(UInt16.init) ?? namespace.defaultPairPort
        self.addresses = Array(addresses)
    }
}
