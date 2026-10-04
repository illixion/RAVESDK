/*
 RAVESDK - a live multichannel stream as per-channel pull sources

 A producer (a network or decoder thread) pushes interleaved PCM frames as
 they arrive; a sound stage pulls each channel through its own render
 handler, one mono source per channel (`RAVEPhaseStage.addSource`, or a
 RealityKit generator, which has the same handler type). The channels play
 the same instant because each render maps its host time onto one shared
 timeline (`RAVEHostClockAligner`), not because their sample clocks agree
 (they don't; see the aligner).

 The timeline (`RAVEStreamTimeline`) is the policy for a *live* source,
 where nothing schedules a start and the sender's clock is not ours:

 - Prime: nothing plays until `cushion` frames are buffered. The first
   render after that anchors the timeline so the frame `cushion` behind the
   newest one plays now.
 - Run dry: a render that finds the timeline caught up with the producer
   drops back to priming, so a late burst refills a whole cushion instead
   of trickling out one jittery packet at a time (each starvation is a cut
   to silence and back).
 - Run long: past `ceiling` frames buffered (a post-stall burst, or a
   sender clock running fast) the timeline skips forward to `cushion`
   behind the newest frame, so latency returns to the cushion instead of
   staying at the ceiling.

 Added latency: the cushion, and nothing else. Alignment maps each render
 to the frame the host clock says is due and holds no frames of its own;
 the ring buffer only holds what the cushion and a run-long excursion
 need. The render quantum of whatever pulls (PHASE's I/O buffer) must fit
 inside the cushion, or each render reads past the newest frame and the
 tail of every buffer is silence.

 Threads: `push` from one producer thread at a time; render handlers from
 the stage's realtime threads. They meet under one `Mutex` held for a few
 integer operations per call; samples are copied outside it, into and out
 of regions the other side doesn't touch (the ring is `capacity` frames,
 several times the ceiling).
 */

import AudioToolbox
import AVFAudio
import Foundation
import Synchronization

/// Where a live stream's timeline stands. Pure value logic, driven by
/// `RAVEChannelFeed`; exposed for tests.
public struct RAVEStreamTimeline: Sendable, Equatable {
    public struct Anchor: Sendable, Equatable {
        /// Timeline frame due at `hostTime`.
        public var frame: Int64
        public var hostTime: UInt64
    }

    public let cushion: Int64
    public let ceiling: Int64
    /// Frames pushed since creation: the timeline frame one past the newest.
    public private(set) var written: Int64 = 0
    /// nil while priming.
    public private(set) var anchor: Anchor?
    /// Bumped whenever the anchor changes; channels re-derive their offsets.
    public private(set) var generation = 0
    /// First frame of the current priming run.
    private var runStart: Int64 = 0
    /// Renders that found the timeline caught up with the producer.
    public private(set) var underruns = 0
    /// Forward skips taken because the buffer ran past the ceiling.
    public private(set) var skips = 0

    public init(cushion: Int64, ceiling: Int64) {
        precondition(cushion > 0 && ceiling > cushion, "ceiling must exceed the cushion")
        self.cushion = cushion
        self.ceiling = ceiling
    }

    public mutating func didWrite(_ frames: Int) {
        written += Int64(frames)
    }

    /// Back to priming from the newest frame (a route change, a flush).
    public mutating func restart() {
        anchor = nil
        runStart = written
        generation += 1
    }

    /// The anchor a render stamped `hostTime` should play against, after
    /// applying the prime, run-dry and run-long rules; nil = render silence.
    /// `due` maps a host time to a timeline frame against an anchor.
    public mutating func anchorForRender(hostTime: UInt64, due: (Anchor, UInt64) -> Int64) -> Anchor? {
        if anchor == nil {
            guard written - runStart >= cushion else { return nil }
            anchor = Anchor(frame: written - cushion, hostTime: hostTime)
            generation += 1
        }
        guard var current = anchor else { return nil }
        let now = due(current, hostTime)
        if now >= written {
            underruns += 1
            restart()
            return nil
        }
        if written - now > ceiling {
            current.frame += (written - cushion) - now
            anchor = current
            skips += 1
            generation += 1
        }
        return current
    }

