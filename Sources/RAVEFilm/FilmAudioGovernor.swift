/*
 RAVE SDK — adaptive object-audio quality ("Auto")

 Chooses, segment by segment, how a film's object audio is fetched, from
 what the link has shown it carries rather than what it is called. The old
 rule read the path once when the film opened: lossless unless the path was
 expensive. A phone that walked out of the house onto cellular kept pulling
 3 Mbps of FLAC; a hotel Wi-Fi (not "expensive", and slow) never got
 anything smaller.

 The governor sees:
 - Every large transfer from the film's server, the picture's segments
   included (they are most of the traffic, and the best measure of what the
   link does at full tilt): `recordTransfer`. Measured from the first byte of
   the response to the last, so the server's own time to build a segment
   doesn't read as a slow link.
 - How big each tier's audio turned out to be (`recordSegment`), so the next
   choice doesn't rest on a guess.
 - Failures and playback stalls, which step down at once.
 - The path (cellular, hotspot, Low Data Mode) from the app, with a
   generation that changes when it switches interface: what was measured on
   the old one says nothing about the new.

 It picks the best tier whose audio fits in `share` of the measured rate (a
 segment arrives in well under half its own duration, leaving the rest to
 the picture), never better than the path allows (lossless on an unmetered
 path, 64 kbps on cellular, 32 on Low Data Mode). Down is immediate; up
 needs the margin and a quiet spell, so a link that flaps doesn't make the
 sound flap with it. When even the lowest tier can't fit, the request
 carries a budget and the server leaves out the quietest channels.

 Tiers are encodings the plugin already serves, so a change needs no reload:
 the next segment is fetched in the new tier and decoded to the same PCM as
 the last.
 */

import DebugTrace
import Foundation
import os

public final class FilmAudioGovernor: @unchecked Sendable {
    /// What the app knows of the network path.
    public struct Link: Sendable, Equatable {
        /// Cellular or a hotspot.
        public var isExpensive: Bool
        /// Low Data Mode.
        public var isConstrained: Bool
        /// Changes when the path switches interface.
        public var generation: Int

        public init(isExpensive: Bool = false, isConstrained: Bool = false, generation: Int = 0) {
            self.isExpensive = isExpensive
            self.isConstrained = isConstrained
            self.generation = generation
        }
    }

    public enum Codec: Sendable { case aac, opus }

    /// Best first: a smaller raw value is better quality.
    public enum Tier: Int, CaseIterable, Sendable {
        case lossless, kbps96, kbps64, kbps48, kbps32, kbps24, kbps16

        /// Average bits per second per audible channel; nil for lossless.
        var perChannel: Int? {
            switch self {
            case .lossless: nil
            case .kbps96: 96000
            case .kbps64: 64000
            case .kbps48: 48000
            case .kbps32: 32000
            case .kbps24: 24000
            case .kbps16: 16000
            }
        }

        func encoding(_ codec: Codec) -> FilmAudioEncoding {
            guard let rate = perChannel else { return .lossless }
            return codec == .aac ? .aac(bitrate: rate) : .opus(bitrate: rate)
        }
    }

    /// What the next segment is fetched as.
    public struct Plan: Sendable, Equatable {
        public let tier: Tier
        public let encoding: FilmAudioEncoding
        /// A cap on the segment's bits per second, when even the lowest tier
        /// is more than the link carries.
        public let budget: Int?
    }

    // Tuning. The shape matters more than the numbers; they are guesses
    // from the demo's sizes, to be tuned on devices.
    /// The share of the measured rate the audio may need.
    static let share = 0.4
    /// A better tier needs this much more than it would use.
    static let stepUpMargin = 1.3
    /// Quiet time at the current tier before stepping back up, and after a failure or a stall.
    static let stepUpAfter: Duration = .seconds(20)
    static let holdAfterFailure: Duration = .seconds(30)
    static let holdAfterStall: Duration = .seconds(60)
    /// Failures this close together are one.
    static let failureWindow: Duration = .seconds(5)
    /// Transfers smaller than this are latency, not bandwidth.
    static let minSampleBytes = 128_000
    static let minSampleSeconds = 0.01
    /// Lossless bits per second per scene channel before one has been seen
    /// (the demo: 270 kbps; silent channels cost almost nothing).
    static let losslessPrior = 270_000.0
    /// Audible share of a scene's channels for a compressed tier not yet
    /// seen, and what each AAC stream's container adds (an M4A's sample
    /// tables: a 16 kbps stream comes to 18.8 kbps); Ogg's pages are no cost worth counting.
    static let audibleShare = 0.85
    static let aacStreamOverhead = 2600.0

