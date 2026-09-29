/*
 RAVECamera - logging.

 **The subsystem stays `Bundle.main.bundleIdentifier`**, as in `RAVEMediaLog`,
 so these lines sort with the host app's. Only the categories are the
 package's own. The loggers are `DebugLogger`s, so every line reaches the
 in-app console and debug traces; unannotated values are private.
 */

import DebugTrace
import Foundation
import os

public enum RAVECameraLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.illixion.ravecamera"

    /// Device discovery, session configuration, interruptions and runtime errors.
    public static let capture = DebugLogger(subsystem: subsystem, category: "Camera")

    /// Compression-session lifecycle: creation, parameter-set changes, failures.
    public static let encoder = DebugLogger(subsystem: subsystem, category: "H264Encoder")
}
