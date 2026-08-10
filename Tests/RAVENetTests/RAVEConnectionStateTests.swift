/*
 Tests for the connection state machine and the app-declared readiness seam.

 The central invariant: the transport never promotes itself to `.ready`. Both
 source implementations disagreed on what "connected" means (first inbound
 frame vs. an `auth_ok` frame), which is exactly why the app declares it.
 */

import Foundation
import Testing
@testable import RAVENet

@Suite("RAVEConnectionState")
struct RAVEConnectionStateTests {

    @Test("Only .ready reports as ready")
    func readinessIsExact() {
        #expect(RAVEConnectionState.ready.isReady)
        #expect(!RAVEConnectionState.idle.isReady)
        #expect(!RAVEConnectionState.connecting.isReady)
        // A half-authenticated socket must never count as usable.
        #expect(!RAVEConnectionState.handshaking.isReady)
        #expect(!RAVEConnectionState.suspended.isReady)
        #expect(!RAVEConnectionState.failed("bad token").isReady)
    }

    @Test("Failure reasons participate in equality")
    func failureEquality() {
        #expect(RAVEConnectionState.failed("a") == RAVEConnectionState.failed("a"))
        #expect(RAVEConnectionState.failed("a") != RAVEConnectionState.failed("b"))
    }
}

@Suite("RAVEWebSocketTransport state guards")
struct RAVEWebSocketTransportStateTests {

    private func makeTransport() -> RAVEWebSocketTransport {
        RAVEWebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.invalid/ws")!),
            logger: RAVENetSilentLogger(),
            pingFrameProvider: { nil }
        )
    }

    @Test("A fresh transport is idle")
    func startsIdle() async {
        let transport = makeTransport()
        #expect(await transport.currentState == .idle)
        #expect(await transport.isReady == false)
    }

    @Test("markReady is ignored unless a connection is in flight")
    func readyRequiresConnecting() async {
        // Guards against an app declaring readiness on a transport that has no
        // socket — which would strand consumers on a connection that never was.
        let transport = makeTransport()
        await transport.markReady()
        #expect(await transport.currentState == .idle)
    }

    @Test("markHandshaking is ignored unless a connection is in flight")
    func handshakingRequiresConnecting() async {
        let transport = makeTransport()
        await transport.markHandshaking()
        #expect(await transport.currentState == .idle)
    }

    @Test("halt moves to failed and carries the reason")
    func haltFails() async {
        let transport = makeTransport()
        await transport.halt(reason: "Invalid access token")
        #expect(await transport.currentState == .failed("Invalid access token"))
    }

    @Test("halt suppresses subsequent reconnect attempts")
    func haltSuppressesRevive() async {
        let transport = makeTransport()
        await transport.halt(reason: "Invalid access token")
        // reviveIfIdle must not resurrect a halted transport — retrying cannot
        // fix a rejected token, and Spatial Stash's broker keeps closing the
        // upgrade for the same reason every time.
        await transport.reviveIfIdle()
        #expect(await transport.currentState == .failed("Invalid access token"))
        await transport.forceReconnectNow()
        #expect(await transport.currentState == .failed("Invalid access token"))
    }

    @Test("State transitions are published on the event stream")
    func transitionsAreObservable() async {
        let transport = makeTransport()
        let events = transport.events

        await transport.halt(reason: "nope")

        var seen: RAVEConnectionState?
        for await event in events {
            if case .stateChanged(let state) = event {
                seen = state
                break
            }
        }
        #expect(seen == .failed("nope"))
    }

    @Test("Repeated identical transitions are collapsed")
    func duplicateTransitionsCollapse() async {
        let transport = makeTransport()
        let events = transport.events

        await transport.halt(reason: "same")
        await transport.halt(reason: "same")
        await transport.stop()

        // Expect exactly one .failed("same") before the .idle from stop().
        var states: [RAVEConnectionState] = []
        for await event in events {
            if case .stateChanged(let state) = event {
                states.append(state)
                if state == .idle { break }
            }
        }
        #expect(states == [.failed("same"), .idle])
    }
}
