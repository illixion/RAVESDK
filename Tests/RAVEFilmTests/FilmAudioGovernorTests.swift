import Foundation
import Testing
@testable import RAVEFilm

/// "Auto": which tier the next segment is fetched in, from what the link
/// carried. The clock and the link are the test's.
@Suite("Film audio governor")
struct FilmAudioGovernorTests {
    /// A clock the test moves.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        var now: ContinuousClock.Instant { lock.withLock { instant } }
        func advance(_ by: Duration) { lock.withLock { instant = instant + by } }
    }

    final class Path: @unchecked Sendable {
        private let lock = NSLock()
        private var value = FilmAudioGovernor.Link()
        var link: FilmAudioGovernor.Link { lock.withLock { value } }
        func set(_ change: (inout FilmAudioGovernor.Link) -> Void) { lock.withLock { change(&value) } }
    }

    /// A demo-sized scene: twelve channels, 10 s segments.
    static let scene = AtmosScene(
        sampleRate: 48000,
        elements: (0 ..< 12).map { AtmosScene.Element(id: $0, channel: $0, kind: "object", bedChannel: nil) },
        frameCount: 5_170_000, segmentFrames: 480_000, segmentCount: 11,
        groups: [Array(0 ..< 6), Array(6 ..< 12)], startSeconds: 0, bundleCodecs: ["aac", "opus"])

    func make(codec: FilmAudioGovernor.Codec = .aac) -> (FilmAudioGovernor, Clock, Path) {
        let clock = Clock(), path = Path()
        return (FilmAudioGovernor(codec: codec, link: { path.link }, now: { clock.now }), clock, path)
    }

    /// A transfer at `mbps` megabits per second.
    func transfer(_ governor: FilmAudioGovernor, mbps: Double, megabytes: Double = 4) {
        governor.recordTransfer(bytes: Int(megabytes * 1_000_000), seconds: megabytes * 8 / mbps)
    }

    @Test func startsSmallAndMeasuresBeforeAskingForMore() {
        let (governor, _, path) = make()
        #expect(governor.plan(for: Self.scene).tier == .kbps96)
        path.set { $0.isExpensive = true; $0.generation += 1 }
        #expect(governor.plan(for: Self.scene).tier == .kbps64)
        path.set { $0.isConstrained = true; $0.generation += 1 }
        #expect(governor.plan(for: Self.scene).tier == .kbps32)
    }

    @Test func aFastLinkGoesStraightToLosslessOnceMeasured() {
        let (governor, _, _) = make()
        transfer(governor, mbps: 200)
        let plan = governor.plan(for: Self.scene)
        #expect(plan.tier == .lossless && plan.encoding == .lossless && plan.budget == nil)
    }

    @Test func aFirstGuessIsReplacedAtOnceByWhatIsMeasured() {
        let (governor, _, _) = make()
        #expect(governor.plan(for: Self.scene).tier == .kbps96)
        transfer(governor, mbps: 200)
        // No quiet spell to wait out: the guess was never earned.
        #expect(governor.plan(for: Self.scene).tier == .lossless)
    }

    @Test func aSlowerLinkGetsWhatFitsAFractionOfIt() {
        // 12 channels: AAC 96 needs ~1.0 Mbps, 64 ~0.7, 48 ~0.5; the audio may use 40% of the link.
        for (mbps, expected) in [(8.5, FilmAudioGovernor.Tier.lossless), (3.0, .kbps96), (2.0, .kbps64), (1.5, .kbps48), (1.0, .kbps32), (0.7, .kbps24), (0.5, .kbps16)] {
            let (governor, _, _) = make()
            transfer(governor, mbps: mbps)
            #expect(governor.plan(for: Self.scene).tier == expected, "\(mbps) Mbps")
        }
    }

    @Test func whenNothingFitsTheRequestCarriesABudget() {
        let (governor, _, _) = make()
        transfer(governor, mbps: 0.3, megabytes: 0.5)
        let plan = governor.plan(for: Self.scene)
        #expect(plan.tier == .kbps16)
        #expect(plan.budget == 120_000)
    }

    @Test func thePathCapsTheTier() {
        let (governor, _, path) = make()
        transfer(governor, mbps: 500)
        path.set { $0.isExpensive = true }
        #expect(governor.plan(for: Self.scene).tier == .kbps64)
        path.set { $0.isConstrained = true }
        #expect(governor.plan(for: Self.scene).tier == .kbps32)
    }

    @Test func switchingInterfaceForgetsWhatWasMeasured() {
        let (governor, _, path) = make()
        transfer(governor, mbps: 500)
        #expect(governor.plan(for: Self.scene).tier == .lossless)
        path.set { $0.isExpensive = true; $0.generation += 1 }
        // The cellular link is unmeasured: a first guess at the cellular cap, not the Wi-Fi's rate.
        #expect(governor.plan(for: Self.scene).tier == .kbps64)
    }

    @Test func steppingUpNeedsAQuietSpellAndMargin() {
        let (governor, clock, _) = make()
        transfer(governor, mbps: 1.5)
        #expect(governor.plan(for: Self.scene).tier == .kbps48)
        // The link recovers (twice: the estimate is smoothed), but a flapping link shouldn't flap the sound.
        for _ in 0 ..< 6 { transfer(governor, mbps: 50) }
        #expect(governor.plan(for: Self.scene).tier == .kbps48)
        clock.advance(.seconds(21))
        #expect(governor.plan(for: Self.scene).tier == .lossless)
    }

    @Test func steppingDownIsImmediate() {
        let (governor, _, _) = make()
        transfer(governor, mbps: 200)
        #expect(governor.plan(for: Self.scene).tier == .lossless)
        // Each slower sample halves the distance to it (a link is believed slower quickly, faster slowly).
        for _ in 0 ..< 12 { transfer(governor, mbps: 2) }
        #expect(governor.plan(for: Self.scene).tier == .kbps64)
    }

    @Test func aFailureStepsDownAndHoldsTheLinkBack() {
        let (governor, clock, _) = make()
        transfer(governor, mbps: 200)
        #expect(governor.plan(for: Self.scene).tier == .lossless)
        governor.recordFailure()
        #expect(governor.plan(for: Self.scene).tier == .kbps96)
        // Fast again, but not for the next half minute.
        for _ in 0 ..< 8 { transfer(governor, mbps: 200) }
        clock.advance(.seconds(25))
        #expect(governor.plan(for: Self.scene).tier == .kbps96)
        clock.advance(.seconds(10))
        #expect(governor.plan(for: Self.scene).tier == .lossless)
    }

    @Test func aLinkThatIsDownIsOneFailureNotMany() {
        let (governor, clock, _) = make()
        transfer(governor, mbps: 200)
        #expect(governor.plan(for: Self.scene).tier == .lossless)
        // A dropped link fails every retry within moments; the sound steps down once, and the estimate isn't ground to nothing.
        for _ in 0 ..< 10 {
            governor.recordFailure()
            clock.advance(.milliseconds(250))
        }
        #expect(governor.plan(for: Self.scene).tier == .kbps96)
        #expect((governor.measuredRate ?? 0) > 50_000_000)
        // A failure of another outage, later, is another step.
        clock.advance(.seconds(10))
        governor.recordFailure()
        #expect(governor.plan(for: Self.scene).tier == .kbps64)
    }

    @Test func aStallStepsDownOnlyWhenTheFetchWasTheSlowPart() {
        let (governor, clock, _) = make()
        transfer(governor, mbps: 200)
        var plan = governor.plan(for: Self.scene)
        // Fetched quickly, and still ran out: the device is slow, not the link.
        governor.recordSegment(plan: plan, bytes: 4_000_000, fetchSeconds: 0.5, scene: Self.scene)
        governor.recordStall(of: Self.scene)
        #expect(governor.plan(for: Self.scene).tier == .lossless)
        clock.advance(.seconds(10))
        // Taking half the segment's duration to arrive, it is the link.
        for _ in 0 ..< 4 { governor.recordSegment(plan: plan, bytes: 4_000_000, fetchSeconds: 6, scene: Self.scene) }
        governor.recordStall(of: Self.scene)
        plan = governor.plan(for: Self.scene)
        #expect(plan.tier == .kbps96)
    }

    @Test func whatATierActuallyTookReplacesTheGuess() {
        let (governor, _, _) = make()
        // 3.5 Mbps: capacity 1.4 Mbps, so AAC 96 (guess 1.0 Mbps) fits.
        transfer(governor, mbps: 3.5)
        var plan = governor.plan(for: Self.scene)
        #expect(plan.tier == .kbps96)
        // But this film's 96 kbps audio came to 2 Mbps (every channel busy): it doesn't.
        for _ in 0 ..< 3 { governor.recordSegment(plan: plan, bytes: 2_500_000, fetchSeconds: 1, scene: Self.scene) }
        plan = governor.plan(for: Self.scene)
        #expect(plan.tier == .kbps64)
    }

    @Test func smallTransfersAreLatencyNotBandwidth() {
        let (governor, _, _) = make()
        governor.recordTransfer(bytes: 20_000, seconds: 0.5)
        // Nothing measured: still the first guess.
        #expect(governor.plan(for: Self.scene).tier == .kbps96)
    }

    @Test func aTransferTooQuickToTimeCountsAsFast() {
        let (governor, _, _) = make()
        // A megabyte in 3 ms (a LAN): read as at least 800 Mbps, not thrown away.
        governor.recordTransfer(bytes: 1_000_000, seconds: 0.003)
        #expect(governor.plan(for: Self.scene).tier == .lossless)
    }

    @Test func opusForAClientWithoutAAC() {
        let (governor, _, _) = make(codec: .opus)
        #expect(governor.plan(for: Self.scene).encoding == .opus(bitrate: 96000))
        #expect(governor.summary == "Auto · Opus 96 kbps")
    }
}
