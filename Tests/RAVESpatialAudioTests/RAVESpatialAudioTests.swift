import Foundation
import simd
import Testing
@testable import RAVESpatialAudio

@Suite struct SpeakerLayoutTests {
    @Test func picksTheLayoutByChannelCount() {
        #expect(RAVESpeakerLayout(channelCount: 2) == .stereo)
        #expect(RAVESpeakerLayout(channelCount: 6) == .surround51)
        #expect(RAVESpeakerLayout(channelCount: 8) == .surround71)
        #expect(RAVESpeakerLayout(channelCount: 4) == nil)
        for layout in RAVESpeakerLayout.allCases {
            #expect(layout.speakers.map(\.channel) == Array(0 ..< layout.channelCount))
        }
    }

    @Test func followsWaveChannelOrder() {
        #expect(RAVESpeakerLayout.surround51.speakers.map(\.label) == ["FL", "FR", "FC", "LFE", "BL", "BR"])
        #expect(RAVESpeakerLayout.surround71.speakers.map(\.label) == ["FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR"])
        let lfe = RAVESpeakerLayout.surround71.speakers.filter(\.isLFE)
        #expect(lfe.map(\.channel) == [3])
        #expect(lfe.first?.position(distance: 2) == nil)
    }

    @Test func placesSpeakersAroundTheListener() throws {
        let speakers = RAVESpeakerLayout.surround71.speakers
        func position(_ label: String) throws -> SIMD3<Float> {
            try #require(speakers.first { $0.label == label }?.position(distance: 2))
        }
        // −z forward, +x right.
        let centre = try position("FC")
        #expect(abs(centre.x) < 1e-5 && abs(centre.z + 2) < 1e-5)
        let left = try position("FL"), right = try position("FR")
        #expect(left.x < 0 && right.x > 0 && left.z < 0 && abs(left.x + right.x) < 1e-5)
        // Sides are abeam, backs behind.
        let side = try position("SR")
        #expect(abs(side.x - 2) < 1e-5 && abs(side.z) < 1e-5)
        let back = try position("BL")
        #expect(back.x < 0 && back.z > 0)
        for speaker in speakers where !speaker.isLFE {
            let p = try #require(speaker.position(distance: 2))
            #expect(abs(simd_length(p) - 2) < 1e-5 && p.y == 0)
        }
        // 5.1's surrounds sit at ±110°, ahead of 7.1's backs.
        let surround = try #require(RAVESpeakerLayout.surround51.speakers[4].position(distance: 2))
        #expect(surround.z > 0 && surround.z < back.z)
    }
}

/// One host tick is one frame in these, so host times read as frames.
/// The types need macOS 15 (Synchronization); the package floor is 14 and
/// Swift Testing won't take an `@available` test, hence the guards.
@Suite struct HostClockAlignerTests {
    @available(macOS 15.0, *)
    func aligner() -> RAVEHostClockAligner {
        RAVEHostClockAligner(channelCount: 2, sampleRate: 1000, reanchorSeconds: 0.05, framesPerTick: 1)
    }

    @Test func alignsChannelsWithDifferentSampleOrigins() {
        guard #available(macOS 15.0, *) else { return }
        let a = aligner()
        // Same host time, sample timelines 37 frames apart.
        let due = a.timelineFrame(hostTime: 10_000, anchorFrame: 500, anchorHostTime: 10_000)
        #expect(a.frame(channel: 0, sampleTime: 0, timelineFrame: due) == 500)
        #expect(a.frame(channel: 1, sampleTime: 37, timelineFrame: due) == 500)
        // Sample-continuous afterwards, whatever the host time jitters by.
        let later = a.timelineFrame(hostTime: 10_256 + 3, anchorFrame: 500, anchorHostTime: 10_000)
        #expect(a.frame(channel: 0, sampleTime: 256, timelineFrame: later) == 756)
        #expect(a.frame(channel: 1, sampleTime: 37 + 256, timelineFrame: later) == 756)
        #expect(a.maxDrift == 3 && a.reanchors == 0)
    }

    @Test func reanchorsAfterAStall() {
        guard #available(macOS 15.0, *) else { return }
        let a = aligner()
        _ = a.frame(channel: 0, sampleTime: 0, timelineFrame: 0)
        // The renderer stalled: 512 frames of host time, 0 of sample time.
        #expect(a.frame(channel: 0, sampleTime: 256, timelineFrame: 768) == 768)
        #expect(a.reanchors == 1)
        // Continuous again from the new offset.
        #expect(a.frame(channel: 0, sampleTime: 512, timelineFrame: 1024) == 1024)
        #expect(a.reanchors == 1)
    }

    @Test func invalidateRederivesOffsets() {
        guard #available(macOS 15.0, *) else { return }
        let a = aligner()
        _ = a.frame(channel: 0, sampleTime: 0, timelineFrame: 100)
        a.invalidate()
        // A new anchor 30 frames away (inside the re-anchor threshold) is
        // still taken, because the epoch changed.
        #expect(a.frame(channel: 0, sampleTime: 10, timelineFrame: 140) == 140)
        #expect(a.reanchors == 0)
    }

    @Test func fallbackContinuesFromTheReset() {
        guard #available(macOS 15.0, *) else { return }
        let a = aligner()
        a.reset(fallbackFrame: 1000)
        #expect(a.fallbackFrame(channel: 1, count: 256) == 1000)
        #expect(a.fallbackFrame(channel: 1, count: 256) == 1256)
        #expect(a.fallbackFrame(channel: 0, count: 256) == 1000)
    }
}

@Suite struct StreamTimelineTests {
    let due: (RAVEStreamTimeline.Anchor, UInt64) -> Int64 = { anchor, host in
        anchor.frame + Int64(host) - Int64(anchor.hostTime)
    }

