/*
 RAVEFilm - a room of our own for the RealityKit stage

 visionOS reverberates every RealityKit spatial source with a simulation of
 the wearer's real room, and a window can't change that: `ReverbComponent`
 is honoured only while the app has a `progressive` or `full` immersive
 space open (Apple's ReverbComponent docs; a Shared Space window or a
 `mixed` space uses the simulation). So the sound of a film in a window is
 the sound of the room the wearer sits in, and whether it reads enclosed
 or open is decided by the system, not the film.

 This is the room the stage can choose instead. With
 `FilmPlayer.roomSource == .virtual`, `FilmStageView` turns each object's
 send to the system's simulation off, so the objects arrive dry, and plays
 this reverb's four outputs as four more sources placed around the
 listener (two front, two rear, raised), themselves dry. Late reverb is
 diffuse, so four decorrelated outputs are enough to surround the listener;
 the room stays where it is when the head turns, as the objects do.

 The DSP: the mix of every element (gains as the render side applies them,
 LFE left out: a reverberant LFE is mud) → pre-delay → early reflections
 (five taps per output, different per output) and two allpass diffusers →
 an eight-line feedback delay network with a Householder mix and a one-pole
 damping filter in each loop, decay set per line from the preset's RT60.
 The four outputs read the lines through four rows of an 8×8 Hadamard
 matrix, so they are mutually uncorrelated. The presets are the same names
 PHASE offers on tvOS (`RAVEReverbPreset`), tuned by ear rather than to
 match PHASE.

 Timing: the PCM is random access by scene frame (`AtmosObjectAudio`'s
 slots), so the reverb reads the frames the dry objects play without
 disturbing them. Each output is its own generator on its own sample
 timeline, aligned by host time the way the dry channels are, but the tank
 runs once: whichever output asks for frames the tank hasn't reached
 computes them into a ring, and the others read the ring. A restart (seek,
 pause, a new anchor) bumps the audio's alignment epoch, which empties the
 tank, so a tail never rings on from where the film was before a seek.
 */

import AVFoundation
import Foundation
import RAVESpatialAudio
import RealityKit
import Synchronization

/// Where a RealityKit stage's room acoustics come from.
public enum FilmRoomSource: String, Codable, CaseIterable, Sendable {
    /// The system's. On visionOS that is the simulation of the wearer's
    /// real room; `FilmPlayer.reverbDB` is each object's send to it.
    case system
    /// `FilmRoomReverb`: the objects play dry and the stage adds the room
    /// named by `FilmPlayer.reverbPreset`, `reverbDB` loud.
    case virtual
}

// Synchronization; the package floor stays at macOS 14.
@available(macOS 15.0, *)
public final class FilmRoomReverb: @unchecked Sendable {
    public static let outputCount = 4
    /// Where each output plays, in DAMF room coordinates (x −1 left…+1
    /// right, y −1 back…+1 front, z 0 ears…1 ceiling).
    public static let outputPositions: [SIMD3<Float>] = [
        SIMD3(-0.8, 0.6, 0.6), SIMD3(0.8, 0.6, 0.6),
        SIMD3(-0.9, -0.8, 0.6), SIMD3(0.9, -0.8, 0.6),
    ]

    let audio: AtmosObjectAudio
    private let aligner: RAVEHostClockAligner
    /// Channels that feed the room (everything but the LFE).
    private let inputChannels: [Int]
    /// Linear output gain as Float bits; 0 when the room is off.
    private let level = Atomic<UInt32>(0)
    /// The tank and the scratch buffers its callers fill, only touched under the lock.
    private let tank: Mutex<FilmReverbTank?>
    private let input: UnsafeMutablePointer<Float>
    private let gains: UnsafeMutablePointer<Float>
    private let appliedLevel: UnsafeMutablePointer<Float>
    private static let chunk = 512
    /// Main actor only: what `setRoom` last built, to skip rebuilding.
    private var preset: RAVEReverbPreset?

