/*
 RAVECamera - logging.

 **The subsystem stays `Bundle.main.bundleIdentifier`, deliberately**, for the
 same reason `RAVEMediaLog` does: `RAVEConsole` polls `OSLogStore` filtered by
 the host app's subsystem, so a package-owned subsystem would make every line
 from here invisible in the in-app console — the one place these are read on
 device. Only the categories are the package's own.

 `OSLogMessage` is a compiler-special type that cannot pass through a wrapper
 function, which is why call sites interpolate directly and annotate `.public`
 themselves; without the annotation os_log redacts the value and the line
 reads `<private>`.
 */

import Foundation
import os

public enum RAVECameraLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.illixion.ravecamera"

    /// Device discovery, session configuration, interruptions and runtime errors.
    public static let capture = Logger(subsystem: subsystem, category: "Camera")

    /// Compression-session lifecycle: creation, parameter-set changes, failures.
    public static let encoder = Logger(subsystem: subsystem, category: "H264Encoder")
}
