/*
 RAVEDeviceSetup - wire format and connection plumbing shared by both ends

 Both directions: a 4-byte big-endian length, then the body. The request
 body is a JSON `Envelope`; the reply body is a ChaCha20-Poly1305 box
 (nonce ‖ ciphertext ‖ tag) of a JSON `Reply`.
 */

import CryptoKit
import Foundation
import Network
import os

enum RAVESetupChannel {
    static let ciphersuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    /// Largest frame either side accepts; setup payloads are small.
    static let maxFrame = 256 * 1024
    static let replyContext = Data("reply".utf8)
    static let logger = Logger(subsystem: "com.illixion.rave", category: "DeviceSetup")

    struct Envelope: Codable {
        var v: Int
        /// HPKE encapsulated key.
        var enc: Data
        /// HPKE ciphertext of the app's JSON payload.
        var box: Data
    }

    struct Reply: Codable {
        var ok: Bool
        var message: String
    }

    /// Binds the HPKE context to one app's one setup screen.
    static func info(for code: RAVESetupCode) -> Data {
        Data("rave-setup v\(RAVESetupCode.version) \(code.service.bonjourType) \(code.instance)".utf8)
    }
}

extension NWConnection {
    func sendFrame(_ body: Data) async throws {
        var length = UInt32(body.count).bigEndian
        let frame = Data(bytes: &length, count: 4) + body
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: frame, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func receiveFrame() async throws -> Data {
        let header = try await receiveExactly(4)
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length <= RAVESetupChannel.maxFrame else { throw RAVESetupError.badFrame }
        return try await receiveExactly(length)
    }

    private func receiveExactly(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: isComplete ? RAVESetupError.closed : RAVESetupError.badFrame)
                }
            }
        }
    }

    /// Starts the connection and waits until it's usable. Bonjour resolution
    /// and the local network prompt both happen before `.ready`; a connection
    /// stuck in `.waiting` is left to the caller's timeout.
    func ready() async throws {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stateUpdateHandler = { state in
                let result: Result<Void, Error>? = switch state {
                case .ready: .success(())
                case .failed(let error): .failure(error)
                case .cancelled: .failure(RAVESetupError.closed)
                default: nil
                }
                guard let result, resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(with: result)
            }
            start(queue: .global(qos: .userInitiated))
        }
    }
}

/// Runs `operation`, failing with `.timedOut` if it takes longer than
/// `seconds`. A pending receive doesn't notice task cancellation, so the timer
/// cancels `connection`, which is what ends it.
func withSetupTimeout<T: Sendable>(
    _ seconds: Double,
    cancelling connection: NWConnection,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let expired = OSAllocatedUnfairLock(initialState: false)
    do {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                expired.withLock { $0 = true }
                connection.cancel()
                throw RAVESetupError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    } catch {
        // The cancelled receive can fail before the timer's own error lands.
        if expired.withLock({ $0 }) { throw RAVESetupError.timedOut }
        throw error
    }
}
