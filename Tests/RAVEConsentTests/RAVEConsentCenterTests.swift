import Foundation
import Testing
@testable import RAVEConsent

extension RAVEConsentKind {
    static let screenshot = RAVEConsentKind("screenshot")
    static let weighIns = RAVEConsentKind("weighIns")
}

/// Stands in for the window or sheet: answers each question from a script,
/// from inside `present`, the way a fast tap would. A nil entry leaves the
/// question waiting.
@MainActor
final class StubPresenter: RAVEConsentPresenting {
    var script: [RAVEConsentDecision?] = []
    var canShow = true
    private(set) var shown: [RAVEConsentRequest] = []
    private(set) var finishedCount = 0

    func present(for center: RAVEConsentCenter) async -> Bool {
        guard canShow, let request = center.request else { return false }
        shown.append(request)
        if !script.isEmpty, let answer = script.removeFirst() { center.respond(answer) }
        return true
    }

    func finished(for center: RAVEConsentCenter) { finishedCount += 1 }
}

/// A clock the tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var date: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

@MainActor
@Suite struct RAVEConsentCenterTests {
    let clock = TestClock()
    let presenter = StubPresenter()
    let center: RAVEConsentCenter

    let device = RAVEConsentDestination(key: "onDevice", summary: "On this device.", leavesDevice: false)
    let server = RAVEConsentDestination(key: "ollama:mac", summary: "To Ollama on the Mac.", leavesDevice: true)

    init() {
        let clock = clock
        center = RAVEConsentCenter(now: { clock.date })
        center.presenter = presenter
    }

    private func request(_ kind: RAVEConsentKind = .screenshot, to destination: RAVEConsentDestination? = nil,
                         preview: RAVEConsentPreview = .none, offersGrant: Bool = true) -> RAVEConsentRequest {
        RAVEConsentRequest(kind: kind, destination: destination ?? server, title: "Show this?", detail: "Why.",
                           preview: preview, offersGrant: offersGrant)
    }

    @Test func onceAllowsOnlyThisTime() async {
        presenter.script = [.once, .once]
        #expect(await center.authorize(request()) == .once)
        #expect(center.grants.isEmpty)
        // No grant, so the next one asks again.
        #expect(await center.authorize(request()) == .once)
        #expect(presenter.shown.count == 2)
    }

    @Test func aGrantCoversTheSameKindToTheSamePlaceUntilItRunsOut() async {
        presenter.script = [.forAWhile]
        #expect(await center.authorize(request()) == .forAWhile)
        #expect(await center.authorize(request()) == .granted)
        #expect(presenter.shown.count == 1)

        clock.advance(14 * 60)
        #expect(await center.authorize(request()) == .granted)
        clock.advance(61)
        presenter.script = [.deny]
        #expect(await center.authorize(request()) == .deny)
        #expect(presenter.shown.count == 2)
        #expect(center.grant(for: .screenshot, to: server) == nil)
    }

    @Test func aGrantIsForOneKindAndOneDestination() async {
        presenter.script = [.forAWhile, .deny, .deny]
        _ = await center.authorize(request(.screenshot, to: server))
        // Another kind to the same place, and the same kind somewhere else, each ask.
        #expect(await center.authorize(request(.weighIns, to: server)) == .deny)
        #expect(await center.authorize(request(.screenshot, to: device)) == .deny)
        #expect(presenter.shown.count == 3)
        #expect(center.grant(for: .screenshot, to: server) != nil)
    }

    @Test func aNewGrantReplacesTheOldAndRevokeEndsThem() async {
        presenter.script = [.forAWhile, .forAWhile]
        _ = await center.ask(request())
        clock.advance(600)
        _ = await center.ask(request())
        #expect(center.grants.count == 1)
        #expect(center.grants[0].until == clock.date.addingTimeInterval(RAVEConsentCenter.defaultGrantDuration))

        presenter.script = [.forAWhile]
        _ = await center.ask(request(.weighIns))
        center.revoke(.screenshot)
        #expect(center.grants.map(\.kind) == [.weighIns])
        center.revoke()
        #expect(center.grants.isEmpty)
    }

    @Test func noPresenterOrNoWindowIsANo() async {
        presenter.canShow = false
        #expect(await center.ask(request()) == .deny)
        #expect(center.request == nil && center.grants.isEmpty)

        let bare = RAVEConsentCenter()
        #expect(await bare.ask(request()) == .deny)
    }

    @Test func aRequestThatOffersNoGrantNeverMakesOne() async {
        presenter.script = [.forAWhile]
        let decision = await center.ask(request(offersGrant: false))
        #expect(decision == .once)
        #expect(center.grants.isEmpty)
    }

    @Test func aNewQuestionSupersedesOneStillWaiting() async {
        presenter.script = [nil, nil]
        let first = Task { await center.ask(request(.screenshot)) }
        while presenter.shown.count < 1 { await Task.yield() }
        let second = Task { await center.ask(request(.weighIns)) }
        #expect(await first.value == .superseded)
        while presenter.shown.count < 2 { await Task.yield() }
        // The window stays for the second: nothing finished yet, and it is the one waiting.
        #expect(presenter.finishedCount == 0)
        #expect(center.request?.kind == .weighIns)
        center.respond(.once)
        #expect(await second.value == .once)
        #expect(presenter.finishedCount == 1 && center.request == nil)
    }

    @Test func closingTheWindowWithAQuestionUpIsANo() async {
        presenter.script = [nil]
        let asked = Task { await center.ask(request()) }
        while presenter.shown.isEmpty { await Task.yield() }
        center.closedUnanswered()
        #expect(await asked.value == .deny)
        // Nothing waiting: closing is nothing.
        center.closedUnanswered()
        center.respond(.once)
        #expect(center.request == nil)
    }

    @Test func statusAndHistoryNeverCarryThePayload() async throws {
        let secret = "Weight 72.4 kg on 3 Oct"
        presenter.script = [.forAWhile]
        let asked = RAVEConsentRequest(kind: .weighIns, destination: server, title: secret, detail: secret,
                                       preview: .text(secret))
        _ = await center.ask(asked)
        for _ in 0..<25 {
            presenter.script = [.once]
            _ = await center.ask(request())
        }
        let status = center.status
        let text = String(describing: status)
        #expect(!text.contains("72.4") && !text.contains("Show this?"))
        #expect((status["history"] as? [[String: Any]])?.count == 20)
        let grants = try #require(status["grants"] as? [[String: Any]])
        #expect(grants.count == 1 && grants[0]["kind"] as? String == "weighIns")
    }

    @Test func aKindAndADestinationAreKnownByTheirKey() {
        #expect(RAVEConsentKind("a") == RAVEConsentKind("a"))
        let reworded = RAVEConsentDestination(key: "onDevice", summary: "Reworded.", leavesDevice: false)
        #expect(reworded == device)
    }
}
