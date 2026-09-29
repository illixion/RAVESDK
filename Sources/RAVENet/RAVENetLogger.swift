/*
 RAVENet - Logging seam

 The package must not reach into an app's logger, but both source
 implementations logged heavily and that logging is load-bearing when
 diagnosing sleep/wake socket failures. So: a narrow protocol the app adapts to
 its own `AppLogger`, with a `DebugLogger` default for standalone use.
 */

import DebugTrace
import Foundation
import os

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
    func log(_ level: RAVENetLogLevel, _ message: DebugLogMessage)
}

/// Default sink writing to `DebugLogger` (the in-app console and the
/// unified log). Used when an app supplies none.
public struct RAVENetOSLogger: RAVENetLogger {
    private let logger: DebugLogger

    public init(subsystem: String = "pro.rave.net", category: String = "websocket") {
        self.logger = DebugLogger(subsystem: subsystem, category: category)
    }

    public func log(_ level: RAVENetLogLevel, _ message: DebugLogMessage) {
        switch level {
        case .debug: logger.debug(message)
        case .info: logger.info(message)
        case .warning: logger.warning(message)
        case .error: logger.error(message)
        }
    }
}

/// Discards everything. Useful in tests.
public struct RAVENetSilentLogger: RAVENetLogger {
    public init() {}
    public func log(_ level: RAVENetLogLevel, _ message: DebugLogMessage) {}
}
