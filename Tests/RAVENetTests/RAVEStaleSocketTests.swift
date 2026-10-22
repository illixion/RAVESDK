/*
 Calls the app decides on one socket must not land on its replacement.

 Regression for Spatial Home halting overnight: the app handled an `auth_ok`,
 but by the time its `markReady()` reached the transport a pong timeout had
 already swapped in a fresh socket. The fresh, unauthenticated socket was
 promoted, its keepalive pinged into Home Assistant's auth phase, HA answered
 `auth_invalid`, and the app halted for good.

 Runs against a real loopback WebSocket server (Network.framework), which
 greets every socket with one frame, as Home Assistant's `auth_required` does.
 */

#if canImport(Network)
import Foundation
import Network
import Testing
@testable import RAVENet

@Suite("RAVEWebSocketTransport stale-socket calls")
struct RAVEStaleSocketTests {

    @Test("markReady decided on a replaced socket is dropped; one on the current socket lands")
    func staleReadyIsDropped() async throws {
        let server = try await GreetingServer.start()
        defer { server.stop() }

        let transport = RAVEWebSocketTransport(
            configuration: .init(url: server.url),
            logger: RAVENetSilentLogger(),
            pingFrameProvider: { nil }
        )
        var events = transport.events.makeAsyncIterator()
        await transport.start()

        var seenFrames = 0
        func nextFrame() async throws -> String {
            while let event = await events.next() {
                if case .frame(let text) = event {
                    seenFrames += 1
                    return text
                }
            }
            throw CancellationError()
        }

        #expect(try await nextFrame() == "hello 1")
        let decidedOnFirstSocket = seenFrames

        // The socket is replaced before the app's decision reaches the transport.
        await transport.forceReconnectNow()
        await transport.markReady(seenFrames: decidedOnFirstSocket)
        #expect(await transport.currentState == .connecting)
        // A send meant for the old socket is dropped too: the server would
        // otherwise echo it back as the next frame.
        await transport.send("for the old socket", seenFrames: decidedOnFirstSocket)

        #expect(try await nextFrame() == "hello 2")
        await transport.send("for the new socket", seenFrames: seenFrames)
        #expect(try await nextFrame() == "echo for the new socket")

        await transport.markReady(seenFrames: seenFrames)
        #expect(await transport.currentState == .ready)
        await transport.stop()
    }
}

/// Loopback WebSocket server: greets each connection with "hello N", then
/// echoes what it receives as "echo <text>".
private final class GreetingServer: @unchecked Sendable {
    let listener: NWListener
    let url: URL
    private let queue = DispatchQueue(label: "rave.net.test.server")
    private var connections = 0

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.url = URL(string: "ws://127.0.0.1:\(port)/")!
    }

    static func start() async throws -> GreetingServer {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "rave.net.test.listener")
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.set() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.set() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: queue)
        }
        let server = GreetingServer(listener: listener, port: port)
        listener.newConnectionHandler = { [server] connection in server.accept(connection) }
        return server
    }

    func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        queue.async { [self] in
            connections += 1
            let greeting = "hello \(connections)"
            connection.start(queue: queue)
            send(greeting, on: connection)
            receive(on: connection)
        }
    }

    private func send(_ text: String, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in })
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [self] data, _, _, error in
            guard error == nil else { return }
            if let data, let text = String(data: data, encoding: .utf8) {
                send("echo \(text)", on: connection)
            }
            receive(on: connection)
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    /// True the first time only.
    func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if isSet { return false }
        isSet = true
        return true
    }
}
#endif
