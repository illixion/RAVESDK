/*
 RAVEMedia - logging.

 The depth pipeline now lives in Vergence, which logs through its own
 `VergenceLog` (os.Logger when nothing else is attached). `routeVergenceLogs()`
 attaches DebugTrace instead, so Vergence's lines reach the in-app console and
 debug traces like everything else. Each message arrives as segments with
 their privacy and is rebuilt as a `DebugLogMessage`, never as finished text,
 so DebugTrace applies its own rules value by value.

 **The subsystem stays `Bundle.main.bundleIdentifier`**, so these lines sort
 with the host app's in Console.app and in traces.
 */

import DebugTrace
import Foundation
import os
import VergenceApple

public enum RAVEMediaLog {
    private static let subsystem = VergenceLog.subsystem

    /// The live player: engage decisions, playback fit.
    public static let pipeline = DebugLogger(subsystem: subsystem, category: "Pseudo3D")

    /// Per-stage intervals for the fake-3D pipeline (inference, stabilize, warp,
    /// transfer) — view in Instruments' os_signpost track to see where a pump
    /// tick or a depth-conversion frame spends its time.
    public static var signposter: OSSignposter { VergenceLog.signposter }

    /// Sends Vergence's log lines through DebugTrace. Idempotent; the stereo
    /// engine calls it, and hosts that convert without playing call it at launch.
    public static func routeVergenceLogs() {
        _ = routing
    }

    private static let routing: Void = {
        let loggers = [
            VergenceLog.cache.category: DebugLogger(subsystem: subsystem, category: VergenceLog.cache.category),
            VergenceLog.pipeline.category: pipeline,
        ]
        VergenceLog.sink = { event in
            let logger = loggers[event.category] ?? DebugLogger(subsystem: subsystem, category: event.category)
            let message = debugMessage(event.message)
            switch event.level {
            case .debug: logger.debug(message)
            case .info: logger.info(message)
            case .notice: logger.notice(message)
            case .error: logger.error(message)
            case .fault: logger.fault(message)
            }
        }
    }()

    /// The same message for DebugTrace, value by value with its privacy.
    static func debugMessage(_ message: VergenceLogMessage) -> DebugLogMessage {
        var out: DebugLogMessage = ""
        for segment in message.segments {
            switch segment {
            case .text(let text):
                out = "\(out)\(text, privacy: .public)"
            case .value(let value, let privacy):
                let mask: DebugLogPrivacy.Mask = privacy.mask == .hash ? .hash : .none
                switch privacy.level {
                case .public: out = "\(out)\(value, privacy: .public)"
                case .sensitive: out = "\(out)\(value, privacy: .sensitive(mask: mask))"
                case .private, .auto: out = "\(out)\(value, privacy: .private(mask: mask))"
                }
            }
        }
        return out
    }
}
