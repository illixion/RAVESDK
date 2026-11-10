/*
 RAVEHome - Logging

 One `DebugLogger` per concern. Lines reach the in-app console and debug
 traces whenever the app links DebugTrace; the privacy labels are load-bearing,
 because cloud models and support read those traces: Home Assistant URLs,
 entity ids, friendly names, HomeKit names, server replies and
 `localizedDescription` are `.private` (entity ids `.private(mask: .hash)`),
 tokens `.sensitive`, and only code-defined values (states, domains, counts,
 versions) are `.public`.
 */

import DebugLog
import Foundation
import RAVENet

enum HomeLog {
    static let subsystem = "pro.rave.home"
    /// Home Assistant WebSocket connection (auth, reconnect, keepalive).
    static let connection = DebugLogger(subsystem: subsystem, category: "Connection")
    /// Entity stores and service calls, both backends.
    static let entities = DebugLogger(subsystem: subsystem, category: "Entities")
}

/// Forwards RAVENet's transport diagnostics into `HomeLog.connection`, keeping
/// their per-value privacy (the server endpoint is logged without its query).
struct HomeTransportLogger: RAVENetLogger {
    func log(_ level: RAVENetLogLevel, _ message: DebugLogMessage) {
        switch level {
        case .debug: HomeLog.connection.debug("WS \(message)")
        case .info: HomeLog.connection.info("WS \(message)")
        case .warning: HomeLog.connection.warning("WS \(message)")
        case .error: HomeLog.connection.error("WS \(message)")
        }
    }
}