    /// Frames buffered ahead of what plays at `hostTime`.
    public func buffered(hostTime: UInt64, due: (Anchor, UInt64) -> Int64) -> Int64 {
        guard let anchor else { return written - runStart }
        return max(0, written - due(anchor, hostTime))
    }
}

/// Live multichannel PCM in, one host-aligned pull render handler per
/// channel out.
// Synchronization.Mutex; the package floor stays at macOS 14.
@available(macOS 15.0, *)
public final class RAVEChannelFeed: @unchecked Sendable {
    public let channelCount: Int
    public let sampleRate: Double
    public let capacity: Int
    public let aligner: RAVEHostClockAligner

    private let timeline: Mutex<RAVEStreamTimeline>
    /// Planar float ring, `capacity` frames per channel.
    private let ring: UnsafeMutablePointer<Float>
    private let fallbackRenderCounter = Atomic<Int>(0)

    /// - Parameters:
    ///   - cushion: seconds buffered before playing, and after running dry.
    ///   - ceiling: seconds buffered past which the timeline skips forward.
    public init(channelCount: Int, sampleRate: Double, cushion: Double = 0.040, ceiling: Double = 0.250,
                reanchorSeconds: Double = 0.05, framesPerTick: Double? = nil) {
        precondition(channelCount > 0)
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        let ceilingFrames = Int64(sampleRate * ceiling)
        timeline = Mutex(RAVEStreamTimeline(cushion: max(1, Int64(sampleRate * cushion)), ceiling: ceilingFrames))
        // A second of audio, and at least four ceilings: the producer must
        // never lap a region a render may still be reading.
        capacity = max(Int(sampleRate), Int(ceilingFrames) * 4)
        ring = .allocate(capacity: capacity * channelCount)
        ring.initialize(repeating: 0, count: capacity * channelCount)
        aligner = RAVEHostClockAligner(channelCount: channelCount, sampleRate: sampleRate,
                                       reanchorSeconds: reanchorSeconds, framesPerTick: framesPerTick)
    }

    deinit { ring.deallocate() }

    // MARK: Producer

    /// Appends `frames` interleaved Int16 frames (`channelCount` per frame).
    public func push(interleaved samples: UnsafePointer<Int16>, frames: Int) {
        write(frames: frames) { frame, ch in Float(samples[frame * self.channelCount + ch]) * (1.0 / 32768.0) }
    }

    /// Appends `frames` interleaved Float frames (`channelCount` per frame).
    public func push(interleaved samples: UnsafePointer<Float>, frames: Int) {
        write(frames: frames) { frame, ch in samples[frame * self.channelCount + ch] }
    }

    @inline(__always)
    private func write(frames: Int, sample: (Int, Int) -> Float) {
        guard frames > 0 else { return }
        // Only the producer advances `written`, so reading it unlocked here
        // and publishing it below can't race another writer.
        let start = timeline.withLock { $0.written }
        // A push longer than the ring keeps only its newest frames.
        let skip = max(0, frames - capacity)
        for f in skip ..< frames {
            let slot = Int((start + Int64(f)) % Int64(capacity))
            for ch in 0 ..< channelCount {
                ring[ch * capacity + slot] = sample(f, ch)
            }
        }
        timeline.withLock { $0.didWrite(frames) }
    }

    /// Drops back to priming from the newest frame.
    public func restart() {
        timeline.withLock { $0.restart() }
        aligner.invalidate()
    }

    // MARK: Telemetry

    public var state: RAVEStreamTimeline { timeline.withLock { $0 } }

