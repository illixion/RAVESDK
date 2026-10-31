/*
 RAVENet - Logging seam

 The package must not reach into an app's logger, but both source
 implementations logged heavily and that logging is load-bearing when
 diagnosing sleep/wake socket failures. So: a narrow protocol the app adapts to
 its own `AppLogger`, with a `DebugLogger` default for standalone use.

 `DebugLogger` comes from DebugLog, DebugTrace's dependency-free logging
 product, which builds on Linux too (RoboFrame's Pi kiosk). There the hub's
 system sink writes to stderr, with every value that is not `.public` withheld:
 a kiosk's journal is forwarded off the box, so it gets the same treatment as
 an exported trace. `RAVE_LOG_PRIVATE=1` in the environment shows `.private`
 values too, for debugging at the device; `.sensitive` values are never shown.
 Debug lines are dropped unless `RAVE_LOG_DEBUG=1`, as the unified log doesn't
 keep them either: a socket's per-frame lines would otherwise fill the journal.
 In an app that also links DebugTrace the same lines reach its in-app console
 and traces.
 */

import DebugLog
import Foundation

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

/// DebugLog's message type, so an app's `RAVENetLogger` forwards it to its
/// own `DebugLogger` with each value's privacy intact.
public typealias RAVENetLogMessage = DebugLogMessage

/// Default sink writing to `DebugLogger`: the unified log (stderr on Linux),
/// and the in-app console when the app links DebugTrace. Used when an app
/// supplies none.
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
