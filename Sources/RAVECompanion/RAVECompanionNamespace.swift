/*
 RAVECompanion - pairing a device with a computer it works with

 A headset (or phone) pairs once with a companion computer by numeric
 comparison, gets a token minted for it alone, and from then on reaches that
 computer over TLS-PSK channels keyed from the token, each connection proving
 which device it is. The computer opens its ports only while a paired device
 knocks for them. Lifted from Longwave (its Mac and Windows Companions), then
 hardened as pairing v2: the numeric comparison binds both endpoint identities
 and all client-supplied enrollment fields. Older v1 peers fail closed and must
 be upgraded together. Swift and Windows interop vectors are pinned in
 `RAVECompanionTests`.

 An app picks a namespace: the Bonjour service types, the key-derivation
 labels and the link scheme it uses. Longwave's is `.longwave`; another app
 talking to Longwave's Companion uses `.longwave` too, and an app with its own
 companion (Convolution's Mac worker) uses its own, so the two never answer
 each other.
 */

import Foundation

public struct RAVECompanionNamespace: Sendable, Equatable, Hashable {
    /// Bonjour service stem: `_<stem>-mac._tcp`, `_<stem>-knock._tcp`,
    /// `_<stem>-pair._tcp`. Each must be declared in the app's
    /// `NSBonjourServices`.
    public var serviceStem: String
    /// Prefix of every key-derivation label (`<prefix>-Knock-v1`,
    /// `<prefix>-Pair-v2`, `<prefix>-Device-Proof-v1`).
    public var labelPrefix: String
    /// Scheme of the address link (`<scheme>://pair?…`).
    public var urlScheme: String
    /// The host's fixed direct-pairing port, dialled from an address link.
    public var defaultPairPort: UInt16
    /// The host app's name, for messages the user reads ("Check that … is
    /// running").
    public var hostAppName: String

    public init(serviceStem: String, labelPrefix: String, urlScheme: String, defaultPairPort: UInt16,
                hostAppName: String) {
        self.serviceStem = serviceStem
        self.labelPrefix = labelPrefix
        self.urlScheme = urlScheme
        self.defaultPairPort = defaultPairPort
        self.hostAppName = hostAppName
    }

    /// Longwave's Companion (Mac and Windows).
    public static let longwave = RAVECompanionNamespace(
        serviceStem: "longwave", labelPrefix: "Longwave", urlScheme: "longwave", defaultPairPort: 4859,
        hostAppName: "Longwave Companion"
    )

    /// The host's announcement: a bare record, no socket behind it.
    public var hostServiceType: String { "_\(serviceStem)-mac._tcp" }
    /// A device asking a host to open its ports, or to pair.
    public var knockServiceType: String { "_\(serviceStem)-knock._tcp" }
    /// The host's one-off listener for one pairing.
    public var pairServiceType: String { "_\(serviceStem)-pair._tcp" }

    var knockSalt: Data { Data("\(labelPrefix)-Knock-v1".utf8) }
    var pairInfo: Data { Data("\(labelPrefix)-Pair-v2".utf8) }
    var proofSalt: Data { Data("\(labelPrefix)-Device-Proof-v1".utf8) }
}