    public init(audio: AtmosObjectAudio, elements: [AtmosScene.Element]) {
        self.audio = audio
        aligner = RAVEHostClockAligner(channelCount: Self.outputCount, sampleRate: audio.sampleRate,
                                       reanchorSeconds: 0.05)
        inputChannels = elements
            .filter { !($0.isBed && ($0.bedChannel?.uppercased().hasPrefix("LFE") ?? false)) }
            .map(\.channel)
            .filter { $0 < audio.channelCount }
        tank = Mutex(nil)
        input = .allocate(capacity: Self.chunk)
        input.initialize(repeating: 0, count: Self.chunk)
        gains = .allocate(capacity: max(1, audio.channelCount))
        gains.initialize(repeating: 0, count: max(1, audio.channelCount))
        appliedLevel = .allocate(capacity: Self.outputCount)
        appliedLevel.initialize(repeating: 0, count: Self.outputCount)
    }

    deinit {
        input.deallocate()
        gains.deallocate()
        appliedLevel.deallocate()
    }

    /// The room to play. `.none` silences the outputs (a dry, open sound).
    /// Rebuilding the tank empties it, so call this on a change only.
    @MainActor
    public func setRoom(_ preset: RAVEReverbPreset) {
        guard preset != self.preset else { return }
        self.preset = preset
        let built = FilmReverbTank.Room(preset).map { FilmReverbTank(room: $0, sampleRate: audio.sampleRate) }
        tank.withLock { $0 = built }
    }

    /// Output gain, linear; 0 is off.
    public func setLevel(_ linear: Float) {
        level.store(max(0, linear).bitPattern, ordering: .relaxed)
    }

    /// The generator callback for output `output` (0..<outputCount). Built
    /// here, nonisolated, for the reason `AtmosObjectAudio.renderHandler`
    /// gives.
    public func renderHandler(output: Int) -> Audio.GeneratorRenderHandler {
        { isSilence, timestamp, frameCount, buffers in
            self.render(output: output, isSilence: isSilence, timestamp: timestamp,
                        frameCount: frameCount, output: buffers)
        }
    }

