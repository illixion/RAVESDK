/*
 RAVEMedia - logging.

 The depth pipeline now lives in Vergence, which logs through its own
 `VergenceLog` (os.Logger when nothing else is attached). `routeVergenceLogs()`
 attaches `DebugLogger` (the DebugLog facility) instead, so Vergence's lines reach
 every sink on its hub: the unified log, and in an app that links DebugTrace the
 in-app console and debug traces like everything else. Each message arrives as
 segments with their privacy and is rebuilt as a `DebugLogMessage`, never as
 finished text, so the hub applies its privacy rules value by value.

 **The subsystem stays `Bundle.main.bundleIdentifier`**, so these lines sort
 with the host app's in Console.app and in traces.
 */

import DebugLog
import Foundation
import os
import VergenceApple

public enum RAVEMediaLog {
    private static let subsystem = VergenceLog.subsystem

    // Vergence emits from the real-time depth-inference queue. Keep OS logging
    // off that stack: a Vision Pro crash showed the queue's 512 KB stack
    // reaching its guard while os_log was formatting a routed depth event.
    // Bound pending work so a noisy producer cannot turn logging into an
    // unbounded queue or retain an arbitrary number of frame diagnostics.
    private static let routingQueue = DispatchQueue(label: "com.rave.media-log-routing")
    private static let routingSlots = DispatchSemaphore(value: 64)
    private static let routingThreadKey = "RAVEMediaLog.isRoutingVergenceEvent"

    /// The live player: engage decisions, playback fit.
    public static let pipeline = DebugLogger(subsystem: subsystem, category: "Pseudo3D")

    /// Depth for still pictures: the shared estimator's model loads, releases
    /// and timings.
    public static let stills = DebugLogger(subsystem: subsystem, category: "StillDepth")

    /// Which spatial-audio experience each player gets, and what said so.
    public static let spatialAudio = DebugLogger(subsystem: subsystem, category: "SpatialAudio")
    /// The audio equalizer: taps, and the stream path (`EQStreamPlayback`).
    public static let audioEQ = DebugLogger(subsystem: subsystem, category: "AudioEQ")

    /// Per-stage intervals for the fake-3D pipeline (inference, stabilize, warp,
    /// transfer) — view in Instruments' os_signpost track to see where a pump
    /// tick or a depth-conversion frame spends its time.
    public static var signposter: OSSignposter { VergenceLog.signposter }

    /// Sends Vergence's log lines through DebugLog. Idempotent; the stereo
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
            // DebugLogger writes to os_log. If that path ever feeds back into
            // VergenceLog, drop the nested event instead of recursing until
            // the producer's thread stack is exhausted.
            guard Thread.current.threadDictionary[routingThreadKey] == nil else { return }
            // The depth path can produce diagnostics continuously. Never make
            // that real-time queue wait for the log writer or accumulate an
            // unbounded backlog when the system logger is under pressure.
            guard routingSlots.wait(timeout: .now()) == .success else { return }
            routingQueue.async {
                let threadDictionary = Thread.current.threadDictionary
                guard threadDictionary[routingThreadKey] == nil else {
                    routingSlots.signal()
                    return
                }
                threadDictionary[routingThreadKey] = true
                defer {
                    threadDictionary.removeObject(forKey: routingThreadKey)
                    routingSlots.signal()
                }

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
        }
    }()

    /// The same message as a `DebugLogMessage`, value by value with its privacy.
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
