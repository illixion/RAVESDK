//
//  RAVECertificateTrust.swift
//  RAVEBrowser
//
//  Certificates a tab may accept although the system does not trust them: a
//  router's or a NAS's self-signed one, which is most of what lives on a
//  LAN. Off unless a host sets `RAVEBrowserTab.certificateExceptions`, so
//  every tab that does not opt in fails such a load exactly as before.
//
//  **An exception is a pin, not a switch.** It names one `host:port` and the
//  SHA-256 of the one leaf certificate it was granted for. A certificate that
//  changes (or a different machine answering on that address) fails again and
//  is reported again, so what is accepted is "this device, as I saw it", not
//  "this address, whatever answers". Exceptions live in memory and are gone
//  when the process ends.
//

#if canImport(WebKit)
import CryptoKit
import Foundation

/// A server certificate the system did not trust, as a tab saw it.
public struct RAVECertificateProblem: Sendable, Equatable, Codable {
    public var host: String
    public var port: Int
    /// SHA-256 of the leaf certificate (DER), lowercase hex.
    public var fingerprint: String
    /// What the system's evaluation said, e.g. "A certificate chain processed, but terminated in a root
    /// certificate which is not trusted".
    public var reason: String

    public init(host: String, port: Int, fingerprint: String, reason: String) {
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
        self.reason = reason
    }

    /// `host:port`, lowercased: what an exception is keyed on.
    public var address: String { RAVECertificateExceptions.address(host: host, port: port) }

    /// SHA-256 of a certificate's DER bytes, lowercase hex.
    public static func fingerprint(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}

/// The certificates a host has accepted, by address and fingerprint.
@MainActor
public final class RAVECertificateExceptions {
    public private(set) var pins: [String: String] = [:]

    public init() {}

    nonisolated public static func address(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    /// Whether this exact certificate was accepted for this address.
    public func isTrusted(_ problem: RAVECertificateProblem) -> Bool {
        pins[problem.address] == problem.fingerprint
    }

    /// Accepts this certificate for this address, replacing any earlier pin
    /// for it.
    public func trust(_ problem: RAVECertificateProblem) {
        pins[problem.address] = problem.fingerprint
    }

    public func forgetAll() { pins = [:] }
}
#endif
