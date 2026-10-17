/*
 RAVECamera - a camera an app publishes into and its own pages subscribe to.

 `RAVEVirtualCameraPublisher` exists because one app's camera has to reach
 another app's camera proxy, and loopback TCP is the pipe between processes.
 When the proxy runs in the same app as the renderer — spatial-ai-character
 showing a Google Meet call in its own window, because an open immersive
 space hides every other app's windows — the socket is only cost: a copy
 through the kernel and a framing parse per frame, for bytes already in this
 process. This is the same camera without the socket.

 **The API mirrors the publisher's** so an app can publish to either, or both,
 from one encoder callback: `publish(config:record:width:height:)`,
 `publish(frame:ptsMicroseconds:keyframe:capturedAtMs:encodedAtMs:)`,
 `onKeyframeRequested` (forward to `RAVEH264Encoder.requestKeyframe()`), and
 `onSubscribersChanged` (render and encode only while it is above zero).
 `start()`/`stop()` mean what they do there: a feed that starts while nothing
 is publishing ends at once ("no camera is publishing"), and `stop()` ends
 every feed. A fail-closed proxy treats both as an outage, shows its offline
 card, and subscribes again a couple of seconds later.

 **It hands out feeds, not frames.** `makeFeed()` returns a `RAVECameraFeed`,
 the protocol RAVEBrowser's camera proxy relays from, so the proxy cannot
 tell this camera from the loopback one. Each feed is a subscriber: it gets
 the latest configuration when it joins and waits for a keyframe, which the
 owner is asked for at once — the publisher's rule for a late joiner, and a
 feed that asks for a keyframe itself (the relay dropped) waits for one the
 same way. Feeds fan out: every tab on a call subscribes on its own.

 **Concurrency.** `publish` is called from the encoder's output thread, the
 feeds are started and stopped from the main actor, and each feed calls back
 on its own serial queue. All shared state is behind one lock; nothing is
 called while holding it except `DispatchQueue.async`, which only enqueues.
 Enqueueing under the lock is what keeps each feed's stream in publish order
 (config before the frames that depend on it) however the threads interleave.
 The owner's callbacks fire, in order, on the camera's own queue.
 */

import Foundation
import os

public final class RAVEInProcessCamera: Sendable {
    fileprivate struct Config: Sendable {
        let codecString: String
        let record: Data
        let width: Int
        let height: Int
    }

    fileprivate struct Frame: Sendable {
        let data: Data
        let ptsMicroseconds: UInt64
        let keyframe: Bool
        let capturedAtMs: Double
        let encodedAtMs: Double
    }

    private struct Subscription: Sendable {
        /// Weak: a feed its owner dropped without stopping must not be kept
        /// alive by the camera. It is swept out on the next publish.
        weak var feed: RAVEInProcessCameraFeed?
        var waitingForKeyframe = true
    }

    private struct State: Sendable {
        var onSubscribersChanged: (@Sendable (Int) -> Void)?
        var onKeyframeRequested: (@Sendable () -> Void)?
        var publishing = false
        var config: Config?
        var subscriptions: [ObjectIdentifier: Subscription] = [:]
        var reportedCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let callbackQueue = DispatchQueue(
        label: "com.illixion.rave.inprocesscamera", qos: .userInteractive)

    public init() {}

    /// The subscriber count changed: render and encode only while it is above
    /// zero. Fires on the camera's own queue.
    public var onSubscribersChanged: (@Sendable (Int) -> Void)? {
        get { state.withLock { $0.onSubscribersChanged } }
        set { state.withLock { $0.onSubscribersChanged = newValue } }
    }

    /// Someone needs a keyframe now: a feed joined, or asked after a drop.
    /// Forward to `RAVEH264Encoder.requestKeyframe()`. Fires on the camera's
    /// own queue.
    public var onKeyframeRequested: (@Sendable () -> Void)? {
        get { state.withLock { $0.onKeyframeRequested } }
        set { state.withLock { $0.onKeyframeRequested = newValue } }
    }