    private struct State {
        var tier: Tier?
        /// The tier was a first guess, chosen before anything was measured;
        /// nothing has been earned that a flapping link could lose.
        var probing = false
        var changedAt: ContinuousClock.Instant
        var holdUntil: ContinuousClock.Instant
        var lastStallAt: ContinuousClock.Instant?
        var lastFailureAt: ContinuousClock.Instant?
        /// Smoothed transfer rate, bits per second; nil until measured.
        var rate: Double?
        /// Smoothed wall time of a segment fetch, as a fraction of the segment's duration.
        var fetchLoad: Double = 0
        /// Bits per second of film each tier took, for the scene named by `sceneKey`.
        var observed: [Tier: Double] = [:]
        var sceneKey = 0
        var generation = 0
    }

    private let logger = DebugLogger(subsystem: "com.illixion.hypnos", category: "AtmosAudio")
    let codec: Codec
    private let link: @Sendable () -> Link
    private let now: @Sendable () -> ContinuousClock.Instant
    private let state: OSAllocatedUnfairLock<State>

    public init(codec: Codec = .aac,
                link: @escaping @Sendable () -> Link = { Link() },
                now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.codec = codec
        self.link = link
        self.now = now
        let start = now()
        state = OSAllocatedUnfairLock(initialState: State(changedAt: start, holdUntil: start, generation: link().generation))
    }

    // MARK: Deciding

    /// The best tier the path allows.
    static func ceiling(for link: Link) -> Tier {
        if link.isConstrained { return .kbps32 }
        if link.isExpensive { return .kbps64 }
        return .lossless
    }

    /// The tier now in use (nil before the first segment), for display.
    public var tier: Tier? { state.withLock { $0.tier } }

    /// The encoding the next segment would most likely be fetched in: the
    /// tier now in use, or the best the path allows before one is chosen.
    public var currentEncoding: FilmAudioEncoding {
        (state.withLock { $0.tier } ?? Self.ceiling(for: link())).encoding(codec)
    }

    /// "Auto · AAC 64 kbps".
    public var summary: String { "Auto · \(currentEncoding.summary)" }

    /// What the link has carried lately, bits per second; nil until measured.
    public var measuredRate: Double? { state.withLock { $0.rate } }

    /// How the next segment of `scene` should be fetched.
    public func plan(for scene: AtmosScene) -> Plan {
        let link = link()
        let instant = now()
        let (plan, change) = state.withLock { s -> (Plan, (from: Tier?, to: Tier, rate: Double?)?) in
            var change: (from: Tier?, to: Tier, rate: Double?)?
            if link.generation != s.generation {
                s.generation = link.generation
                s.rate = nil
                s.tier = nil
                s.probing = false
                s.fetchLoad = 0
                s.observed = [:]
            }
            let key = scene.frameCount ^ (scene.elements.count << 40)
            if key != s.sceneKey {
                s.sceneKey = key
                s.observed = [:]
            }

            let ceiling = Self.ceiling(for: link)
            let chosen: Tier
            var budget: Int?
            if let rate = s.rate {
                let capacity = rate * Self.share
                func need(_ tier: Tier) -> Double { Self.requirement(of: tier, scene: scene, observed: s.observed, codec: codec) }
                let fits = Tier.allCases.filter { $0.rawValue >= ceiling.rawValue }
                var best = fits.first { need($0) <= capacity } ?? .kbps16
                if let current = s.tier, !s.probing, best.rawValue < current.rawValue {
                    // Better than now: only with the margin, and after a quiet spell.
                    let settled = instant >= s.holdUntil && instant - s.changedAt >= Self.stepUpAfter
                    let candidates = fits.filter { $0.rawValue >= best.rawValue && $0.rawValue < current.rawValue }
                    best = settled ? (candidates.first { need($0) * Self.stepUpMargin <= capacity } ?? current) : current
                }
                // Never better than the path allows, even if the tier held from before did.
                chosen = best.rawValue < ceiling.rawValue ? ceiling : best
                if need(.kbps16) > capacity { budget = Int(capacity) }
                s.probing = false
            } else {
                // Nothing measured yet: begin small and measure, rather than
                // wait on a megabytes-long first segment over a link that may be slow.
                let start = ceiling.rawValue < Tier.kbps96.rawValue ? Tier.kbps96 : ceiling
                // A failure before anything was measured still counts.
                chosen = s.tier.map { $0.rawValue > start.rawValue ? $0 : start } ?? start
                s.probing = true
            }
            if chosen != s.tier {
                change = (s.tier, chosen, s.rate)
                s.tier = chosen
                s.changedAt = instant
            }
            return (Plan(tier: chosen, encoding: chosen.encoding(codec), budget: budget), change)
        }
        if let change {
            logger.info("Audio quality \(change.from.map { "\($0)" } ?? "none", privacy: .public) → \(change.to.encoding(codec).summary, privacy: .public) (link \(change.rate.map { Int($0 / 1000) } ?? -1, privacy: .public) kbps measured)")
        }
        return plan
    }

