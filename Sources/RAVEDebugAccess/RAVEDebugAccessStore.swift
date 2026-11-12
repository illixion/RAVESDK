/*
 RAVEDebugAccess - the app's list of paired computers

 Each pairing mints a token for that one computer. The list is the app's
 only copy, kept in the Keychain as this-device-only: it is not synced and
 does not travel in a backup to another device. Removing a computer removes
 its token, which is all that computer had.
 */

import Foundation
import Security

/// A computer the person paired with this app.
public struct RAVEDebugComputer: Codable, Sendable, Identifiable, Equatable {
    /// The computer's id in the pairing. Approvals are kept under it.
    public let id: String
    /// What the computer called itself when it paired, as the person saw it
    /// beside the code.
    public var name: String
    public let pairedAt: Date
    let token: String

    init(id: String, name: String, pairedAt: Date, token: String) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
        self.token = token
    }
}

/// Where the list is kept. The Keychain in an app; memory in tests.
public protocol RAVEDebugAccessStorage: Sendable {
    func load() -> Data?
    /// Nil removes it.
    func save(_ data: Data?) throws
}

/// A generic-password item, this device only, readable once the device has
/// been unlocked since boot (so a server set to run at every launch can start
/// from a background launch).
public struct RAVEDebugKeychainStorage: RAVEDebugAccessStorage {
    public let service: String
    public let account: String

    public init(service: String, account: String = "paired-computers") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    public func save(_ data: Data?) throws {
        SecItemDelete(query as CFDictionary)
        guard let data else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public struct KeychainError: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String { "the Keychain refused the paired computers (status \(status))" }
    }
}

/// For tests and previews.
public final class RAVEDebugMemoryStorage: RAVEDebugAccessStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    public init() {}

    public func load() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return data
    }

    public func save(_ data: Data?) throws {
        lock.lock(); defer { lock.unlock() }
        self.data = data
    }
}

enum RAVEDebugComputerList {
    static func decode(_ data: Data?) -> [RAVEDebugComputer] {
        guard let data else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RAVEDebugComputer].self, from: data)) ?? []
    }

    static func encode(_ computers: [RAVEDebugComputer]) throws -> Data? {
        guard !computers.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(computers)
    }
}