    /// Seconds buffered ahead of what is playing now.
    public var bufferedSeconds: Double {
        let now = mach_absolute_time()
        let aligner = aligner
        let frames = timeline.withLock { t in
            t.buffered(hostTime: now) { aligner.timelineFrame(hostTime: $1, anchorFrame: $0.frame, anchorHostTime: $0.hostTime) }
        }
        return Double(frames) / sampleRate
    }

    /// Renders that arrived without a valid sample and host time (silent).
    public var fallbackRenders: Int { fallbackRenderCounter.load(ordering: .relaxed) }

    // MARK: Consumer

    /// The pull render handler for one channel. Built here, in a nonisolated
    /// context, on purpose: a closure written inside a `@MainActor` context
    /// inherits that isolation, and Swift 6 traps on the audio thread's
    /// first call. Same signature as `PHASEPullStreamRenderHandler`,
    /// `AVAudioSourceNodeRenderBlock` and RealityKit's generator handler.
    public func renderHandler(channel: Int)
        -> (UnsafeMutablePointer<ObjCBool>, UnsafePointer<AudioTimeStamp>, AVAudioFrameCount, UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        precondition(channel >= 0 && channel < channelCount)
        return { isSilence, timestamp, frameCount, output in
            self.render(channel: channel, isSilence: isSilence, timestamp: timestamp, frameCount: frameCount, output: output)
        }
    }

    /// Fills `out` with `count` frames of channel `ch` for a render stamped
    /// `sampleTime`/`hostTime`; false if it is all silence. The body of the
    /// render handler, callable directly by tests.
    public func read(channel ch: Int, sampleTime: Int64, hostTime: UInt64, count: Int,
                     into out: UnsafeMutablePointer<Float>) -> Bool {
        let aligner = aligner
        let (anchor, epoch, written) = timeline.withLock { t -> (RAVEStreamTimeline.Anchor?, Int, Int64) in
            let before = t.generation
            let anchor = t.anchorForRender(hostTime: hostTime) {
                aligner.timelineFrame(hostTime: $1, anchorFrame: $0.frame, anchorHostTime: $0.hostTime)
            }
            // Under the lock, so every channel sees the bump with the anchor it belongs to.
            if t.generation != before { aligner.invalidate() }
            return (anchor, aligner.epoch, t.written)
        }
        guard let anchor else {
            out.update(repeating: 0, count: count)
            return false
        }
        let due = aligner.timelineFrame(hostTime: hostTime, anchorFrame: anchor.frame, anchorHostTime: anchor.hostTime)
        let frame = aligner.frame(channel: ch, sampleTime: sampleTime, timelineFrame: due, epoch: epoch)
        let oldest = written - Int64(capacity) + 1
        let base = ring + ch * capacity
        var audible = false
        for i in 0 ..< count {
            let f = frame + Int64(i)
            if f >= written || f < oldest || f < 0 {
                out[i] = 0
            } else {
                out[i] = base[Int(f % Int64(capacity))]
                audible = true
            }
        }
        return audible
    }

    private func render(channel ch: Int, isSilence: UnsafeMutablePointer<ObjCBool>,
                        timestamp: UnsafePointer<AudioTimeStamp>, frameCount: AVAudioFrameCount,
                        output: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        let n = Int(frameCount)
        let flags = timestamp.pointee.mFlags
        guard flags.contains(.sampleTimeValid), flags.contains(.hostTimeValid),
              let out = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else {
            // Without a host time there is no way to stay aligned with the
            // other channels; silence is better than skew.
            for buffer in buffers { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
            isSilence.pointee = true
            fallbackRenderCounter.add(1, ordering: .relaxed)
            return noErr
        }
        let audible = read(channel: ch, sampleTime: Int64(timestamp.pointee.mSampleTime),
                           hostTime: timestamp.pointee.mHostTime, count: n, into: out)
        // Mono source, but copy into any further buffers the node asked for.
        for extra in buffers.dropFirst() {
            guard let dst = extra.mData else { continue }
            memcpy(dst, out, n * MemoryLayout<Float>.size)
        }
        isSilence.pointee = ObjCBool(!audible)
        return noErr
    }
}
