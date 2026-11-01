/*
 RAVECompanion - finding a host and knocking for its ports

 Three Bonjour services carry it (see `RAVECompanionNamespace`):
 - the host's announcement, a record only, whose TXT carries its id, LAN
   addresses (wired first) and whether its ports are open right now;
 - a device's knock, advertised while it wants the host. A paired device's
   carries a tag only a holder of its token can make, rolling every minute;
   seeing a valid one, the host opens its ports. An unpaired device knocks
   with `pair=1` instead;
 - the host's pairing listener, up only while it answers one request.

 A knock can be copied or forged by anything on the LAN, and that is fine: it
 only decides whether a port is listening. Getting in still takes the token.
 */

import CryptoKit
import Foundation

public enum RAVECompanionDiscovery {
    /// TXT keys. Short, because a record travels in every mDNS answer.
    public enum Key {
        public static let version = "v"
        public static let hostID = "id"
        public static let addresses = "addr"
        public static let open = "open"
        public static let deviceID = "hs"
        public static let tag = "t"
        public static let pairRequest = "pair"
        public static let name = "n"
        /// "windows" on a Windows host's record; absent on a Mac's.
        public static let os = "os"
        /// The host's fixed pairing port. A host that lists it (Windows) is
        /// paired by dialling it rather than knocking for a listener.
        public static let pairPort = "pp"
    }

    public static let version = "1"

    /// How long a knock tag stays valid: its own minute and the one either
    /// side, so clock skew between the devices of up to a minute still works.
    public static let tagWindowMinutes: Int64 = 1

    public static func minute(of date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / 60).rounded(.down))
    }

    /// The knock tag a paired device advertises: HMAC of the host, the device
    /// and the minute under a key derived from the token. Truncated: it gates
    /// a listener, it isn't the authentication.
    public static func knockTag(_ namespace: RAVECompanionNamespace, token: String, hostID: String,
                                deviceID: String, minute: Int64) -> String {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(token.utf8)),
            salt: namespace.knockSalt,
            info: Data("knock".utf8),
            outputByteCount: 32
        )
        let message = Data("\(hostID)|\(deviceID)|\(minute)".utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return Data(mac.prefix(12)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func isValidKnock(_ namespace: RAVECompanionNamespace, tag: String, token: String, hostID: String,
                                    deviceID: String, now: Date = Date()) -> Bool {
        let current = minute(of: now)
        for offset in -tagWindowMinutes...tagWindowMinutes {
            let expected = knockTag(namespace, token: token, hostID: hostID, deviceID: deviceID,
                                    minute: current + offset)
            if constantTimeEqual(expected, tag) { return true }
        }
        return false
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<x.count { difference |= x[i] ^ y[i] }
        return difference == 0
    }
}
