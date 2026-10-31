//
//  RAVEConsentCenter.swift
//  RAVEConsent
//
//  Asks the person before personal data leaves an app's hands: what it is,
//  where it goes, and a preview of exactly what would be sent. Allow once,
//  allow for 15 minutes, or don't.
//
//  Why this is a RAVESDK target and not part of DebugTrace: DebugTrace's own
//  approval is a development tool's ("may this Mac client read my logs?") and
//  its server is left out of submission builds. This is a product feature that
//  ships: a character that reads Health data has to ask in the App Store build
//  too. DebugTrace could not import it either way, since RAVESDK depends on
//  DebugTrace.
//
//  The center holds the rules and nothing about screens: grants, the one
//  question waiting, the history. A presenter shows the question (a window on
//  visionOS and macOS, where an immersive space has nothing a system alert
//  could attach to; a sheet on iOS and tvOS); `raveConsentPrompts()` wires one.
//
//  Grants are in memory only: quitting the app revokes them. Debug endpoints
//  may read `status` and `revoke`, never answer: that is the person's tap.
//

import Foundation
import Observation

@MainActor
@Observable
public final class RAVEConsentCenter {
    public static let shared = RAVEConsentCenter()
    /// How long "for 15 Minutes" lasts.
    public static let defaultGrantDuration: TimeInterval = 15 * 60

    /// The question waiting for an answer; nil when none.
    public private(set) var request: RAVEConsentRequest?
    /// Live grants. Expired ones are dropped as they are noticed.
    public private(set) var grants: [RAVEConsentGrant] = []

    /// What shows the question. `raveConsentPrompts()` sets it; with none,
    /// every question is a no.
    @ObservationIgnored public var presenter: (any RAVEConsentPresenting)?

    @ObservationIgnored public let grantDuration: TimeInterval
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var answer: ((RAVEConsentDecision) -> Void)?
    @ObservationIgnored private var log: [[String: Any]] = []

    public init(grantDuration: TimeInterval = RAVEConsentCenter.defaultGrantDuration,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.grantDuration = grantDuration
        self.now = now
    }

    // MARK: - Grants

    /// A live grant for this kind to this destination, if there is one.
    public func grant(for kind: RAVEConsentKind, to destination: RAVEConsentDestination) -> RAVEConsentGrant? {
        let t = now()
        return grants.first { $0.kind == kind && $0.destination == destination && $0.until > t }
    }

    /// Ends the grants for `kind`, or all of them.
    public func revoke(_ kind: RAVEConsentKind? = nil) {
        grants.removeAll { kind == nil || $0.kind == kind }
    }

    // MARK: - Asking

    /// Checks for a live grant first: `.granted` when one covers it, nobody
    /// asked. Otherwise asks, as `ask` does.
    public func authorize(_ request: RAVEConsentRequest) async -> RAVEConsentDecision {
        if grant(for: request.kind, to: request.destination) != nil { return .granted }
        return await ask(request)
    }

    /// Always asks, replacing a question still waiting (which answers
    /// `.superseded`). A no when nothing could show it, never a yes.
    public func ask(_ request: RAVEConsentRequest) async -> RAVEConsentDecision {
        if self.request != nil { respond(.superseded) }
        guard let presenter else {
            RAVEConsentLog.consent.error("A \(request.kind.id, privacy: .public) question had nothing to show it in")
            return .deny
        }
        self.request = request
        var decision = await withCheckedContinuation { continuation in
            // The answer is ready before the question is shown, so a tap
            // that beats `present` returning is not lost.
            self.answer = { continuation.resume(returning: $0) }
            Task {
                if await presenter.present(for: self) == false, self.request?.id == request.id {
                    self.respond(.deny)
                }
            }
        }
        // The grant is the request's to offer: a stray `.forAWhile` is a once.
        if decision == .forAWhile, !request.offersGrant { decision = .once }
        if decision == .forAWhile {
            let t = now()
            grants.removeAll { ($0.kind == request.kind && $0.destination == request.destination) || $0.until <= t }
            grants.append(RAVEConsentGrant(kind: request.kind, destination: request.destination,
                                           until: t.addingTimeInterval(grantDuration)))
        }
        record(request, decision)
        // A superseding question already owns the screen.
        guard decision != .superseded else { return decision }
        self.request = nil
        presenter.finished(for: self)
        return decision
    }

    /// The person's answer to the question waiting. Nothing waiting: ignored.
    public func respond(_ decision: RAVEConsentDecision) {
        let resume = answer
        answer = nil
        resume?(decision)
    }

    /// The presenter was closed with a question up: that is a no.
    public func closedUnanswered() {
        guard request != nil else { return }
        respond(.deny)
    }

    // MARK: - Reporting

    private func record(_ request: RAVEConsentRequest, _ decision: RAVEConsentDecision) {
        log.append(["at": now().timeIntervalSince1970, "kind": request.kind.id,
                    "destination": request.destination.key, "decision": decision.rawValue])
        if log.count > 20 { log.removeFirst(log.count - 20) }
        RAVEConsentLog.consent.info("Consent for a \(request.kind.id, privacy: .public) to \(request.destination.key, privacy: .private(mask: .hash)): \(decision.rawValue, privacy: .public)")
    }

    /// For a debug endpoint: ids, destinations, times and decisions only.
    /// Never a title, detail or preview, which can hold the data itself.
    public var status: [String: Any] {
        let t = now()
        return [
            "waiting": request.map { ["kind": $0.kind.id, "destination": $0.destination.key] } as Any,
            "grants": grants.filter { $0.until > t }.map {
                ["kind": $0.kind.id, "destination": $0.destination.key, "secondsLeft": Int($0.until.timeIntervalSince(t))]
            },
            "history": log,
        ]
    }
}

/// Shows the question in `center.request` and hides it again.
@MainActor
public protocol RAVEConsentPresenting: AnyObject {
    /// Makes the question visible. False when it cannot be shown right now,
    /// which the center takes as a no. A tap may come before this returns.
    func present(for center: RAVEConsentCenter) async -> Bool
    /// The question was answered and `center.request` is clear; hide it. Free
    /// to wait a moment in case the next question follows at once.
    func finished(for center: RAVEConsentCenter)
}
