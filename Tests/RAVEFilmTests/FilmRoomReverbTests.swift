import Foundation
import Testing
@testable import RAVEFilm

/// The room `FilmStageView` plays instead of the system's acoustics.
@Suite("Film room reverb")
struct FilmRoomReverbTests {
    static let rate = 48000

    static func energyDB(_ x: [Float], seconds range: ClosedRange<Double>) -> Double {
        let a = Int(range.lowerBound * Double(rate)), b = Int(range.upperBound * Double(rate))
        let e = x[a ..< b].reduce(0.0) { $0 + Double($1 * $1) } / Double(b - a)
        return 10 * log10(max(e, 1e-30))
    }

    @MainActor
    @Test func anImpulseRingsAndDecaysAtTheRoomsRate() {
        guard #available(macOS 15.0, *) else { return }
        let (audio, scene) = ReverbFixture.makeAudio { f, ch in f == 100 && ch == 0 ? 0.9 : 0 }
        let reverb = FilmRoomReverb(audio: audio, elements: scene.elements)
        reverb.setRoom(.mediumRoom)
        reverb.setLevel(1)
        let out = ReverbFixture.render(reverb, output: 0, frames: Self.rate)
        let early = Self.energyDB(out, seconds: 0.1 ... 0.2)
        let late = Self.energyDB(out, seconds: 0.3 ... 0.4)
        #expect(early > -80, "no tail: \(early) dB")
        // RT60 0.6 s: 60 dB per 0.6 s is 20 dB per 0.2 s; damping makes it a bit faster.
        let decay = early - late
        #expect(decay > 12 && decay < 40, "decayed \(decay) dB in 0.2 s")
        // A cathedral rings much longer than a medium room.
        reverb.setRoom(.cathedral)
        audio.start(at: 0)
        let long = ReverbFixture.render(reverb, output: 0, frames: Self.rate)
        let longDecay = Self.energyDB(long, seconds: 0.1 ... 0.2) - Self.energyDB(long, seconds: 0.3 ... 0.4)
        #expect(longDecay < decay / 2, "cathedral decayed \(longDecay) dB vs room's \(decay)")
    }

    @MainActor
    @Test func outputsAreDecorrelated() {
        guard #available(macOS 15.0, *) else { return }
        var generator = SystemRandomNumberGenerator()
        let noise = (0 ..< 2 * Self.rate).map { _ in Float.random(in: -0.3 ... 0.3, using: &generator) }
        let (audio, scene) = ReverbFixture.makeAudio { f, ch in ch == 0 ? noise[f] : 0 }
        let reverb = FilmRoomReverb(audio: audio, elements: scene.elements)
        reverb.setRoom(.largeHall)
        reverb.setLevel(1)
        let outs = (0 ..< FilmRoomReverb.outputCount).map { o -> [Float] in
            audio.start(at: 0)
            return ReverbFixture.render(reverb, output: o, frames: Self.rate)
        }
        // Rendered one after another, each from a fresh tank fed the same
        // input: identical tanks, so only the output matrix tells them apart.
        func correlation(_ a: [Float], _ b: [Float]) -> Double {
            let range = Self.rate / 4 ..< Self.rate
            var ab = 0.0, aa = 0.0, bb = 0.0
            for i in range {
                ab += Double(a[i] * b[i]); aa += Double(a[i] * a[i]); bb += Double(b[i] * b[i])
            }
            return ab / (aa * bb).squareRoot()
        }
        for o in 1 ..< outs.count {
            let r = correlation(outs[0], outs[o])
            #expect(abs(r) < 0.3, "outputs 0 and \(o) correlate \(r)")
        }
    }

    @MainActor
    @Test func outputsShareOneTank() {
        guard #available(macOS 15.0, *) else { return }
        let (audio, scene) = ReverbFixture.makeAudio { f, ch in f == 100 && ch == 1 ? 0.9 : 0 }
        let reverb = FilmRoomReverb(audio: audio, elements: scene.elements)
        reverb.setRoom(.mediumRoom)
        reverb.setLevel(1)
        // Interleaved like four generators: each output's render reads what
        // another may already have computed, and none restarts the tank.
        var outs = [[Float]](repeating: [Float](repeating: 0, count: 8192), count: 4)
        for start in Swift.stride(from: 0, to: 8192, by: 512) {
            for o in 0 ..< 4 {
                outs[o].withUnsafeMutableBufferPointer {
                    reverb.renderForTesting(output: o, frame: start, count: 512, into: $0.baseAddress! + start)
                }
            }
        }
        audio.start(at: 0)
        let alone = ReverbFixture.render(reverb, output: 2, frames: 8192)
        #expect(zip(outs[2], alone).allSatisfy { abs($0 - $1) < 1e-6 })
    }