    @Test func primesBeforePlaying() {
        var t = RAVEStreamTimeline(cushion: 40, ceiling: 250)
        t.didWrite(30)
        #expect(t.anchorForRender(hostTime: 1000, due: due) == nil)
        t.didWrite(30)
        // The frame a cushion behind the newest plays now.
        #expect(t.anchorForRender(hostTime: 1010, due: due) == .init(frame: 20, hostTime: 1010))
        #expect(t.anchorForRender(hostTime: 1020, due: due)?.frame == 20)
    }

    @Test func runningDryReprimes() {
        var t = RAVEStreamTimeline(cushion: 40, ceiling: 250)
        t.didWrite(40)
        _ = t.anchorForRender(hostTime: 0, due: due)
        // 40 frames of host time later the timeline reaches the newest frame.
        #expect(t.anchorForRender(hostTime: 40, due: due) == nil)
        #expect(t.underruns == 1 && t.anchor == nil)
        // A late packet isn't enough; a whole cushion is.
        t.didWrite(10)
        #expect(t.anchorForRender(hostTime: 50, due: due) == nil)
        t.didWrite(30)
        #expect(t.anchorForRender(hostTime: 60, due: due) == .init(frame: 40, hostTime: 60))
    }

    @Test func runningLongSkipsBackToTheCushion() {
        var t = RAVEStreamTimeline(cushion: 40, ceiling: 250)
        t.didWrite(40)
        _ = t.anchorForRender(hostTime: 0, due: due)
        // A burst: 300 frames buffered.
        t.didWrite(300)
        let generation = t.generation
        let anchor = t.anchorForRender(hostTime: 0, due: due)
        #expect(t.skips == 1 && t.generation == generation + 1)
        #expect(anchor.map { due($0, 0) } == 300)
        #expect(t.buffered(hostTime: 0, due: due) == 40)
    }

    @Test func restartPrimesFromTheNewestFrame() {
        var t = RAVEStreamTimeline(cushion: 40, ceiling: 250)
        t.didWrite(100)
        _ = t.anchorForRender(hostTime: 0, due: due)
        t.restart()
        #expect(t.anchorForRender(hostTime: 5, due: due) == nil)
        t.didWrite(40)
        #expect(t.anchorForRender(hostTime: 5, due: due)?.frame == 100)
    }
}

@Suite struct ChannelFeedTests {
    /// Channel c of frame f carries f + 10_000·c, so a read names its frame.
    @available(macOS 15.0, *)
    func push(_ feed: RAVEChannelFeed, from start: Int, count: Int) {
        var samples = [Float]()
        for f in start ..< start + count {
            for c in 0 ..< feed.channelCount { samples.append(Float(f + 10_000 * c)) }
        }
        samples.withUnsafeBufferPointer { feed.push(interleaved: $0.baseAddress!, frames: count) }
    }

    @available(macOS 15.0, *)
    func read(_ feed: RAVEChannelFeed, channel: Int, sampleTime: Int64, hostTime: UInt64, count: Int) -> [Float] {
        var out = [Float](repeating: -1, count: count)
        _ = out.withUnsafeMutableBufferPointer {
            feed.read(channel: channel, sampleTime: sampleTime, hostTime: hostTime, count: count, into: $0.baseAddress!)
        }
        return out
    }

    @Test func channelsPlayTheSameFrameWhateverTheirSampleClocks() {
        guard #available(macOS 15.0, *) else { return }
        let feed = RAVEChannelFeed(channelCount: 2, sampleRate: 1000, cushion: 0.040, ceiling: 0.250, framesPerTick: 1)
        push(feed, from: 0, count: 100)
        let left = read(feed, channel: 0, sampleTime: 5_000, hostTime: 777, count: 8)
        let right = read(feed, channel: 1, sampleTime: 91, hostTime: 777, count: 8)
        #expect(left == (60 ..< 68).map(Float.init))
        #expect(right == (60 ..< 68).map { Float($0 + 10_000) })
        // The next buffer continues on each channel's own sample clock.
        #expect(read(feed, channel: 1, sampleTime: 99, hostTime: 785, count: 4) == (68 ..< 72).map { Float($0 + 10_000) })
    }

    @Test func silentWhilePrimingAndAfterRunningDry() {
        guard #available(macOS 15.0, *) else { return }
        let feed = RAVEChannelFeed(channelCount: 1, sampleRate: 1000, cushion: 0.040, ceiling: 0.250, framesPerTick: 1)
        push(feed, from: 0, count: 20)
        #expect(read(feed, channel: 0, sampleTime: 0, hostTime: 0, count: 4) == [0, 0, 0, 0])
        push(feed, from: 20, count: 20)
        #expect(read(feed, channel: 0, sampleTime: 4, hostTime: 4, count: 4) == [0, 1, 2, 3])
        // The tail past the newest frame is silence, then the feed reprimes.
        #expect(read(feed, channel: 0, sampleTime: 40, hostTime: 40, count: 4) == [36, 37, 38, 39])
        #expect(read(feed, channel: 0, sampleTime: 44, hostTime: 44, count: 4) == [0, 0, 0, 0])
        #expect(feed.state.underruns == 1)
    }

    @Test func int16SamplesAreScaled() {
        guard #available(macOS 15.0, *) else { return }
        let feed = RAVEChannelFeed(channelCount: 1, sampleRate: 1000, cushion: 0.004, ceiling: 0.250, framesPerTick: 1)
        let samples: [Int16] = [16384, -32768, 0, 8192]
        samples.withUnsafeBufferPointer { feed.push(interleaved: $0.baseAddress!, frames: 4) }
        #expect(read(feed, channel: 0, sampleTime: 0, hostTime: 0, count: 4) == [0.5, -1, 0, 0.25])
    }
}