    /// How many feeds are subscribed, read on any thread.
    public var subscriberCount: Int {
        state.withLock { state in state.subscriptions.values.filter { $0.feed != nil }.count }
    }

    /// Whether `start()` has been called and `stop()` has not.
    public var isPublishing: Bool { state.withLock { $0.publishing } }

    /// Opens the camera to subscribers.
    public func start() {
        state.withLock { $0.publishing = true }
        RAVECameraLog.virtualCamera.info("in-process camera: publishing")
    }

    /// Ends every feed (each sees `onEnded`) and forgets the configuration.
    public func stop() {
        state.withLock { state in
            guard state.publishing else { return }
            state.publishing = false
            state.config = nil
            for subscription in state.subscriptions.values {
                subscription.feed?.deliverEnd("the camera stopped publishing")
            }
            state.subscriptions.removeAll()
            notifyCountIfChanged(&state)
        }
    }

    /// A subscriber of this camera, for a camera proxy (`RAVECameraProxy`'s
    /// `makeFeed`). Nothing happens until the proxy starts it.
    public func makeFeed() -> any RAVECameraFeed {
        RAVEInProcessCameraFeed(camera: self)
    }

    /// The encoder's decoder configuration and the frame size it was made
    /// for. Kept, so every later subscriber gets it before its first frame.
    public func publish(config codecString: String, record: Data, width: Int, height: Int) {
        let config = Config(codecString: codecString, record: record, width: width, height: height)
        state.withLock { state in
            state.config = config
            for (id, var subscription) in state.subscriptions {
                guard let feed = subscription.feed else { continue }
                // Units after a new configuration decode only from its first
                // keyframe.
                subscription.waitingForKeyframe = true
                state.subscriptions[id] = subscription
                feed.deliver(config)
            }
        }
    }

    /// One encoded frame, as `RAVEH264Encoder.onAccessUnit` produced it.
    public func publish(frame data: Data, ptsMicroseconds: UInt64, keyframe: Bool,
                        capturedAtMs: Double, encodedAtMs: Double) {
        let frame = Frame(data: data, ptsMicroseconds: ptsMicroseconds, keyframe: keyframe,
                          capturedAtMs: capturedAtMs, encodedAtMs: encodedAtMs)
        state.withLock { state in
            guard state.config != nil, !state.subscriptions.isEmpty else { return }
            var swept = false
            for (id, var subscription) in state.subscriptions {
                guard let feed = subscription.feed else {
                    state.subscriptions[id] = nil
                    swept = true
                    continue
                }
                if subscription.waitingForKeyframe {
                    guard keyframe else { continue }
                    subscription.waitingForKeyframe = false
                    state.subscriptions[id] = subscription
                }
                feed.deliver(frame)
            }
            if swept { notifyCountIfChanged(&state) }
        }
    }

    // MARK: - Feeds

    fileprivate func subscribe(_ feed: RAVEInProcessCameraFeed) {
        state.withLock { state in
            guard state.publishing else {
                feed.deliverEnd("no camera is publishing")
                return
            }
            state.subscriptions[ObjectIdentifier(feed)] = Subscription(feed: feed)
            if let config = state.config { feed.deliver(config) }
            notifyCountIfChanged(&state)
            if let ask = state.onKeyframeRequested { callbackQueue.async { ask() } }
        }
    }

    fileprivate func unsubscribe(_ feed: RAVEInProcessCameraFeed) {
        state.withLock { state in
            guard state.subscriptions.removeValue(forKey: ObjectIdentifier(feed)) != nil else { return }
            notifyCountIfChanged(&state)
        }
    }

    fileprivate func keyframeRequested(by feed: RAVEInProcessCameraFeed) {
        state.withLock { state in
            let id = ObjectIdentifier(feed)
            guard var subscription = state.subscriptions[id] else { return }
            // Never a lone delta after a drop: the feed waits for the keyframe
            // it asked for, as a loopback subscriber does.
            subscription.waitingForKeyframe = true
            state.subscriptions[id] = subscription
            if let ask = state.onKeyframeRequested { callbackQueue.async { ask() } }
        }
    }

