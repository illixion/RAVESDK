import AVFoundation
import Foundation
import Testing
@testable import RAVEFilm

/// The object audio at another speed: faster, at its own pitch, every
/// channel splicing at the same frames.
@Suite("Film time stretch")
struct FilmTimeStretchTests {
    static let rate = FilmRoomReverbTests.rate

    /// Renders `frames` of one channel through the render callback, `buffer`
    /// frames at a time, with no timestamps (each channel's own cursor).
    @available(macOS 15.0, *)
    static func render(_ audio: AtmosObjectAudio, channel: Int, frames: Int, buffer: Int = 512) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        var chunk = [Float](repeating: 0, count: buffer)
        var silence = ObjCBool(false)
        var timestamp = AudioTimeStamp()
        var f = 0
        while f < frames {
            let n = min(buffer, frames - f)
            chunk.withUnsafeMutableBufferPointer { pointer in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(n * MemoryLayout<Float>.size), mData: pointer.baseAddress))
                _ = audio.render(channel: channel, isSilence: &silence, timestamp: &timestamp,
                                 frameCount: AVAudioFrameCount(n), output: &list)
            }
            out.replaceSubrange(f ..< f + n, with: chunk[0 ..< n])
            f += n
        }
        return out
    }

    /// Upward zero crossings per second over `range` (seconds).
    static func crossingsPerSecond(_ x: [Float], seconds range: ClosedRange<Double>) -> Double {
        let a = Int(range.lowerBound * Double(rate)), b = Int(range.upperBound * Double(rate))
        var count = 0
        for i in a + 1 ..< b where x[i - 1] < 0 && x[i] >= 0 { count += 1 }
        return Double(count) / (range.upperBound - range.lowerBound)
    }

    static func rms(_ x: ArraySlice<Float>) -> Float {
        (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
    }

    @Test func atSpeedOneTheSceneIsReadAsIs() {
        guard #available(macOS 15.0, *) else { return }
        let (audio, _) = ReverbFixture.makeAudio { f, ch in ch == 0 ? Float(f % 200) / 400 - 0.25 : 0 }
        let out = Self.render(audio, channel: 0, frames: 4800)
        let expected = (0 ..< 4800).map { f in Float(Int16((Float(f % 200) / 400 - 0.25) * 32768)) / 32768 }
        #expect(out == expected)
    }

    @Test func fasterKeepsThePitchAndTheLevel() {
        guard #available(macOS 15.0, *) else { return }
        let (audio, _) = ReverbFixture.makeAudio { f, ch in
            ch == 2 ? 0 : 0.5 * Float(sin(2 * Double.pi * 440 * Double(f) / Double(Self.rate)))
        }
        audio.start(at: 0, speed: 1.5)
        let out = Self.render(audio, channel: 0, frames: Self.rate)

        // The scene moved on half as far again as the output did.
        let played = audio.playhead.load(ordering: .relaxed)
        #expect(abs(played - Self.rate * 3 / 2) < audio.stretch.search + audio.stretch.hop, "playhead \(played)")
        // Same tone: resampling would have raised it to 660 Hz.
        let tone = Self.crossingsPerSecond(out, seconds: 0.1 ... 0.9)
        #expect(abs(tone - 440) < 10, "\(tone) Hz")
        // Grains spliced in phase: no dips where two of them overlap.
        let expected: Float = 0.5 / Float(2).squareRoot()
        let window = Self.rate / 100
        for start in Swift.stride(from: Self.rate / 10, to: Self.rate * 9 / 10, by: window) {
            let level = Self.rms(out[start ..< start + window])
            #expect(level > expected * 0.9 && level < expected * 1.1, "level \(level) at frame \(start)")
        }
    }

    @Test func slowerKeepsThePitch() {
        guard #available(macOS 15.0, *) else { return }
        let (audio, _) = ReverbFixture.makeAudio { f, ch in
            ch == 2 ? 0 : 0.5 * Float(sin(2 * Double.pi * 300 * Double(f) / Double(Self.rate)))
        }
        audio.start(at: 0, speed: 0.75)
        let out = Self.render(audio, channel: 0, frames: Self.rate)
        let tone = Self.crossingsPerSecond(out, seconds: 0.1 ... 0.9)
        #expect(abs(tone - 300) < 10, "\(tone) Hz")
        let played = audio.playhead.load(ordering: .relaxed)
        #expect(abs(played - Self.rate * 3 / 4) < audio.stretch.search + audio.stretch.hop, "playhead \(played)")
    }

    @Test func everyChannelSplicesAtTheSameFrames() {
        guard #available(macOS 15.0, *) else { return }
        // A gliding chord: grains land somewhere different in every period,
        // so any channel choosing its own splices would come out different.
        func signal(_ f: Int) -> Float {
            let t = Double(f) / Double(Self.rate)
            return Float(0.3 * sin(2 * .pi * (220 * t + 40 * t * t)) + 0.2 * sin(2 * .pi * 331 * t))
        }
        let (audio, _) = ReverbFixture.makeAudio { f, ch in ch == 2 ? 0 : signal(f) }
        audio.start(at: 0, speed: 1.25)
        // Different buffer sizes, as two renderers ask for: the second
        // channel reads every grain the first one published.
        let first = Self.render(audio, channel: 0, frames: Self.rate / 2, buffer: 512)
        let second = Self.render(audio, channel: 1, frames: Self.rate / 2, buffer: 441)
        #expect(first == second)
    }

    @Test func aNewStartForgetsTheOldGrains() {
        guard #available(macOS 15.0, *) else { return }
        let (audio, _) = ReverbFixture.makeAudio { f, ch in
            ch == 2 ? 0 : 0.5 * Float(sin(2 * Double.pi * 500 * Double(f) / Double(Self.rate)))
        }
        audio.start(at: 0, speed: 2)
        let fast = Self.render(audio, channel: 0, frames: Self.rate / 4)
        // The same start again replays the same grains, chosen afresh.
        audio.start(at: 0, speed: 2)
        #expect(Self.render(audio, channel: 0, frames: Self.rate / 4) == fast)
        // And back at speed 1 the scene plays as it is.
        audio.start(at: 0, speed: 1)
        let plain = Self.render(audio, channel: 0, frames: 4800)
        let expected = (0 ..< 4800).map { f in
            Float(Int16(0.5 * Float(sin(2 * Double.pi * 500 * Double(f) / Double(Self.rate))) * 32768)) / 32768
        }
        #expect(plain == expected)
    }
}
