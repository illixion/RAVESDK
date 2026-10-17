import Foundation
import Testing
@testable import RAVECamera

/// Real loopback sockets on the host, on ports of their own so a test run
/// never collides with a device's camera port.
@Suite("Virtual camera", .serialized)
struct RAVEVirtualCameraTests {

    /// Collects what a subscriber hears, across its queue.
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []
        func add(_ event: String) { lock.lock(); _events.append(event); lock.unlock() }
        var events: [String] { lock.lock(); defer { lock.unlock() }; return _events }
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func aSubscriberGetsTheConfigThenFramesFromAKeyframe() async throws {
        let port: UInt16 = 47_515
        let publisher = RAVEVirtualCameraPublisher(port: port)
        let counts = Log()
        let keyframeAsks = Log()
        publisher.onSubscribersChanged = { counts.add("\($0)") }
        publisher.onKeyframeRequested = { keyframeAsks.add("ask") }
        publisher.start()
        // The config arrives before anyone subscribes and must be replayed.
        publisher.publish(config: "hvc1.1.6.L120.B0", record: Data([1, 2, 3]), width: 1280, height: 720)
        try await Task.sleep(for: .milliseconds(100))

        let heard = Log()
        let subscriber = RAVEVirtualCameraSubscriber(port: port)
        subscriber.onConfig = { codec, record, width, height in
            heard.add("config \(codec) \(record.count) \(width)x\(height)")
        }
        subscriber.onFrame = { data, pts, keyframe, _, _ in
            heard.add("frame \(pts) \(keyframe ? "key" : "delta") \(data.count)")
        }
        subscriber.onEnded = { heard.add("ended \($0)") }
        subscriber.start()

        #expect(await waitUntil { counts.events.last == "1" })
        // Joining asks for a keyframe, so a mid-GOP join waits one frame.
        #expect(keyframeAsks.events.count >= 1)

        // A delta before the first keyframe is useless to a new decoder.
        publisher.publish(frame: Data([9]), ptsMicroseconds: 1, keyframe: false, capturedAtMs: 1, encodedAtMs: 2)
        publisher.publish(frame: Data([9, 9]), ptsMicroseconds: 2, keyframe: true, capturedAtMs: 1, encodedAtMs: 2)
        publisher.publish(frame: Data([9]), ptsMicroseconds: 3, keyframe: false, capturedAtMs: 1, encodedAtMs: 2)

        #expect(await waitUntil { heard.events.count >= 3 })
        #expect(heard.events == [
            "config hvc1.1.6.L120.B0 3 1280x720",
            "frame 2 key 2",
            "frame 3 delta 1",
        ])

        // The control direction: a subscriber's request reaches the publisher.
        let before = keyframeAsks.events.count
        subscriber.requestKeyframe()
        #expect(await waitUntil { keyframeAsks.events.count > before })

        // Stopping the publisher is EOF to the subscriber.
        publisher.stop()
        #expect(await waitUntil { heard.events.last?.hasPrefix("ended") == true })
        subscriber.stop()
    }

    @Test func nothingPublishingEndsTheSubscriberPromptly() async throws {
        let heard = Log()
        let subscriber = RAVEVirtualCameraSubscriber(port: 47_516)
        subscriber.onEnded = { heard.add("ended \($0)") }
        let started = Date()
        subscriber.start()
        #expect(await waitUntil(RAVEVirtualCameraSubscriber.connectTimeout + 1) { !heard.events.isEmpty })
        #expect(heard.events.first?.hasPrefix("ended no camera is publishing") == true)
        #expect(Date().timeIntervalSince(started) <= RAVEVirtualCameraSubscriber.connectTimeout + 0.5)
    }

    @Test func leavingIsCounted() async throws {
        let port: UInt16 = 47_517
        let publisher = RAVEVirtualCameraPublisher(port: port)
        let counts = Log()
        publisher.onSubscribersChanged = { counts.add("\($0)") }
        publisher.start()
        try await Task.sleep(for: .milliseconds(100))

        let first = RAVEVirtualCameraSubscriber(port: port)
        let second = RAVEVirtualCameraSubscriber(port: port)
        first.start()
        second.start()
        #expect(await waitUntil { counts.events.last == "2" })
        first.stop()
        #expect(await waitUntil { counts.events.last == "1" })
        second.stop()
        #expect(await waitUntil { counts.events.last == "0" })
        publisher.stop()
    }
}