    /// Called with the lock held; only enqueues.
    private func notifyCountIfChanged(_ state: inout State) {
        let count = state.subscriptions.values.filter { $0.feed != nil }.count
        guard count != state.reportedCount else { return }
        let joined = count > state.reportedCount
        state.reportedCount = count
        RAVECameraLog.virtualCamera.info("""
        in-process camera: subscriber \(joined ? "joined" : "left", privacy: .public) \
        (\(count, privacy: .public) watching)
        """)
        if let changed = state.onSubscribersChanged { callbackQueue.async { changed(count) } }
    }
}

// MARK: - Feed

/// One subscription to a `RAVEInProcessCamera`. Calls back on its own serial
/// queue, in publish order.
public final class RAVEInProcessCameraFeed: RAVECameraFeed, Sendable {
    private struct State: Sendable {
        var onDecoderConfiguration: (@Sendable (RAVEH264Encoder.DecoderConfiguration, Int, Int) -> Void)?
        var onAccessUnit: (@Sendable (Data, UInt64, Bool, Double, Double) -> Void)?
        var onEnded: (@Sendable (String) -> Void)?
        var started = false
        /// Stopped by its owner, or ended: nothing more is delivered.
        var finished = false
    }

    private let camera: RAVEInProcessCamera
    private let queue = DispatchQueue(label: "com.illixion.rave.inprocesscamera.feed", qos: .userInteractive)
    private let state = OSAllocatedUnfairLock(initialState: State())

    deinit { RAVELiveObjects.release("RAVEInProcessCameraFeed") }

    fileprivate init(camera: RAVEInProcessCamera) {
        RAVELiveObjects.retain("RAVEInProcessCameraFeed")
        self.camera = camera
    }

    public var onDecoderConfiguration: (@Sendable (
        RAVEH264Encoder.DecoderConfiguration, _ width: Int, _ height: Int
    ) -> Void)? {
        get { state.withLock { $0.onDecoderConfiguration } }
        set { state.withLock { $0.onDecoderConfiguration = newValue } }
    }

    public var onAccessUnit: (@Sendable (
        _ data: Data, _ ptsMicroseconds: UInt64, _ keyframe: Bool,
        _ capturedAtMs: Double, _ encodedAtMs: Double
    ) -> Void)? {
        get { state.withLock { $0.onAccessUnit } }
        set { state.withLock { $0.onAccessUnit = newValue } }
    }

    public var onEnded: (@Sendable (String) -> Void)? {
        get { state.withLock { $0.onEnded } }
        set { state.withLock { $0.onEnded = newValue } }
    }

    public func start() {
        let first = state.withLock { state -> Bool in
            guard !state.started else { return false }
            state.started = true
            return true
        }
        if first { camera.subscribe(self) }
    }

    /// Deliberate teardown; does not fire `onEnded`, and drops anything still
    /// queued for delivery.
    public func stop() {
        state.withLock { $0.finished = true }
        camera.unsubscribe(self)
    }

    public func requestKeyframe() {
        camera.keyframeRequested(by: self)
    }

    // Called by the camera with its lock held: enqueue only.

    fileprivate func deliver(_ config: RAVEInProcessCamera.Config) {
        queue.async { [self] in
            guard let callback = state.withLock({ $0.finished ? nil : $0.onDecoderConfiguration }) else { return }
            callback(RAVEH264Encoder.DecoderConfiguration(codecString: config.codecString, record: config.record),
                     config.width, config.height)
        }
    }

    fileprivate func deliver(_ frame: RAVEInProcessCamera.Frame) {
        queue.async { [self] in
            guard let callback = state.withLock({ $0.finished ? nil : $0.onAccessUnit }) else { return }
            callback(frame.data, frame.ptsMicroseconds, frame.keyframe, frame.capturedAtMs, frame.encodedAtMs)
        }
    }

    fileprivate func deliverEnd(_ reason: String) {
        queue.async { [self] in
            let callback = state.withLock { state -> (@Sendable (String) -> Void)? in
                guard !state.finished else { return nil }
                state.finished = true
                return state.onEnded
            }
            callback?(reason)
        }
    }
}
