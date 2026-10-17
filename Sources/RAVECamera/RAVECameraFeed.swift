/*
 RAVECamera - what a camera proxy relays into a page.

 One shape for every source a page's camera can be painted from: a stream of
 encoded access units with the decoder configuration ahead of them, a way to
 ask for a keyframe, and a one-shot ending. `RAVEPersonaCameraFeed` is the
 wearer's Persona from the app's own capture session;
 `RAVEVirtualCameraFeed` is another app's camera over loopback
 (`RAVEVirtualCameraSubscriber`); `RAVEInProcessCamera.makeFeed()` is a camera
 the app itself publishes into. Everything downstream (RAVEBrowser's
 `RAVECameraProxy`: its drop policy, the latency report, an app's replay ring
 on the proxy's tap) treats them alike, which is the point: the page decodes
 whatever arrives and cannot tell them apart.

 What differs between sources is policy, and it stays with the proxy, keyed
 on its mode: the Persona is device-exclusive and falls back to WebKit's
 camera when it fails; the avatar and a virtual device are shared by every
 tab that asks and never fall back, because falling back would show the site
 the face the wearer chose not to show.

 Raven wrote this as its own `CameraFeed` (2026-10-17 lift).
 */

import Foundation
import os

public protocol RAVECameraFeed: AnyObject, Sendable {
    /// Codec string plus the `avcC`/`hvcC` record, and the frame size it was
    /// made for. Before the first unit, and again whenever it changes.
    var onDecoderConfiguration: (@Sendable (
        RAVEH264Encoder.DecoderConfiguration, _ width: Int, _ height: Int
    ) -> Void)? { get set }
    /// One access unit, in stream order. `capturedAtMs` and `encodedAtMs` are
    /// wall-clock epoch milliseconds, `nan` when unknown.
    var onAccessUnit: (@Sendable (
        _ data: Data, _ ptsMicroseconds: UInt64, _ keyframe: Bool,
        _ capturedAtMs: Double, _ encodedAtMs: Double
    ) -> Void)? { get set }
    /// The feed stopped, or never started. One shot; not fired by `stop()`.
    var onEnded: (@Sendable (String) -> Void)? { get set }

    /// Set the callbacks first: a feed may deliver as soon as this returns.
    func start()
    /// Deliberate teardown. Does not fire `onEnded`.
    func stop()
    /// The next unit should be a keyframe: the relay dropped, or a new
    /// decoder is waiting.
    func requestKeyframe()
}

// MARK: - Live objects

/// How many of each buffer-owning class exist right now. A class counts
/// itself in at `init` and out at `deinit`, and an app's memory heartbeat
/// prints `summary()`: a count that only goes up is a leak named outright.
///
/// Raven's `LiveObjects`, lifted with the feeds it caught: a closure cycle
/// once kept every Persona feed ever started alive, each with its stopped
/// `AVCaptureSession` and buffer pools, and this count is what named it.
/// The RAVE classes that hold buffers count themselves here; an app may count
/// its own here too, so one line covers both.
public enum RAVELiveObjects {
    private static let counts = OSAllocatedUnfairLock(initialState: [String: Int]())

    public static func retain(_ name: String) {
        counts.withLock { $0[name, default: 0] += 1 }
    }

    public static func release(_ name: String) {
        counts.withLock { $0[name, default: 0] -= 1 }
    }

    public static func count(_ name: String) -> Int {
        counts.withLock { $0[name] ?? 0 }
    }

    /// `Name=count` for every non-zero entry, sorted by name.
    public static func summary() -> String {
        counts.withLock { table in
            table.filter { $0.value != 0 }.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        }
    }
}
