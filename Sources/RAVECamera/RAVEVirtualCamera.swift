/*
 RAVECamera - a camera one app publishes and another app on the same device
 subscribes to.

 visionOS gives apps no virtual capture device: there is no CoreMedia I/O, and
 the Persona is the only camera WebKit will ever offer a page. So an app that
 renders something worth sending as a camera — spatial-ai-character's avatar,
 performed by the wearer — publishes it here as encoded access units, and an
 app that owns a camera proxy — Raven's, which already paints a page's
 `getUserMedia` track from `RAVEH264Encoder` output — subscribes and paints
 from it instead of from the sensor.

 Loopback TCP on a fixed port, the same transport Raven's screen-share
 extension already uses, and for the same reason: no App Group, so no
 entitlement the sideload provisioning would have to carry.

 **The publisher listens and the subscriber dials**, the reverse of the
 screen-share pipe, because a camera is a device that exists before anyone
 opens it: the avatar app listens while its camera is on, and a page asking
 for the camera connects, or learns at once that nothing is publishing.
 Nothing is rendered or encoded for nobody: `onSubscribersChanged` tells the
 publisher's owner when to start and stop.

 **Anything local can dial the port.** The stream is the wearer's avatar, not
 their face, but it carries how they move and what they render behind it, so
 the publisher reports every subscriber and its owner should show that a
 camera is being watched — the same thing a camera indicator does. The
 listener binds loopback only.

 Flow control is per subscriber and keyframe-shaped, like Raven's relay: a
 subscriber whose socket backs up stops receiving deltas until the next
 keyframe, which the publisher's owner is asked for at once. A subscriber that
 joins mid-GOP waits for a keyframe the same way.
 */

import Foundation
import Network

public enum RAVEVirtualCamera {
    /// One port per device, as there is one camera. The screen-share pipe is
    /// 46414.
    public static let port: UInt16 = 46415
}

// MARK: - Publisher

public final class RAVEVirtualCameraPublisher: @unchecked Sendable {
    /// How many subscribers may watch at once. A camera proxy is per tab, and
    /// a call rarely runs in more than one; past this a connection is refused.
    public static let maxSubscribers = 4
    /// Bytes a subscriber may have queued before it is put back on
    /// "keyframe only". About a quarter second at 8 Mbit/s: a backlog any
    /// longer is steady-state latency, never a burst.
    public static let backlogLimit = 256 * 1024

    /// Every callback fires on the publisher's own queue.
    /// The subscriber count changed: render and encode only while it is
    /// above zero.
    public var onSubscribersChanged: ((Int) -> Void)?
    /// Someone needs a keyframe now: a subscriber joined, asked, or fell
    /// behind. Forward to `RAVEH264Encoder.requestKeyframe()`.
    public var onKeyframeRequested: (() -> Void)?
    /// The listener could not bind or failed later. One shot; the publisher
    /// is stopped afterwards.
    public var onFailed: ((String) -> Void)?

    private let port: UInt16
    private let queue = DispatchQueue(label: "com.illixion.rave.virtualcamera.publisher", qos: .userInteractive)
    private var listener: NWListener?
    private var subscribers: [ObjectIdentifier: Subscriber] = [:]
    private var config: (codecString: String, record: Data, width: Int, height: Int)?
    private var stopped = false

    /// Confined to the publisher's queue, like everything else here.
    private final class Subscriber: @unchecked Sendable {
        let connection: NWConnection
        var ready = false
        var waitingForKeyframe = true
        var queuedBytes = 0
        var control = RAVEVideoFraming.Parser(magic: nil)
        init(connection: NWConnection) { self.connection = connection }
    }

    public init(port: UInt16 = RAVEVirtualCamera.port) {
        self.port = port
    }

    /// How many subscribers are connected, read on any thread.
    public var subscriberCount: Int {
        queue.sync { subscribers.values.filter(\.ready).count }
    }