    /// Bits per second of film `tier` needs for `scene`.
    static func requirement(of tier: Tier, scene: AtmosScene, observed: [Tier: Double], codec: Codec) -> Double {
        if let seen = observed[tier] { return seen }
        let channels = Double(scene.elements.count)
        guard let rate = tier.perChannel else { return losslessPrior * channels }
        return (Double(rate) + (codec == .aac ? aacStreamOverhead : 0)) * channels * audibleShare
    }

    // MARK: Learning

    /// A transfer of `bytes` over `seconds` (first byte to last) from the
    /// film's server: audio, picture or anything else large.
    public func recordTransfer(bytes: Int, seconds: Double) {
        guard bytes >= Self.minSampleBytes, seconds > 0 else { return }
        // A transfer too quick to time (a LAN) is at least this fast: the clock's grain, not the link, sets the floor.
        let sample = Double(bytes) * 8 / max(seconds, Self.minSampleSeconds)
        state.withLock { s in
            // Quick to believe a slower link, slow to believe a faster one.
            s.rate = s.rate.map { sample < $0 ? $0 * 0.5 + sample * 0.5 : $0 * 0.8 + sample * 0.2 } ?? sample
        }
    }

    /// An audio segment fetched as `plan`: its payload size, and how long
    /// the whole fetch took, server time included.
    public func recordSegment(plan: Plan, bytes: Int, fetchSeconds: Double, scene: AtmosScene) {
        let duration = Double(scene.segmentFrames) / Double(max(1, scene.sampleRate))
        guard duration > 0 else { return }
        let bits = Double(bytes) * 8 / duration
        let load = fetchSeconds / duration
        state.withLock { s in
            // A budget changes what a tier costs; only unbudgeted fetches say what it does.
            if plan.budget == nil {
                s.observed[plan.tier] = s.observed[plan.tier].map { $0 * 0.5 + bits * 0.5 } ?? bits
            }
            s.fetchLoad = s.fetchLoad * 0.6 + load * 0.4
        }
    }

    /// A fetch that failed or timed out: one tier down, and a longer wait
    /// before going back up. A link that is simply down fails every retry:
    /// those within a few seconds of the last count as the same failure, so
    /// the sound doesn't fall to the bottom tier, and the estimate to
    /// nothing, while it waits for the link to come back.
    public func recordFailure() {
        let instant = now()
        let repeated = state.withLock { s -> Bool in
            if let last = s.lastFailureAt, instant - last < Self.failureWindow { return true }
            s.lastFailureAt = instant
            return false
        }
        if !repeated { stepDown(hold: Self.holdAfterFailure, rateFactor: 0.5) }
    }

    /// The sound ran out under the playhead. Only a slow fetch is the link's
    /// fault: a device too slow to decode would not be helped by less data.
    public func recordStall(of scene: AtmosScene) {
        let instant = now()
        let slow = state.withLock { s -> Bool in
            if let last = s.lastStallAt, instant - last < .seconds(5) { return false }
            s.lastStallAt = instant
            return s.fetchLoad > 0.3
        }
        if slow { stepDown(hold: Self.holdAfterStall, rateFactor: 0.7) }
    }

    private func stepDown(hold: Duration, rateFactor: Double) {
        let instant = now()
        state.withLock { s in
            let current = s.tier ?? Self.ceiling(for: link())
            s.tier = Tier(rawValue: min(Tier.kbps16.rawValue, current.rawValue + 1))
            s.changedAt = instant
            s.holdUntil = instant + hold
            s.rate = s.rate.map { $0 * rateFactor }
        }
    }
}
