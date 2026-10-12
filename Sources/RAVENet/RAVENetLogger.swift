/*
 RAVENet - Logging seam

 The package must not reach into an app's logger, but both source
 implementations logged heavily and that logging is load-bearing when
 diagnosing sleep/wake socket failures. So: a narrow protocol the app adapts to
 its own `AppLogger`, with a `DebugLogger` default for standalone use.

 DebugTrace is Apple-only (os, CryptoKit, MetricKit), and RAVENet also builds
 on Linux for RoboFrame's Pi kiosk. There `RAVENetLogMessage` is a small
 stand-in with the same interpolation spellings, so every call site compiles
 unchanged, and the default sink writes to stderr with every value that is not
 `.public` withheld: a kiosk's journal is forwarded off the box, so it gets the
 same treatment as an exported trace. `RAVE_LOG_PRIVATE=1` in the environment
 shows `.private` values too, for debugging at the device (DebugTrace's
 development mode); `.sensitive` values are never shown. Debug lines are
 dropped unless `RAVE_LOG_DEBUG=1`, as the unified log doesn't keep them
 either: a socket's per-frame lines would otherwise fill the journal.
 */

import Foundation
#if canImport(DebugTrace)
import DebugTrace
#endif

/// Severity of a transport log line.
public enum RAVENetLogLevel: Int, Sendable, Comparable, CaseIterable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public static func < (lhs: RAVENetLogLevel, rhs: RAVENetLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Sink for transport diagnostics. Implement this to forward into the host
/// app's structured logger (`AppLogger.remoteViewer`, `AppLogger.connection`, …).
///
/// Messages carry per-value privacy: timings, counts, states and error codes
/// are public; server endpoints, error descriptions and close reasons are
/// not. A URL is logged without its query or credentials, because a token
/// often rides in the query (RoboFrame's and Home Assistant's did). Forward
/// the message as it is — don't flatten it to a String.
public protocol RAVENetLogger: Sendable {
    func log(_ level: RAVENetLogLevel, _ message: RAVENetLogMessage)
}

/// Discards everything. Useful in tests.
public struct RAVENetSilentLogger: RAVENetLogger {
    public init() {}
    public func log(_ level: RAVENetLogLevel, _ message: RAVENetLogMessage) {}
}

#if canImport(DebugTrace)

/// DebugTrace's message type, so an app's `RAVENetLogger` forwards it to its
/// own `DebugLogger` with each value's privacy intact.
public typealias RAVENetLogMessage = DebugLogMessage

/// Default sink writing to `DebugLogger` (the in-app console and the
/// unified log). Used when an app supplies none.
public struct RAVENetOSLogger: RAVENetLogger {
    private let logger: DebugLogger

    public init(subsystem: String = "pro.rave.net", category: String = "websocket") {
        self.logger = DebugLogger(subsystem: subsystem, category: category)
    }

    public func log(_ level: RAVENetLogLevel, _ message: RAVENetLogMessage) {
        switch level {
        case .debug: logger.debug(message)
        case .info: logger.info(message)
        case .warning: logger.warning(message)
        case .error: logger.error(message)
        }
    }
}

#else

/// How an interpolated value may be shown, spelled like DebugTrace's
/// `DebugLogPrivacy`. Only `.public` values (and, under `.auto`, numbers and
/// booleans) reach the rendered line.
public struct RAVENetLogPrivacy: Sendable, Equatable {
    public enum Mask: Sendable, Equatable {
        case none, hash
    }

    enum Level: Sendable, Equatable {
        case auto, `public`, `private`, sensitive
    }

    let level: Level
    let mask: Mask

    public static let auto = RAVENetLogPrivacy(level: .auto, mask: .none)
    public static let `public` = RAVENetLogPrivacy(level: .public, mask: .none)
    public static let `private` = RAVENetLogPrivacy(level: .private, mask: .none)
    public static let sensitive = RAVENetLogPrivacy(level: .sensitive, mask: .none)

    public static func auto(mask: Mask) -> RAVENetLogPrivacy { RAVENetLogPrivacy(level: .auto, mask: mask) }
    public static func `private`(mask: Mask) -> RAVENetLogPrivacy { RAVENetLogPrivacy(level: .private, mask: mask) }
    public static func sensitive(mask: Mask) -> RAVENetLogPrivacy { RAVENetLogPrivacy(level: .sensitive, mask: mask) }

    func isShown(scalar: Bool) -> Bool {
        switch level {
        case .public: true
        case .auto: scalar || Self.showsPrivate
        case .private: Self.showsPrivate
        case .sensitive: false
        }
    }

    static let showsPrivate = ProcessInfo.processInfo.environment["RAVE_LOG_PRIVATE"] == "1"
}

/// A log line whose non-public values are withheld when it is built. A hashed
/// value prints as `<hash:…>`, salted per launch, so one value can be followed
/// across lines without being revealed.
public struct RAVENetLogMessage: Sendable, ExpressibleByStringInterpolation, CustomStringConvertible {
    public let description: String

    public init(stringLiteral value: String) {
        description = value
    }

    public init(stringInterpolation: StringInterpolation) {
        description = stringInterpolation.text
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var text = ""

        public init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity + interpolationCount * 8)
        }

        public mutating func appendLiteral(_ literal: String) {
            text += literal
        }

        public mutating func appendInterpolation<T>(_ value: T, privacy: RAVENetLogPrivacy = .auto) {
            let scalar = value is any BinaryInteger || value is any BinaryFloatingPoint || value is Bool
            append(String(describing: value), privacy, scalar: scalar)
        }

        public mutating func appendInterpolation<T: BinaryInteger>(_ value: T, privacy: RAVENetLogPrivacy = .auto) {
            append(String(value), privacy, scalar: true)
        }

        public mutating func appendInterpolation(_ value: Bool, privacy: RAVENetLogPrivacy = .auto) {
            append(value ? "true" : "false", privacy, scalar: true)
        }

        public mutating func appendInterpolation(_ message: RAVENetLogMessage) {
            text += message.description
        }

        public mutating func appendInterpolation<T>(_ value: T?, privacy: RAVENetLogPrivacy = .auto) {
            guard let value else { return text += "nil" }
            appendInterpolation(value, privacy: privacy)
        }

        private mutating func append(_ rendered: String, _ privacy: RAVENetLogPrivacy, scalar: Bool) {
            if privacy.isShown(scalar: scalar) {
                text += rendered
            } else if privacy.mask == .hash, privacy.level != .sensitive {
                text += "<hash:\(Self.hash(rendered))>"
            } else {
                text += "<private>"
            }
        }

        private static let salt = UInt64.random(in: .min ... .max)

        /// FNV-1a over the salted bytes: a short tag that only needs to stay
        /// stable for one launch, not to resist attack.
        private static func hash(_ value: String) -> String {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325 ^ salt
            for byte in value.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
            }
            return String(hash & 0xffff_ffff, radix: 16)
        }
    }
}

/// Default sink: one line per message on stderr, which systemd puts in the
/// journal. Used when an app supplies none.
public struct RAVENetOSLogger: RAVENetLogger {
    private let prefix: String

    public init(subsystem: String = "pro.rave.net", category: String = "websocket") {
        self.prefix = "[\(subsystem):\(category)]"
    }

    static let minimumLevel: RAVENetLogLevel = ProcessInfo.processInfo.environment["RAVE_LOG_DEBUG"] == "1" ? .debug : .info

    public func log(_ level: RAVENetLogLevel, _ message: RAVENetLogMessage) {
        guard level >= Self.minimumLevel else { return }
        let label = switch level {
        case .debug: "debug"
        case .info: "info"
        case .warning: "warning"
        case .error: "error"
        }
        FileHandle.standardError.write(Data("\(prefix) \(label): \(message)\n".utf8))
    }
}

#endif