    public func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            stopped = false
            let parameters = NWParameters.tcp
            // Loopback only: binding the wildcard address would offer the
            // avatar to every interface.
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
            parameters.allowLocalEndpointReuse = true
            let listener: NWListener
            do {
                listener = try NWListener(using: parameters)
            } catch {
                fail("couldn't listen on \(port): \(error.localizedDescription)")
                return
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.fail("listener failed: \(error.localizedDescription)")
                }
            }
            self.listener = listener
            listener.start(queue: queue)
            RAVECameraLog.virtualCamera.info("virtual camera: publishing on \(self.port, privacy: .public)")
        }
    }

    /// Closes the listener and every subscriber. A subscriber sees EOF, which
    /// is how "the camera went away" reaches it.
    public func stop() {
        queue.async { [self] in
            stopped = true
            listener?.cancel()
            listener = nil
            let had = subscribers.values.contains(where: \.ready)
            subscribers.values.forEach { $0.connection.cancel() }
            subscribers.removeAll()
            config = nil
            if had { onSubscribersChanged?(0) }
        }
    }

    /// The encoder's decoder configuration and the frame size it was made
    /// for. Kept, so every later subscriber gets it before its first frame.
    public func publish(config codecString: String, record: Data, width: Int, height: Int) {
        queue.async { [self] in
            config = (codecString, record, width, height)
            let message = RAVEVideoFraming.encode(
                .config(codecString: codecString, record: record, width: width, height: height))
            for subscriber in subscribers.values where subscriber.ready {
                // Units after a new configuration decode only from its first
                // keyframe.
                subscriber.waitingForKeyframe = true
                send(message, to: subscriber)
            }
        }
    }

    /// One encoded frame, as `RAVEH264Encoder.onAccessUnit` produced it.
    public func publish(frame data: Data, ptsMicroseconds: UInt64, keyframe: Bool,
                        capturedAtMs: Double, encodedAtMs: Double) {
        queue.async { [self] in
            guard config != nil, !subscribers.isEmpty else { return }
            var message: Data?
            var wantKeyframe = false
            for subscriber in subscribers.values where subscriber.ready {
                if subscriber.waitingForKeyframe {
                    guard keyframe else { continue }
                    subscriber.waitingForKeyframe = false
                }
                // Never drop a lone delta — that poisons the chain until a
                // keyframe anyway. Drop to one, and ask for it now.
                if subscriber.queuedBytes > Self.backlogLimit, !keyframe {
                    subscriber.waitingForKeyframe = true
                    wantKeyframe = true
                    continue
                }
                let encoded = message ?? RAVEVideoFraming.encode(.frame(
                    data: data, ptsMicroseconds: ptsMicroseconds, keyframe: keyframe,
                    capturedAtMs: capturedAtMs, encodedAtMs: encodedAtMs))
                message = encoded
                send(encoded, to: subscriber)
            }
            if wantKeyframe { onKeyframeRequested?() }
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        guard !stopped, subscribers.count < Self.maxSubscribers else {
            connection.cancel()
            return
        }
        let subscriber = Subscriber(connection: connection)
        let id = ObjectIdentifier(subscriber)
        subscribers[id] = subscriber
        connection.stateUpdateHandler = { [weak self, weak subscriber] state in
            guard let self, let subscriber else { return }
            switch state {
            case .ready:
                subscriber.ready = true
                self.send(RAVEVideoFraming.virtualCameraMagic, to: subscriber)
                if let config = self.config {
                    self.send(RAVEVideoFraming.encode(.config(
                        codecString: config.codecString, record: config.record,
                        width: config.width, height: config.height)), to: subscriber)
                }
                self.receive(on: subscriber)
                let count = self.subscribers.values.filter(\.ready).count
                RAVECameraLog.virtualCamera.info("virtual camera: subscriber joined (\(count, privacy: .public) watching)")
                self.onSubscribersChanged?(count)
                self.onKeyframeRequested?()
            case .failed, .cancelled:
                self.drop(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on subscriber: Subscriber) {
        subscriber.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak subscriber] data, _, isComplete, error in
            guard let self, let subscriber else { return }
            if let data, !data.isEmpty {
                do {
                    for message in try subscriber.control.consume(data) where message == .keyframeRequest {
                        subscriber.waitingForKeyframe = true
                        self.onKeyframeRequested?()
                    }
                } catch {
                    RAVECameraLog.virtualCamera.error("virtual camera: dropping a subscriber that sent \(String(describing: error), privacy: .public)")
                    subscriber.connection.cancel()
                    return
                }
            }
            if isComplete || error != nil {
                subscriber.connection.cancel()
            } else {
                self.receive(on: subscriber)
            }
        }
    }

    private func send(_ data: Data, to subscriber: Subscriber) {
        subscriber.queuedBytes += data.count
        subscriber.connection.send(content: data, completion: .contentProcessed { [weak subscriber] error in
            guard let subscriber else { return }
            subscriber.queuedBytes -= data.count
            if error != nil { subscriber.connection.cancel() }
        })
    }

    private func drop(_ id: ObjectIdentifier) {
        guard let subscriber = subscribers.removeValue(forKey: id) else { return }
        subscriber.connection.stateUpdateHandler = nil
        guard subscriber.ready, !stopped else { return }
        let count = subscribers.values.filter(\.ready).count
        RAVECameraLog.virtualCamera.info("virtual camera: subscriber left (\(count, privacy: .public) watching)")
        onSubscribersChanged?(count)
    }

    private func fail(_ reason: String) {
        guard !stopped else { return }
        RAVECameraLog.virtualCamera.error("virtual camera: \(reason, privacy: .public)")
        stopped = true
        listener?.cancel()
        listener = nil
        subscribers.values.forEach { $0.connection.cancel() }
        subscribers.removeAll()
        onFailed?(reason)
    }
}

// MARK: - Subscriber

public final class RAVEVirtualCameraSubscriber: @unchecked Sendable {
    /// Every callback fires on the subscriber's own queue, in stream order.
    public var onConfig: ((_ codecString: String, _ record: Data, _ width: Int, _ height: Int) -> Void)?
    public var onFrame: ((
        _ data: Data, _ ptsMicroseconds: UInt64, _ keyframe: Bool,
        _ capturedAtMs: Double, _ encodedAtMs: Double
    ) -> Void)?
    /// The stream ended or never started: nothing publishing, the publisher
    /// stopped, a broken connection or a stream that is not a camera. One
    /// shot, and not fired by `stop()`.
    public var onEnded: ((String) -> Void)?

    /// Loopback with no listener refuses at once, but "at once" is not a
    /// contract; this caps the wait.
    public static let connectTimeout: TimeInterval = 3

    private let queue = DispatchQueue(label: "com.illixion.rave.virtualcamera.subscriber", qos: .userInteractive)
    private let connection: NWConnection
    private var parser = RAVEVideoFraming.Parser(magic: RAVEVideoFraming.virtualCameraMagic)
    private var ready = false
    private var ended = false

    public init(port: UInt16 = RAVEVirtualCamera.port) {
        connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.ready = true
                self.receive()
            case .waiting(let error), .failed(let error):
                // `.waiting` is what a refused loopback connection looks like:
                // Network would retry forever, but nothing is publishing.
                self.finish("no camera is publishing (\(error.localizedDescription))")
            case .cancelled:
                self.finish("the connection closed")
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak self] in
            guard let self, !self.ready else { return }
            self.finish("no camera is publishing")
        }
    }

    /// Asks the publisher to make its next frame a keyframe: after a drop, so
    /// recovery is a frame rather than the rest of the GOP.
    public func requestKeyframe() {
        queue.async { [self] in
            guard ready, !ended else { return }
            connection.send(content: RAVEVideoFraming.encode(.keyframeRequest),
                            completion: .contentProcessed { _ in })
        }
    }

    /// Deliberate teardown; does not fire `onEnded`.
    public func stop() {
        queue.async { [self] in
            ended = true
            connection.cancel()
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for message in try self.parser.consume(data) {
                        switch message {
                        case .config(let codecString, let record, let width, let height):
                            self.onConfig?(codecString, record, width, height)
                        case .frame(let data, let pts, let keyframe, let capturedAtMs, let encodedAtMs):
                            self.onFrame?(data, pts, keyframe, capturedAtMs, encodedAtMs)
                        case .keyframeRequest:
                            break
                        }
                    }
                } catch {
                    self.finish("not a camera stream (\(error))")
                    return
                }
            }
            if isComplete || error != nil {
                self.finish("the camera stopped publishing")
            } else {
                self.receive()
            }
        }
    }

    private func finish(_ reason: String) {
        guard !ended else { return }
        ended = true
        connection.cancel()
        onEnded?(reason)
    }
}
