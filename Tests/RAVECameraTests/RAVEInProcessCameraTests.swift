import Foundation
import Testing
@testable import RAVECamera

/// The in-process camera: the publisher's contract without the socket, so
/// these mirror `RAVEVirtualCameraTests` — fan-out, a late joiner's config
/// and keyframe ask, keyframe gating, the subscriber count — and add a
/// concurrent publisher, which is the case the lock exists for.
@Suite("In-process camera", .serialized)
struct RAVEInProcessCameraTests {
    /// Collects events across queues.
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
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func listen(_ feed: any RAVECameraFeed, into log: Log) {
        feed.onDecoderConfiguration = { config, width, height in
            log.add("config \(config.codecString) \(config.record.count) \(width)x\(height)")
        }
        feed.onAccessUnit = { data, pts, keyframe, _, _ in
            log.add("frame \(pts) \(keyframe ? "key" : "delta") \(data.count)")
        }
        feed.onEnded = { log.add("ended \($0)") }
    }

    private func frame(_ camera: RAVEInProcessCamera, _ pts: UInt64, key: Bool, bytes: Int = 4) {
        camera.publish(frame: Data(repeating: 1, count: bytes), ptsMicroseconds: pts, keyframe: key,
                       capturedAtMs: 1, encodedAtMs: 2)
    }

    @Test func aLateJoinerGetsTheConfigAndAsksForAKeyframe() async {
        let camera = RAVEInProcessCamera()
        let counts = Log()
        let asks = Log()
        camera.onSubscribersChanged = { counts.add("\($0)") }
        camera.onKeyframeRequested = { asks.add("ask") }
        camera.start()
        // Published before anyone watched: kept, and replayed to the joiner.
        camera.publish(config: "hvc1.1.6.L120.B0", record: Data([1, 2, 3]), width: 1280, height: 720)
        frame(camera, 0, key: true)

        let heard = Log()
        let feed = camera.makeFeed()
        listen(feed, into: heard)
        feed.start()

        #expect(await waitUntil { counts.events == ["1"] && asks.events.count == 1 })
        #expect(camera.subscriberCount == 1)
        #expect(await waitUntil { heard.events == ["config hvc1.1.6.L120.B0 3 1280x720"] })

        // Mid-GOP: deltas wait for the keyframe the owner was just asked for.
        frame(camera, 33_333, key: false)
        frame(camera, 66_666, key: true, bytes: 8)
        frame(camera, 99_999, key: false)
        #expect(await waitUntil { heard.events.count == 3 })
        #expect(heard.events.dropFirst() == ["frame 66666 key 8", "frame 99999 delta 4"])

        feed.stop()
        #expect(await waitUntil { counts.events == ["1", "0"] })
        #expect(camera.subscriberCount == 0)
        #expect(!heard.events.contains { $0.hasPrefix("ended") }, "stop() does not fire onEnded")
        camera.stop()
    }

    /// Every tab on a call subscribes on its own, and each gets the stream.
    @Test func fansOutToEverySubscriber() async {
        let camera = RAVEInProcessCamera()
        let counts = Log()
        camera.onSubscribersChanged = { counts.add("\($0)") }
        camera.start()
        camera.publish(config: "hvc1", record: Data([9]), width: 640, height: 360)

        let logs = [Log(), Log(), Log()]
        let feeds = logs.map { log -> any RAVECameraFeed in
            let feed = camera.makeFeed()
            listen(feed, into: log)
            feed.start()
            return feed
        }
        #expect(await waitUntil { counts.events.last == "3" })
        #expect(camera.subscriberCount == 3)

        for index in 0..<30 { frame(camera, UInt64(index) * 33_333, key: index % 10 == 0) }
        for log in logs {
            #expect(await waitUntil { log.events.count == 31 })
            #expect(log.events.first == "config hvc1 1 640x360")
            #expect(log.events[1] == "frame 0 key 4")
        }

        // A configuration change reaches everyone, and each waits for its
        // first keyframe again.
        camera.publish(config: "hvc2", record: Data([1, 1]), width: 1920, height: 1080)
        frame(camera, 1_000_000, key: false)
        frame(camera, 1_033_333, key: true)
        for log in logs {
            #expect(await waitUntil { log.events.count == 33 })
            #expect(log.events.suffix(2) == ["config hvc2 2 1920x1080", "frame 1033333 key 4"])
        }
        feeds.forEach { $0.stop() }
        camera.stop()
    }

