/*
 RAVEBroadcast - logging.

 **The subsystem stays `Bundle.main.bundleIdentifier`**, as in `RAVECameraLog`,
 so these lines sort with the host app's (or the broadcast extension's). The
 logger is a `DebugLogger`, so every line reaches the in-app console and debug
 traces; hosts, URLs and error text stay private.
 */

import DebugLog
import Foundation

public enum RAVEBroadcastLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.illixion.ravebroadcast"

    /// The RTSP session and the encoders feeding it.
    public static let broadcast = DebugLogger(subsystem: subsystem, category: "Broadcast")
}
