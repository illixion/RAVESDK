#if os(macOS)
import AVFoundation
import Testing
@testable import RAVEVoiceEngine

/// The output half on this Mac's speakers. Capture needs a record permission a
/// test host cannot grant, so the microphone half is checked on the headset.
@MainActor
@Suite("RAVEVoiceEngine outputs", .serialized)
struct RAVEVoiceEngineTests {
    final class Owner {}

    private func silentSource() -> AVAudioSourceNode {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        return AVAudioSourceNode(format: format) { _, _, frameCount, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            if let data = buffers[0].mData { memset(data, 0, Int(frameCount) * MemoryLayout<Float>.size) }
            return noErr
        }
    }

    @Test func anOutputStartsTheEngineAndTheLastOneStopsIt() throws {
        let voice = RAVEVoiceEngine.shared
        let a = Owner(), b = Owner()
        let nodeA = silentSource(), nodeB = silentSource()
        try voice.addOutput(a, nodes: [nodeA], connect: { $0.connect(nodeA, to: $0.mainMixerNode, format: nil) })
        #expect(voice.isRunning)
        #expect(nodeA.engine === voice.engine)
        try voice.addOutput(b, nodes: [nodeB], connect: { $0.connect(nodeB, to: $0.mainMixerNode, format: nil) })
        voice.removeOutput(a)
        #expect(nodeA.engine == nil)
        #expect(voice.isRunning)
        voice.removeOutput(b)
        #expect(!voice.isRunning)
        #expect(nodeB.engine == nil)
    }

    @Test func addingTheSameOwnerTwiceIsOneOutput() throws {
        let voice = RAVEVoiceEngine.shared
        let owner = Owner()
        let node = silentSource()
        var connects = 0
        let connect: (AVAudioEngine) throws -> Void = { engine in
            connects += 1
            engine.connect(node, to: engine.mainMixerNode, format: nil)
        }
        try voice.addOutput(owner, nodes: [node], connect: connect)
        try voice.addOutput(owner, nodes: [node], connect: connect)
        #expect(connects == 1)
        voice.removeOutput(owner)
        #expect(!voice.isRunning)
    }
}
#endif
