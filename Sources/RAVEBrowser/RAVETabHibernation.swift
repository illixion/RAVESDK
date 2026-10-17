/*
 RAVEBrowser — when a tab stops being worth a content process.

 The jetsam report from 2026-09-21 is the argument for this file. Raven's own
 process was 485 MB; the Meet tab's `WebContent` was 1.0 GB; two tabs nobody
 had looked at in an hour were another 270 MB and 157 MB, suspended, doing
 nothing. WebKit had already done everything it does on its own — a tab that is
 not in the window has its process suspended, and the OS reclaims suspended
 pages first — and the tabs were still that big, because suspending a process
 is not the same as giving its memory back.

 **What Safari does, and what this does, is give the page up and keep the tab.**
 A tab hidden long enough, or any hidden tab while the system is asking for
 memory back, drops its `WKWebView`: the content process exits, and what is
 left is the address, the title and `interactionState` — enough to put the user
 back where they were, one page load later. See `RAVEBrowserTab.hibernate(reason:)`.

 Three deliberate limits, because the failure mode of getting this wrong is a
 browser that loses your work:

 - **Only hidden tabs, ever.** The tab on screen is never touched, whatever the
   pressure. A page reloading under the user is worse than being killed by
   jetsam, because at least jetsam takes the whole app and nobody blames the
   tab they were reading.
 - **Anything doing work is exempt** — a call, a screen share, a conversion, a
   camera proxy, audio playing. `RAVEBrowserTab.hibernationBlocker` is the list,
   and it is checked again at the moment of hibernating rather than only when
   the sweep picks a victim.
 - **Pressure has a grace period.** The tab the user switched away from ten
   seconds ago is the one they are most likely to switch back to, and a
   *warning* is not a crash. Two minutes of being hidden buys a tab out of a
   warning sweep; a critical notification does not grant it.

 The policy is a separate, pure type from the sweeper that runs it, so the
 decision — which tabs, in what order, under which trigger — can be tested
 without a `WKWebView`, a timer or a memory-pressure source.

 Raven's `TabHibernation`, lifted 2026-10-17. A tab takes part only if its app
 passes a sweeper (`RAVEBrowserTab(hibernation: .shared)`): an app that never
 reports visibility would otherwise have every tab counted as hidden.
 */

#if canImport(WebKit)
import Foundation
import os

// MARK: - Policy

public enum RAVETabHibernationPolicy {
    /// How long a tab has to be off screen before an ordinary sweep takes its
    /// page. Half an hour is Safari-ish, and deliberately long: this exists
    /// for the tabs someone forgot, not for the one they are alternating with.
    public static let idleInterval: TimeInterval = 30 * 60
    /// A memory-pressure *warning* spares whatever was on screen recently.
    public static let pressureGrace: TimeInterval = 2 * 60
    /// How often the idle sweep looks. Nothing is urgent at this timescale;
    /// the pressure path is the one that has to be prompt.
    public static let sweepInterval: TimeInterval = 60

    public enum Trigger: Equatable, Sendable {
        /// The timer.
        case idle
        /// `DispatchSource.makeMemoryPressureSource`, which is the only
        /// warning an app ever gets before jetsam starts killing things.
        case pressure(critical: Bool)

        public var reason: String {
            switch self {
            case .idle: "idle"
            case .pressure(critical: false): "memory pressure"
            case .pressure(critical: true): "critical memory pressure"
            }
        }
    }

    /// One tab, as the policy sees it. Everything expensive to ask — is it
    /// capturing, is it playing audio — has already been answered by
    /// `RAVEBrowserTab.hibernationBlocker` and reduced to `blocked`.
    public struct Candidate: Equatable, Sendable {
        public let id: UUID
        /// How long it has been off screen; nil if it is on screen now.
        public let hiddenFor: TimeInterval?
        /// It is doing something that hibernating would break.
        public let blocked: Bool

        public init(id: UUID, hiddenFor: TimeInterval?, blocked: Bool) {
            self.id = id
            self.hiddenFor = hiddenFor
            self.blocked = blocked
        }
    }

