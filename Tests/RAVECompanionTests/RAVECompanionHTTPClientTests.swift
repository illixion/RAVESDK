import Foundation
import Network
import Testing
@testable import RAVECompanion

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}

/// A TLS-PSK HTTP/1.1 server on loopback that answers by path, counting connections.
private final class TestServer: @unchecked Sendable {
    let listener: NWListener
    private let lock = NSLock()
    private var accepted = 0
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "TestServer")

    var connectionCount: Int { lock.withLock { accepted } }

    init(channel: RAVECompanionChannel, credential: RAVECompanionCredential) async throws {
        listener = try NWListener(using: channel.tcpParameters(credentials: [credential]), on: .any)
        listener.newConnectionHandler = { [self] connection in
            lock.withLock {
                accepted += 1
                connections.append(connection)
            }
            connection.start(queue: queue)
            serve(connection, buffer: Data())
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                if case .ready = state { once.run { continuation.resume() } }
            }
            listener.start(queue: queue)
        }
    }

    var port: UInt16 { listener.port!.rawValue }

    /// Closes every connection the server holds, as a host does with idle keep-alives.
    func dropConnections() {
        lock.withLock {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    func stop() {
        dropConnections()
        listener.cancel()
    }

    private func serve(_ connection: NWConnection, buffer: Data) {
        if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let path = lines[0].split(separator: " ")[1]
            let length = lines.first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            let bodyStart = end.upperBound
            if buffer.count - (bodyStart - buffer.startIndex) >= length {
                let body = Data(buffer[bodyStart..<(bodyStart + length)])
                let rest = Data(buffer[(bodyStart + length)...])
                let (reply, close) = respond(String(path), body: body, head: head)
                connection.send(content: reply, completion: .contentProcessed { _ in
                    if close { connection.cancel() } else { self.serve(connection, buffer: rest) }
                })
                return
            }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            guard let data, error == nil else { return }
            serve(connection, buffer: buffer + data)
            if isComplete && data.isEmpty { connection.cancel() }
        }
    }

    private func respond(_ path: String, body: Data, head: String) -> (Data, Bool) {
        switch path {
        case "/echo":
            var reply = Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nX-Head: \(head.contains("Authorization") ? "auth" : "none")\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
            reply.append(body)
            return (reply, false)
        case "/chunked":
            let reply = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=1\r\nhello\r\n7\r\n, world\r\n0\r\nX-Trailer: t\r\n\r\n"
            return (Data(reply.utf8), false)
        case "/close":
            return (Data("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n{\"state\":\"none\"}".utf8), true)
        case "/big":
            let big = Data((0..<3_000_000).map { UInt8($0 % 251) })
            var reply = Data("HTTP/1.1 200 OK\r\nContent-Length: \(big.count)\r\nVergence-Chunk-Complete: false\r\n\r\n".utf8)
            reply.append(big)
            return (reply, false)
        default:
            return (Data("HTTP/1.1 204 No Content\r\n\r\n".utf8), false)
        }
    }
}

@Suite("HTTP over a paired channel", .serialized)
struct CompanionHTTPClientTests {
    let channel = RAVECompanionChannel(identityBase: "TestAPI/v1", salt: "Test-API-PSK-v1")
    let credential = RAVECompanionCredential(token: "device-token", deviceID: "HS-1")

    @Test("requests share a kept-alive connection; bodies by length, chunks or close")
    func keepAlive() async throws {
        let server = try await TestServer(channel: channel, credential: credential)
        defer { server.stop() }
        let client = RAVECompanionHTTPClient(channel: channel, credential: credential, hosts: ["127.0.0.1"],
                                             port: server.port, timeout: .seconds(10))
        let echoed = try await client.send("POST", "/echo", headers: ["Content-Type": "application/json"],
                                           body: Data("{\"a\":1}".utf8))
        #expect(echoed.status == 200)
        #expect(echoed.body == Data("{\"a\":1}".utf8))
        #expect(echoed.header("x-head") == "none")
        let chunked = try await client.send("GET", "/chunked")
        #expect(String(decoding: chunked.body, as: UTF8.self) == "hello, world")
        let empty = try await client.send("GET", "/nothing")
        #expect(empty.status == 204 && empty.body.isEmpty)
        let big = try await client.send("GET", "/big")
        #expect(big.body.count == 3_000_000 && big.body[250] == 250 && big.header("Vergence-Chunk-Complete") == "false")
        #expect(server.connectionCount == 1)
        // Read to the close, and the next request needs a new connection.
        let closing = try await client.send("GET", "/close")
        #expect(closing.status == 404 && String(decoding: closing.body, as: UTF8.self) == "{\"state\":\"none\"}")
        _ = try await client.send("GET", "/nothing")
        #expect(server.connectionCount == 2)
    }

    @Test("a kept-alive connection the host closed is replaced")
    func staleConnection() async throws {
        let server = try await TestServer(channel: channel, credential: credential)
        defer { server.stop() }
        let client = RAVECompanionHTTPClient(channel: channel, credential: credential, hosts: ["127.0.0.1"],
                                             port: server.port, timeout: .seconds(10))
        _ = try await client.send("GET", "/nothing")
        server.dropConnections()
        try await Task.sleep(for: .milliseconds(100))
        let again = try await client.send("POST", "/echo", body: Data("x".utf8))
        #expect(again.body == Data("x".utf8))
        #expect(server.connectionCount == 2)
    }

    @Test("a wrong key, or no address answering, is unreachable; the next address is tried")
    func refused() async throws {
        let server = try await TestServer(channel: channel, credential: credential)
        defer { server.stop() }
        let stranger = RAVECompanionHTTPClient(
            channel: channel, credential: RAVECompanionCredential(token: "wrong", deviceID: "HS-1"),
            hosts: ["127.0.0.1"], port: server.port, timeout: .seconds(5))
        await #expect(throws: RAVECompanionHTTPClient.Failure.self) { try await stranger.send("GET", "/nothing") }
        // A dead address first, then the live one.
        let fallback = RAVECompanionHTTPClient(channel: channel, credential: credential,
                                               hosts: ["127.0.0.2", "127.0.0.1"], port: server.port, timeout: .seconds(10))
        #expect(try await fallback.send("GET", "/nothing").status == 204)
    }

    @Test("requests are encoded as HTTP/1.1 with a length")
    func encoding() {
        let get = String(decoding: RAVECompanionHTTPClient.encode(method: "GET", path: "/v1/health", host: "fe80::1",
                                                                  headers: [:], body: nil), as: UTF8.self)
        #expect(get == "GET /v1/health HTTP/1.1\r\nHost: [fe80::1]\r\nContent-Length: 0\r\n\r\n")
        let post = RAVECompanionHTTPClient.encode(method: "POST", path: "/x", host: "10.0.0.2",
                                                  headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        #expect(String(decoding: post, as: UTF8.self)
            == "POST /x HTTP/1.1\r\nHost: 10.0.0.2\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}")
    }
}
