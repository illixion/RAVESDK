/*
 RAVEMedia - logging.

 The depth pipeline logged through Spatial Stash's `AppLogger` under two
 categories that predated it ("VideoCache" and "VideoWindow"). Those names
 belonged to the app's window and download layers, not to depth, so the package
 takes its own: `cache` for the on-disk conversion cache, `pipeline` for model
 loading and per-video engage decisions.

 **The subsystem stays `Bundle.main.bundleIdentifier`, deliberately.**
 `RAVEConsole` polls `OSLogStore` filtered by the host app's subsystem, so a
 package-owned subsystem would make every line from here invisible in the
 in-app console — the one place these are read on device.

 `OSLogMessage` is a compiler-special type that cannot pass through a wrapper
 function, which is why call sites interpolate directly and annotate `.public`
 themselves; without the annotation os_log redacts the value and the line reads
 `<private>`.
 */

import Foundation
import os

public enum RAVEMediaLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.illixion.ravemedia"

    /// Depth cache: conversions, eviction, entry lifecycle.
    public static let cache = Logger(subsystem: subsystem, category: "DepthCache")

    /// The live pipeline: model load, engage decisions, playback fit.
    public static let pipeline = Logger(subsystem: subsystem, category: "Pseudo3D")

    /// Per-stage intervals for the fake-3D pipeline (inference, stabilize, warp,
    /// transfer) — view in Instruments' os_signpost track to see where a pump
    /// tick or a depth-conversion frame spends its time.
    public static let signposter = OSSignposter(subsystem: subsystem, category: "Pseudo3D")
}
