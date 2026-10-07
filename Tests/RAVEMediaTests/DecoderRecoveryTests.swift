import Foundation
import Testing
@testable import RAVEMedia

@Suite("Decoder recovery")
struct DecoderRecoveryTests {
    /// Collects recover calls from the helper's queue.
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var reasons: [String] = []
        private var gaveUp: [String] = []
        func add(_ r: RAVEDecoderRecovery.Reason) { lock.lock(); reasons.append(r.description); lock.unlock() }
        func giveUp(_ r: String) { lock.lock(); gaveUp.append(r); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return reasons.count }
        var gaveUpCount: Int { lock.lock(); defer { lock.unlock() }; return gaveUp.count }
    }

    private func settle(_ seconds: Double = 0.05) async { try? await Task.sleep(for: .seconds(seconds)) }

    @Test("A loss is recovered asynchronously, once")
    func recoversOnce() async {
        let calls = Calls()
        let recovery = RAVEDecoderRecovery(minimumInterval: 0.2) { calls.add($0) }
        recovery.noteLoss(.sessionLost)
        #expect(calls.count == 0) // never from inside the caller's call
        await settle()
        #expect(calls.count == 1)
    }

    @Test("Losses inside the interval are spaced out, not dropped")
    func rateLimited() async {
        let calls = Calls()
        let recovery = RAVEDecoderRecovery(minimumInterval: 0.2) { calls.add($0) }
        recovery.noteLoss(.sessionLost)
        await settle()
        recovery.noteLoss(.sessionLost)
        recovery.noteLoss(.sessionLost)
        await settle()
        #expect(calls.count == 1)
        await settle(0.3)
        #expect(calls.count == 2)
    }

    @Test("After a recovery, delta frames are dropped until a key frame")
    func keyFrameGate() async {
        let calls = Calls()
        let recovery = RAVEDecoderRecovery(minimumInterval: 0.2) { calls.add($0) }
        #expect(recovery.admit(isKeyFrame: false))
        recovery.noteLoss(.sessionLost)
        await settle()
        #expect(!recovery.admit(isKeyFrame: false))
        #expect(recovery.admit(isKeyFrame: true))
        #expect(recovery.admit(isKeyFrame: false))
    }

    @Test("Deltas that keep coming ask for a key frame again")
    func asksAgain() async {
        let calls = Calls()
        let recovery = RAVEDecoderRecovery(minimumInterval: 0.1) { calls.add($0) }
        recovery.expectKeyFrame()
        #expect(!recovery.admit(isKeyFrame: false))
        await settle(0.15)
        #expect(!recovery.admit(isKeyFrame: false))
        await settle()
        #expect(calls.count == 1)
    }

    @Test("Gives up after the attempt limit; a key frame resets the count")
    func givesUp() async {
        let calls = Calls()
        let recovery = RAVEDecoderRecovery(minimumInterval: 0.01, maximumAttempts: 2,
                                           onGiveUp: { calls.giveUp($0) }) { calls.add($0) }
        for _ in 0..<3 {
            recovery.noteLoss(.rendererFailed)
            await settle()
        }
        #expect(calls.count == 2)
        #expect(calls.gaveUpCount == 1)
        recovery.reset()
        recovery.noteLoss(.rendererFailed)
        await settle()
        #expect(calls.count == 3)
    }

    @Test("Cancelled recovery does nothing")
    func cancelled() async {
        let calls = Calls()
        let recovery = RAVEDecoderRecovery(minimumInterval: 0.01) { calls.add($0) }
        recovery.cancel()
        recovery.noteLoss(.sessionLost)
        await settle()
        #expect(calls.count == 0)
    }
}

@Suite("Decoder recovery limits")
struct DecoderRecoveryLimitTests {
    @Test("Withdrawn decoding never counts toward giving up")
    func withdrawnNeverGivesUp() async {
        let calls = DecoderRecoveryTests.Calls()
        let recovery = RAVEDecoderRecovery(minimumInterval: 0.01, maximumAttempts: 1,
                                           onGiveUp: { calls.giveUp($0) }) { calls.add($0) }
        for _ in 0..<4 {
            recovery.noteLoss(.sessionLost)
            try? await Task.sleep(for: .seconds(0.05))
        }
        #expect(calls.count == 4)
        #expect(calls.gaveUpCount == 0)
    }
}