    func render(
        output o: Int,
        isSilence: UnsafeMutablePointer<ObjCBool>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount count: AVAudioFrameCount,
        output: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        let n = Int(count)
        let target = Float(bitPattern: level.load(ordering: .relaxed))
        guard let out = buffers.first?.mData?.assumingMemoryBound(to: Float.self),
              audio.playing.load(ordering: .relaxed), target > 0 || appliedLevel[o] > 0 else {
            for buffer in buffers { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
            appliedLevel[o] = 0
            isSilence.pointee = true
            return noErr
        }

        let epoch = audio.alignment.epoch
        let frame: Int
        let flags = timestamp.pointee.mFlags
        if flags.contains(.sampleTimeValid), flags.contains(.hostTimeValid) {
            let start = audio.startFrame.load(ordering: .relaxed)
            let anchor = audio.resolvedAnchor(hostTime: timestamp.pointee.mHostTime)
            let due = aligner.timelineFrame(hostTime: timestamp.pointee.mHostTime,
                                            anchorFrame: Int64(start), anchorHostTime: anchor)
            frame = Int(aligner.frame(channel: o, sampleTime: Int64(timestamp.pointee.mSampleTime),
                                      timelineFrame: due, epoch: epoch))
        } else {
            frame = audio.playhead.load(ordering: .relaxed)
        }

        let rendered = tank.withLock { tank -> Bool in
            guard let tank else { return false }
            tank.advance(from: frame, to: frame + n, epoch: epoch) { first, frames, into in
                mixInput(from: first, count: frames, into: into)
            }
            tank.read(output: o, from: frame, count: n, into: out)
            return true
        }
        guard rendered else {
            for buffer in buffers { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
            appliedLevel[o] = 0
            isSilence.pointee = true
            return noErr
        }

        // Ramp the level across the buffer so a change doesn't click.
        var gain = appliedLevel[o]
        let step = (target - gain) / Float(max(n, 1))
        for i in 0 ..< n {
            gain += step
            out[i] *= gain
        }
        appliedLevel[o] = target
        for extra in buffers.dropFirst() {
            guard let dst = extra.mData else { continue }
            memcpy(dst, out, n * MemoryLayout<Float>.size)
        }
        isSilence.pointee = false
        return noErr
    }

    /// The room's input for `count` frames from scene frame `first`: every
    /// feeding element at the gain the render side applies to it.
    /// Called under the tank's lock (it owns `gains`).
    private func mixInput(from first: Int, count: Int, into buffer: UnsafeMutablePointer<Float>) {
        for ch in inputChannels { gains[ch] = audio.targetGain[ch] }
        let start = audio.startFrame.load(ordering: .relaxed)
        let total = audio.frameCount
        let stride = audio.channelCount
        let segmentFrames = audio.segmentFrames
        let scale: Float = 1.0 / 32768.0
        var cachedSegment = -1
        var cached: UnsafePointer<Int16>?
        for i in 0 ..< count {
            let f = first + i
            buffer[i] = 0
            guard f >= start, f < total else { continue }
            let segment = f / segmentFrames
            if segment != cachedSegment {
                cachedSegment = segment
                cached = audio.samples(forSegment: segment)
            }
            guard let cached else { continue }
            let base = (f - segment * segmentFrames) * stride
            var sum: Float = 0
            for ch in inputChannels { sum += Float(cached[base + ch]) * gains[ch] }
            buffer[i] = sum * scale
        }
    }

    /// Test hook: renders `count` frames of output `o` from scene frame
    /// `frame`, as a timestamp-less render at that frame would.
    func renderForTesting(output o: Int, frame: Int, count: Int, into out: UnsafeMutablePointer<Float>) {
        let epoch = audio.alignment.epoch
        let target = Float(bitPattern: level.load(ordering: .relaxed))
        tank.withLock { tank in
            guard let tank else {
                out.initialize(repeating: 0, count: count)
                return
            }
            tank.advance(from: frame, to: frame + count, epoch: epoch) { first, frames, into in
                mixInput(from: first, count: frames, into: into)
            }
            tank.read(output: o, from: frame, count: count, into: out)
        }
        for i in 0 ..< count { out[i] *= target }
    }
}

// MARK: - The tank

/// The reverb's state. Not thread-safe: `FilmRoomReverb` holds it under a lock.
@available(macOS 15.0, *)
final class FilmReverbTank: @unchecked Sendable {
    struct Room {
        /// Seconds for the late tail to fall 60 dB.
        var rt60: Double
        /// Scales the delay lines and reflection times; 1 is a medium room.
        var size: Double
        var preDelayMs: Double
        /// Where the loop's damping filter starts rolling off.
        var dampingHz: Double
        /// Early reflections against the late tail, linear.
        var early: Float
        /// Overall level, linear: with the output at 0 dB, a room's
        /// steady-state reverb sits about 10 dB under the dry mix and a
        /// cathedral's about 6 (FilmRoomReverbTests measures it).
        var level: Float

        init?(_ preset: RAVEReverbPreset) {
            switch preset {
            case .none: return nil
            case .smallRoom: self.init(rt60: 0.35, size: 0.6, preDelayMs: 3, dampingHz: 7000, early: 0.9, level: 0.29)
            case .mediumRoom: self.init(rt60: 0.6, size: 1.0, preDelayMs: 8, dampingHz: 6500, early: 0.75, level: 0.35)
            case .largeRoom: self.init(rt60: 0.9, size: 1.4, preDelayMs: 14, dampingHz: 6000, early: 0.65, level: 0.42)
            case .mediumChamber: self.init(rt60: 1.2, size: 1.1, preDelayMs: 10, dampingHz: 7500, early: 0.55, level: 0.47)
            case .largeChamber: self.init(rt60: 1.6, size: 1.5, preDelayMs: 16, dampingHz: 7000, early: 0.5, level: 0.48)
            case .mediumHall: self.init(rt60: 1.8, size: 1.8, preDelayMs: 20, dampingHz: 5500, early: 0.42, level: 0.57)
            case .largeHall: self.init(rt60: 2.4, size: 2.3, preDelayMs: 28, dampingHz: 5000, early: 0.38, level: 0.59)
            case .cathedral: self.init(rt60: 4.0, size: 3.0, preDelayMs: 40, dampingHz: 4000, early: 0.3, level: 0.75)
            }
        }

        init(rt60: Double, size: Double, preDelayMs: Double, dampingHz: Double, early: Float, level: Float) {
            self.rt60 = rt60
            self.size = size
            self.preDelayMs = preDelayMs
            self.dampingHz = dampingHz
            self.early = early
            self.level = level
        }
    }

    static let lineCount = 8
    static let outputCount = FilmRoomReverb.outputCount
    static let tapCount = 5
    static let ringSize = 16384
    static let preSize = 16384
    /// A request this far past the tank's end is a jump, not a continuation.
    static let maxGap = 4096
    /// Line lengths for a medium room at 48 kHz: mutually prime, 23–48 ms.
    static let baseLines: [Double] = [1123, 1291, 1447, 1601, 1777, 1951, 2111, 2297]
    /// Reflection times for a medium room, ms after the pre-delay.
    static let baseTapsMs: [Double] = [4.3, 9.1, 14.7, 21.3, 29.9]
    static let allpassLengths: [Double] = [142, 379]
    static let allpassGain: Float = 0.6
    /// Rows 1–4 of the 8×8 Sylvester Hadamard matrix: orthogonal, so the
    /// outputs are uncorrelated.
    static let signs: [Float] = [
        1, -1, 1, -1, 1, -1, 1, -1,
        1, 1, -1, -1, 1, 1, -1, -1,
        1, -1, -1, 1, 1, -1, -1, 1,
        1, 1, 1, 1, -1, -1, -1, -1,
    ]

    /// First frame the ring holds output for, and one past the last.
    private(set) var validFrom = 0
    private(set) var computedUntil = 0
    private var epoch = -1

    private let ring: UnsafeMutablePointer<Float>
    private let pre: UnsafeMutablePointer<Float>
    private var preIndex = 0
    private let preDelay: Int
    private let taps: UnsafeMutablePointer<Int>
    private let tapGains: UnsafeMutablePointer<Float>
    private let allpass: UnsafeMutablePointer<Float>
    private let allpassOffsets: UnsafeMutablePointer<Int>
    private let allpassLength: UnsafeMutablePointer<Int>
    private let allpassIndex: UnsafeMutablePointer<Int>
    private let lines: UnsafeMutablePointer<Float>
    private let lineOffsets: UnsafeMutablePointer<Int>
    private let lineLength: UnsafeMutablePointer<Int>
    private let lineIndex: UnsafeMutablePointer<Int>
    private let feedback: UnsafeMutablePointer<Float>
    private let lowpass: UnsafeMutablePointer<Float>
    private let lineOut: UnsafeMutablePointer<Float>
    private let looped: UnsafeMutablePointer<Float>
    private let signs: UnsafeMutablePointer<Float>
    private let damping: Float
    private let inputGain: Float
    private let lateGain: Float
    private let earlyGain: Float
    private let input: UnsafeMutablePointer<Float>
    private let lineTotal: Int
    private let allpassTotal: Int

    init(room: Room, sampleRate: Double) {
        let rate = sampleRate / 48000
        ring = .allocate(capacity: Self.outputCount * Self.ringSize)
        pre = .allocate(capacity: Self.preSize)
        preDelay = min(Self.preSize / 2, Int(room.preDelayMs / 1000 * sampleRate))

        taps = .allocate(capacity: Self.outputCount * Self.tapCount)
        tapGains = .allocate(capacity: Self.tapCount)
        for o in 0 ..< Self.outputCount {
            // Each output hears the walls at slightly different times.
            let spread = 1 + 0.11 * Double(o)
            for t in 0 ..< Self.tapCount {
                let ms = Self.baseTapsMs[t] * room.size * spread
                taps[o * Self.tapCount + t] = min(Self.preSize - 1, preDelay + max(1, Int(ms / 1000 * sampleRate)))
            }
        }
        for t in 0 ..< Self.tapCount {
            // Later reflections are quieter; alternate signs keep them from summing to a click.
            tapGains[t] = powf(0.78, Float(t)) * (t.isMultiple(of: 2) ? 1 : -1)
        }

        allpassOffsets = .allocate(capacity: Self.allpassLengths.count)
        allpassLength = .allocate(capacity: Self.allpassLengths.count)
        allpassIndex = .allocate(capacity: Self.allpassLengths.count)
        var apTotal = 0
        for (k, base) in Self.allpassLengths.enumerated() {
            allpassOffsets[k] = apTotal
            allpassLength[k] = max(8, Int(base * rate))
            allpassIndex[k] = 0
            apTotal += allpassLength[k]
        }
        allpassTotal = apTotal
        allpass = .allocate(capacity: apTotal)

        lineOffsets = .allocate(capacity: Self.lineCount)
        lineLength = .allocate(capacity: Self.lineCount)
        lineIndex = .allocate(capacity: Self.lineCount)
        feedback = .allocate(capacity: Self.lineCount)
        var total = 0
        var gainSquares = 0.0
        for k in 0 ..< Self.lineCount {
            let length = max(64, Int(Self.baseLines[k] * room.size * rate))
            lineOffsets[k] = total
            lineLength[k] = length
            lineIndex[k] = 0
            // −60 dB after rt60 seconds of round trips through this line.
            let g = pow(10, -3 * Double(length) / (room.rt60 * sampleRate))
            feedback[k] = Float(g)
            gainSquares += g * g
            total += length
        }
        lineTotal = total
        lines = .allocate(capacity: total)
        lowpass = .allocate(capacity: Self.lineCount)
        lineOut = .allocate(capacity: Self.lineCount)
        looped = .allocate(capacity: Self.lineCount)
        signs = .allocate(capacity: Self.signs.count)
        signs.initialize(from: Self.signs, count: Self.signs.count)
        input = .allocate(capacity: 512)

        damping = Float(exp(-2 * Double.pi * room.dampingHz / sampleRate))
        // Inject less into a longer tail, so a hall isn't louder than a room
        // just for ringing longer: its steady state sums to about the input's energy.
        let meanSquare = gainSquares / Double(Self.lineCount)
        inputGain = Float(sqrt(max(0.01, 1 - meanSquare)))
        lateGain = room.level / Float(Double(Self.lineCount).squareRoot())
        earlyGain = room.early * room.level * 0.5
        clear()
    }

    deinit {
        ring.deallocate()
        pre.deallocate()
        taps.deallocate()
        tapGains.deallocate()
        allpass.deallocate()
        allpassOffsets.deallocate()
        allpassLength.deallocate()
        allpassIndex.deallocate()
        lines.deallocate()
        lineOffsets.deallocate()
        lineLength.deallocate()
        lineIndex.deallocate()
        feedback.deallocate()
        lowpass.deallocate()
        lineOut.deallocate()
        looped.deallocate()
        signs.deallocate()
        input.deallocate()
    }

    private func clear() {
        ring.initialize(repeating: 0, count: Self.outputCount * Self.ringSize)
        pre.initialize(repeating: 0, count: Self.preSize)
        allpass.initialize(repeating: 0, count: allpassTotal)
        lines.initialize(repeating: 0, count: lineTotal)
        lowpass.initialize(repeating: 0, count: Self.lineCount)
        lineOut.initialize(repeating: 0, count: Self.lineCount)
        looped.initialize(repeating: 0, count: Self.lineCount)
        for k in 0 ..< Self.lineCount { lineIndex[k] = 0 }
        for k in 0 ..< Self.allpassLengths.count { allpassIndex[k] = 0 }
        preIndex = 0
    }

    /// Computes output up to scene frame `end` for a request starting at
    /// `first`, filling the input from `mix(first, count, buffer)`. Starts
    /// empty at `first` after a restart (a new `epoch`) or a jump.
    func advance(from first: Int, to end: Int, epoch: Int,
                 mix: (Int, Int, UnsafeMutablePointer<Float>) -> Void) {
        if epoch != self.epoch || first > computedUntil + Self.maxGap || end < computedUntil - Self.ringSize / 2 {
            clear()
            self.epoch = epoch
            validFrom = first
            computedUntil = first
        }
        while computedUntil < end {
            let count = min(512, end - computedUntil)
            mix(computedUntil, count, input)
            process(count: count)
        }
    }

    /// Output `o` for `count` frames from `first`; silence where the ring
    /// holds nothing for a frame.
    func read(output o: Int, from first: Int, count: Int, into out: UnsafeMutablePointer<Float>) {
        let oldest = max(validFrom, computedUntil - Self.ringSize)
        let base = ring + o * Self.ringSize
        for i in 0 ..< count {
            let f = first + i
            out[i] = f >= oldest && f < computedUntil ? base[f & (Self.ringSize - 1)] : 0
        }
    }

    private func process(count: Int) {
        let preMask = Self.preSize - 1
        let ringMask = Self.ringSize - 1
        let lineCount = Self.lineCount
        let tapCount = Self.tapCount
        let apGain = Self.allpassGain
        for i in 0 ..< count {
            pre[preIndex] = input[i]

            // Pre-delayed and diffused, into the network.
            var x = pre[(preIndex - preDelay) & preMask]
            for k in 0 ..< Self.allpassLengths.count {
                let slot = allpassOffsets[k] + allpassIndex[k]
                let delayed = allpass[slot]
                let w = x + apGain * delayed
                x = delayed - apGain * w
                allpass[slot] = w
                allpassIndex[k] = allpassIndex[k] + 1 == allpassLength[k] ? 0 : allpassIndex[k] + 1
            }
            x *= inputGain

            var sum: Float = 0
            for k in 0 ..< lineCount {
                let v = lines[lineOffsets[k] + lineIndex[k]]
                lineOut[k] = v
                lowpass[k] = v + damping * (lowpass[k] - v)
                let fed = lowpass[k] * feedback[k]
                looped[k] = fed
                sum += fed
            }
            // Householder: I − (2/N)·11ᵀ, lossless and dense.
            let mixed = sum * (2 / Float(lineCount))
            for k in 0 ..< lineCount {
                lines[lineOffsets[k] + lineIndex[k]] = looped[k] - mixed + x
                lineIndex[k] = lineIndex[k] + 1 == lineLength[k] ? 0 : lineIndex[k] + 1
            }

            let slot = (computedUntil + i) & ringMask
            for o in 0 ..< Self.outputCount {
                var late: Float = 0
                let row = signs + o * lineCount
                for k in 0 ..< lineCount { late += row[k] * lineOut[k] }
                var early: Float = 0
                let oTaps = taps + o * tapCount
                for t in 0 ..< tapCount { early += tapGains[t] * pre[(preIndex - oTaps[t]) & preMask] }
                ring[o * Self.ringSize + slot] = late * lateGain + early * earlyGain
            }
            preIndex = (preIndex + 1) & preMask
        }
        computedUntil += count
    }
}