    @MainActor
    @Test func theLFEDoesNotFeedTheRoom() {
        guard #available(macOS 15.0, *) else { return }
        let (audio, scene) = ReverbFixture.makeAudio { f, ch in f == 100 && ch == 2 ? 0.9 : 0 }
        let reverb = FilmRoomReverb(audio: audio, elements: scene.elements)
        reverb.setRoom(.largeHall)
        reverb.setLevel(1)
        let out = ReverbFixture.render(reverb, output: 0, frames: Self.rate / 2)
        #expect(out.allSatisfy { $0 == 0 })
    }

    @MainActor
    @Test func aRestartEmptiesTheTail() {
        guard #available(macOS 15.0, *) else { return }
        let (audio, scene) = ReverbFixture.makeAudio { f, ch in f == 100 && ch == 0 ? 0.9 : 0 }
        let reverb = FilmRoomReverb(audio: audio, elements: scene.elements)
        reverb.setRoom(.cathedral)
        reverb.setLevel(1)
        _ = ReverbFixture.render(reverb, output: 0, frames: Self.rate / 4)
        // A seek to 0.6 s: the cathedral is still ringing there, but not from here.
        audio.start(at: Int(0.6 * Double(Self.rate)))
        let after = ReverbFixture.render(reverb, output: 0, from: Int(0.6 * Double(Self.rate)), frames: 4096)
        #expect(after.allSatisfy { $0 == 0 })
    }

    @MainActor
    @Test func offIsSilentAndPresetsSitAtSimilarLevels() {
        guard #available(macOS 15.0, *) else { return }
        var generator = SystemRandomNumberGenerator()
        let noise = (0 ..< 2 * Self.rate).map { _ in Float.random(in: -0.3 ... 0.3, using: &generator) }
        let (audio, scene) = ReverbFixture.makeAudio { f, ch in ch < 2 ? noise[f] * 0.5 : 0 }
        let reverb = FilmRoomReverb(audio: audio, elements: scene.elements)
        reverb.setRoom(.none)
        reverb.setLevel(1)
        #expect(ReverbFixture.render(reverb, output: 0, frames: 4096).allSatisfy { $0 == 0 })

        let dry = Self.energyDB(noise, seconds: 0.5 ... 1.5)
        var levels: [RAVEReverbPreset: Double] = [:]
        for preset in RAVEReverbPreset.allCases where preset != .none {
            reverb.setRoom(preset)
            audio.start(at: 0)
            let out = ReverbFixture.render(reverb, output: 0, frames: 3 * Self.rate / 2)
            levels[preset] = Self.energyDB(out, seconds: 0.5 ... 1.5) - dry
        }
        let values = levels.values
        #expect(values.max()! - values.min()! < 6, "\(levels)")
        // Wet against dry at 0 dB: clearly under the film, bigger spaces wetter.
        #expect(values.allSatisfy { $0 > -13 && $0 < -4 }, "\(levels)")
        #expect(levels[.cathedral]! > levels[.smallRoom]!, "\(levels)")
    }
}

@available(macOS 15.0, *)
enum ReverbFixture {
    /// Two objects and an LFE bed, two 2 s segments, segment 0 resident.
    static func makeAudio(fill: (Int, Int) -> Float) -> (AtmosObjectAudio, AtmosScene) {
        let elements = [
            AtmosScene.Element(id: 0, channel: 0, kind: "object", bedChannel: nil),
            AtmosScene.Element(id: 1, channel: 1, kind: "object", bedChannel: nil),
            AtmosScene.Element(id: 2, channel: 2, kind: "bed", bedChannel: "LFE"),
        ]
        let segmentFrames = 2 * FilmRoomReverbTests.rate
        let scene = AtmosScene(sampleRate: FilmRoomReverbTests.rate, elements: elements, frameCount: 2 * segmentFrames,
                               segmentFrames: segmentFrames, segmentCount: 2, groups: [[0, 1, 2]], startSeconds: 0)
        let audio = AtmosObjectAudio(scene: scene, slotCount: 3)
        let slot = audio.slots[0]
        for f in 0 ..< segmentFrames {
            for ch in 0 ..< 3 {
                let v = max(-1, min(fill(f, ch), 32767.0 / 32768.0))
                slot.samples[f * 3 + ch] = Int16(v * 32768)
            }
        }
        slot.segment.store(0, ordering: .releasing)
        audio.start(at: 0)
        return (audio, scene)
    }

    @MainActor
    static func render(_ reverb: FilmRoomReverb, output: Int, from: Int = 0, frames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        out.withUnsafeMutableBufferPointer { buffer in
            var f = 0
            while f < frames {
                let n = min(512, frames - f)
                reverb.renderForTesting(output: output, frame: from + f, count: n, into: buffer.baseAddress! + f)
                f += n
            }
        }
        return out
    }

}
