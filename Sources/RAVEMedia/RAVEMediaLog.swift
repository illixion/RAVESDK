/*
 RAVEMedia - logging.

 The depth pipeline logged through Spatial Stash's `AppLogger` under two
 categories that predated it ("VideoCache" and "VideoWindow"). Those names
 belonged to the app's window and download layers, not to depth, so the package
 takes its own: `cache` for the on-disk conversion cache, `pipeline` for model
 loading and per-video engage decisions.

 **The subsystem stays `Bundle.main.bundleIdentifier`**, so these lines sort
 with the host app's in Console.app and in traces.

 The loggers are DebugTrace's `DebugLogger`, so every line reaches the in-app
 console and debug traces. Call sites annotate `.public` themselves; anything
 left unannotated is treated as private, as os_log does.
 */

import DebugTrace
import Foundation
import os

public enum RAVEMediaLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.illixion.ravemedia"

    /// Depth cache: conversions, eviction, entry lifecycle.
    public static let cache = DebugLogger(subsystem: subsystem, category: "DepthCache")

    /// The live pipeline: model load, engage decisions, playback fit.
    public static let pipeline = DebugLogger(subsystem: subsystem, category: "Pseudo3D")

    /// Per-stage intervals for the fake-3D pipeline (inference, stabilize, warp,
    /// transfer) — view in Instruments' os_signpost track to see where a pump
    /// tick or a depth-conversion frame spends its time.
    public static let signposter = OSSignposter(subsystem: subsystem, category: "Pseudo3D")
}