    /// How long a tab must have been hidden to be eligible under `trigger`.
    public static func minimumHidden(for trigger: Trigger) -> TimeInterval {
        switch trigger {
        case .idle: idleInterval
        case .pressure(critical: false): pressureGrace
        case .pressure(critical: true): 0
        }
    }

    /// The tabs to hibernate, longest-hidden first — so that a caller which
    /// stops early (nothing does today, but the order is the useful one)
    /// gives up the coldest page rather than an arbitrary one.
    public static func victims(_ candidates: [Candidate], trigger: Trigger) -> [UUID] {
        let minimum = minimumHidden(for: trigger)
        return candidates
            .filter { candidate in
                guard !candidate.blocked, let hiddenFor = candidate.hiddenFor else { return false }
                return hiddenFor >= minimum
            }
            .sorted { ($0.hiddenFor ?? 0) > ($1.hiddenFor ?? 0) }
            .map(\.id)
    }
}

// MARK: - Sweeper

/// Process-wide, because memory is: two windows with eight tabs each are
/// sixteen content processes against one limit, and a per-window timer would
/// make the policy depend on how the user happened to arrange things.
@MainActor
public final class RAVETabHibernation {
    public static let shared = RAVETabHibernation()

    /// After a sweep that hibernated anything: how many, and why. Raven puts
    /// its memory footprint next to it, because the question this answers is
    /// always "did it give the memory back".
    public var onHibernated: ((Int, RAVETabHibernationPolicy.Trigger) -> Void)?

    private var tabs: [WeakTab] = []
    private var timer: DispatchSourceTimer?
    private var pressure: DispatchSourceMemoryPressure?

    private struct WeakTab {
        weak var tab: RAVEBrowserTab?
    }

    /// `shared` is the one an app wants: memory is process-wide. Separate
    /// sweepers are for tests.
    public init() {}

    /// Every tab registers itself at birth. Weak, so this is never why a tab
    /// outlives its window, and dead entries are swept out on the next pass.
    public func register(_ tab: RAVEBrowserTab) {
        tabs.removeAll { $0.tab == nil }
        tabs.append(WeakTab(tab: tab))
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard timer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + RAVETabHibernationPolicy.sweepInterval,
            repeating: RAVETabHibernationPolicy.sweepInterval,
            leeway: .seconds(10)
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { _ = self?.sweep(trigger: .idle) }
        }
        timer.resume()
        self.timer = timer

        // A source of its own even when the app has one (Raven's
        // `MemoryMonitor`), deliberately: that one is an instrument and this
        // one is a policy, and neither should have to know the other exists
        // to do its job.
        let pressure = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main
        )
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.pressure else { return }
                let critical = source.data.contains(.critical)
                self.sweep(trigger: .pressure(critical: critical))
            }
        }
        pressure.resume()
        self.pressure = pressure
    }

    /// Runs the policy and acts on it. Idempotent and cheap when there is
    /// nothing to do, which is the usual case — a sweep that hibernates
    /// nothing says nothing.
    @discardableResult
    public func sweep(trigger: RAVETabHibernationPolicy.Trigger, now: Date = Date()) -> Int {
        tabs.removeAll { $0.tab == nil }
        let live = tabs.compactMap(\.tab)
        let candidates = live.map { tab in
            RAVETabHibernationPolicy.Candidate(
                id: tab.id,
                hiddenFor: tab.hiddenSince.map { now.timeIntervalSince($0) },
                blocked: tab.hibernationBlocker != nil
            )
        }

        var hibernated = 0
        for id in RAVETabHibernationPolicy.victims(candidates, trigger: trigger) {
            guard let tab = live.first(where: { $0.id == id }) else { continue }
            if tab.hibernate(reason: trigger.reason) { hibernated += 1 }
        }
        if hibernated > 0 { onHibernated?(hibernated, trigger) }
        return hibernated
    }
}
#endif
