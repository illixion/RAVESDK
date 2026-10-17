/*
 RAVECamera - another app's virtual camera as a camera feed.

 spatial-ai-character renders an avatar the wearer performs and publishes it
 as encoded video on loopback (`RAVEVirtualCameraPublisher`, port 46415). This
 subscribes to it with `RAVEVirtualCameraSubscriber` and hands a camera proxy
 exactly what `RAVEPersonaCameraFeed` would: the decoder configuration with
 its frame size, then access units with their wall-clock stamps, then a
 one-shot ending. So the relay, an app's replay ring and the latency report
 all work on it unchanged.

 Three things it does not have that the Persona feed does, all on purpose:

 - **No exclusivity.** The Persona is a device one process can hold; the
   virtual camera is a broadcast the publisher hands up to four subscribers
   (`RAVEVirtualCameraPublisher.maxSubscribers`), so every tab that asks gets
   its own subscription.
 - **No uncompressed samples.** There is no `onVideoSample`: the frames exist
   only encoded. A preview has to decode the units (Raven's live pane does).
 - **No retry of its own.** An ending is reported once, like any feed's; the
   proxy decides to subscribe again, and for a fail-closed source it always
   does while the page still wants the camera.

 Timestamps are the publisher's, rebased to *its* first frame rather than to
 this subscription, so a subscriber joining a minute in sees PTS starting near
 sixty seconds, and one rejoining a restarted publisher sees them start over.
 The proxy's `monotonic` lifts anything that would run backwards, which covers
 both. `capturedAtMs`/`encodedAtMs` are the publisher's stamps on the shared
 wall clock, which is what keeps the latency report meaningful.

 Raven's `AvatarCameraFeed`, lifted 2026-10-17.
 */

import Foundation

public final class RAVEVirtualCameraFeed: RAVECameraFeed, @unchecked Sendable {
    public nonisolated(unsafe) var onDecoderConfiguration: (@Sendable (
        RAVEH264Encoder.DecoderConfiguration, _ width: Int, _ height: Int
    ) -> Void)?
    public nonisolated(unsafe) var onAccessUnit: (@Sendable (
        _ data: Data, _ ptsMicroseconds: UInt64, _ keyframe: Bool,
        _ capturedAtMs: Double, _ encodedAtMs: Double
    ) -> Void)?
    public nonisolated(unsafe) var onEnded: (@Sendable (String) -> Void)?

    private let subscriber: RAVEVirtualCameraSubscriber

    deinit { RAVELiveObjects.release("RAVEVirtualCameraFeed") }

    public init(port: UInt16 = RAVEVirtualCamera.port) {
        RAVELiveObjects.retain("RAVEVirtualCameraFeed")
        subscriber = RAVEVirtualCameraSubscriber(port: port)
    }

    /// Dials the publisher. Nothing publishing ends the feed at once (or at
    /// the subscriber's 3 s connect timeout); the publisher asks its encoder
    /// for a keyframe when a subscriber joins, so the first unit is one.
    public func start() {
        // Weak: the callbacks live on the subscriber this feed owns.
        subscriber.onConfig = { [weak self] codecString, record, width, height in
            self?.onDecoderConfiguration?(
                RAVEH264Encoder.DecoderConfiguration(codecString: codecString, record: record), width, height)
        }
        subscriber.onFrame = { [weak self] data, pts, keyframe, capturedAtMs, encodedAtMs in
            self?.onAccessUnit?(data, pts, keyframe, capturedAtMs, encodedAtMs)
        }
        subscriber.onEnded = { [weak self] reason in
            self?.onEnded?(reason)
        }
        subscriber.start()
    }

    public func stop() {
        subscriber.stop()
    }

    public func requestKeyframe() {
        subscriber.requestKeyframe()
    }
}