    /// A feed that asks for a keyframe (the relay dropped) waits for it, and
    /// the owner is asked.
    @Test func aFeedsOwnKeyframeRequestGatesItsDeltas() async {
        let camera = RAVEInProcessCamera()
        let asks = Log()
        camera.onKeyframeRequested = { asks.add("ask") }
        camera.start()
        camera.publish(config: "hvc1", record: Data([1]), width: 2, height: 2)
        let heard = Log()
        let feed = camera.makeFeed()
        listen(feed, into: heard)
        feed.start()
        frame(camera, 0, key: true)
        #expect(await waitUntil { heard.events.count == 2 && asks.events.count == 1 })

        feed.requestKeyframe()
        frame(camera, 33_333, key: false)
        frame(camera, 66_666, key: true)
        #expect(await waitUntil { heard.events.count == 3 && asks.events.count == 2 })
        #expect(heard.events.last == "frame 66666 key 4")
        feed.stop()
        camera.stop()
    }

    /// The proxy's outage path: nothing publishing ends a feed at once, and
    /// stopping the camera ends every feed — once, as a feed's ending is.
    @Test func feedsEndWhenNothingIsPublishing() async {
        let camera = RAVEInProcessCamera()
        let early = Log()
        let before = camera.makeFeed()
        listen(before, into: early)
        before.start()
        #expect(await waitUntil { early.events == ["ended no camera is publishing"] })

        camera.start()
        let heard = Log()
        let feed = camera.makeFeed()
        listen(feed, into: heard)
        feed.start()
        #expect(await waitUntil { camera.subscriberCount == 1 })
        camera.stop()
        #expect(await waitUntil { heard.events == ["ended the camera stopped publishing"] })
        #expect(camera.subscriberCount == 0)
        frame(camera, 0, key: true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(heard.events.count == 1, "nothing after the ending")
    }

    /// The encoder publishes from its own thread while tabs come and go on
    /// others. Every feed's stream stays in publish order: config first, then
    /// frames with increasing timestamps, from a keyframe.
    @Test func concurrentPublishingKeepsEachStreamInOrder() async {
        let camera = RAVEInProcessCamera()
        camera.start()
        camera.publish(config: "hvc1", record: Data([1]), width: 2, height: 2)
        let encoder = DispatchQueue(label: "test.encoder")
        let done = Log()
        encoder.async {
            for index in 0..<600 {
                camera.publish(frame: Data([UInt8(index % 255)]), ptsMicroseconds: UInt64(index),
                               keyframe: index % 30 == 0, capturedAtMs: 0, encodedAtMs: 0)
            }
            done.add("done")
        }
        let logs = (0..<6).map { _ in Log() }
        await withTaskGroup(of: Void.self) { group in
            for log in logs {
                group.addTask {
                    let feed = camera.makeFeed()
                    feed.onDecoderConfiguration = { _, _, _ in log.add("config") }
                    feed.onAccessUnit = { _, pts, key, _, _ in log.add("\(key ? "K" : "d")\(pts)") }
                    feed.start()
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 0...20)))
                    feed.requestKeyframe()
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 0...20)))
                    feed.stop()
                }
            }
        }
        #expect(await waitUntil { done.events == ["done"] })
        for log in logs {
            let events = log.events
            guard let first = events.first else { continue }
            #expect(first == "config")
            let stamps = events.dropFirst().compactMap { UInt64($0.dropFirst()) }
            #expect(stamps == stamps.sorted(), "frames out of order")
            #expect(events.dropFirst().first.map { $0.hasPrefix("K") } ?? true, "joined on a delta")
        }
        #expect(camera.subscriberCount == 0)
        camera.stop()
    }
}
