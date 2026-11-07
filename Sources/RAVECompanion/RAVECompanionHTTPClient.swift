/*
 RAVECompanion - HTTP/1.1 over a paired channel

 For a host that serves an HTTP API on its paired TLS-PSK channel (Vergence's
 analysis coordinator does: `VergenceAPI/v1`). URLSession can't offer an
 external PSK, so this speaks just enough HTTP/1.1 itself over
 Network.framework: one request at a time per connection, connections kept
 alive and reused, bodies framed by Content-Length or chunked, or read to the
 close. The channel's key schedule (`RAVECompanionChannel`) authenticates both
 ends, so no Authorization header is sent: a host that knows which PSK a
 connection used (OpenSSL can) knows the device from the handshake.

 Nothing here is specific to one host app; the paths, the payloads and what
 the statuses mean are the caller's.
 */

import DebugLog
import Foundation
import Network

public actor RAVECompanionHTTPClient {
    public struct Response: Sendable {
        public let status: Int
        /// Header names lowercased; a repeated header keeps its last value.
        public let headers: [String: String]
        public let body: Data

        public func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    public enum Failure: Error, Sendable, Equatable {
        /// No address answered, or the TLS handshake failed (an unknown device, or a wrong key).
        case unreachable(String)
        /// The host closed the connection before the response was whole.
        case closed
        case malformed(String)
        case timedOut
        /// A header block or body over the client's limit.
        case tooLarge
    }

    public nonisolated let hosts: [String]
    public nonisolated let port: UInt16
    private let channel: RAVECompanionChannel
    private let credential: RAVECompanionCredential
    private let timeout: Duration
    private let maxIdle: Int
    private let maxBodyBytes: Int
    private var idle: [Connection] = []
    /// The address that answered last, tried first next time.
    private var preferred = 0

    private static let log = DebugLogger(subsystem: "com.illixion.rave", category: "CompanionHTTP")

    /// - Parameter hosts: addresses or names to try in turn (the pairing's own address first).
    /// - Parameter timeout: for connecting plus one whole exchange.
    public init(channel: RAVECompanionChannel, credential: RAVECompanionCredential, hosts: [String], port: UInt16,
                timeout: Duration = .seconds(15), maxIdle: Int = 4, maxBodyBytes: Int = 256 << 20) {
        self.channel = channel
        self.credential = credential
        self.hosts = hosts
        self.port = port
        self.timeout = timeout
        self.maxIdle = maxIdle
        self.maxBodyBytes = maxBodyBytes
    }

    /// Sends one request and returns the whole response. A kept-alive connection the host has
    /// since closed is replaced, and the request sent again, once.
    public func send(_ method: String, _ path: String, headers: [String: String] = [:],
                     body: Data? = nil) async throws -> Response {
        let request = Self.encode(method: method, path: path, host: hosts.first ?? "", headers: headers, body: body)
        let expectsBody = method.uppercased() != "HEAD"
        if let reused = idle.popLast() {
            do {
                return try await exchange(on: reused, request, expectsBody: expectsBody, reused: true)
            } catch Retry.staleConnection {
                Self.log.debug("A kept-alive connection had closed; reconnecting")
            }
        }
        let fresh = try await connect()
        return try await exchange(on: fresh, request, expectsBody: expectsBody, reused: false)
    }

    /// Closes every idle connection.
    public func closeAll() {
        idle.forEach { $0.cancel() }
        idle.removeAll()
    }

    private enum Retry: Error { case staleConnection }

    private func exchange(on connection: Connection, _ request: Data, expectsBody: Bool,
                          reused: Bool) async throws -> Response {
        let limit = maxBodyBytes
        let timeout = timeout
        let result: (Response, Bool)
        do {
            result = try await Self.withTimeout(timeout, cancelling: connection) {
                try await connection.send(request)
                return try await Self.readResponse(connection, expectsBody: expectsBody, maxBody: limit)
            }
        } catch let failure as Failure {
            connection.cancel()
            // A reused connection that died before answering a single byte: the host closed it
            // while it sat idle, so the request never reached it.
            if reused, connection.receivedNothing, failure != .timedOut { throw Retry.staleConnection }
            throw failure
        } catch {
            connection.cancel()
            if reused, connection.receivedNothing { throw Retry.staleConnection }
            throw Failure.closed
        }
        let (response, reusable) = result
        if reusable, idle.count < maxIdle {
            connection.reset()
            idle.append(connection)
        } else {
            connection.cancel()
        }
        return response
    }

    /// Dials the hosts in turn, the last one that answered first.
    private func connect() async throws -> Connection {
        guard !hosts.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw Failure.unreachable("no address")
        }
        let order = hosts.indices.map { (preferred + $0) % hosts.count }
        var lastReason = "no address answered"
        for index in order {
            let parameters = channel.tcpParameters(credentials: [credential], connectionTimeout: 5)
            let connection = Connection(NWConnection(host: NWEndpoint.Host(hosts[index]), port: nwPort, using: parameters))
            do {
                try await Self.withTimeout(timeout, cancelling: connection) { try await connection.open() }
                preferred = index
                return connection
            } catch {
                connection.cancel()
                lastReason = "\(error)"
            }
        }
        throw Failure.unreachable(lastReason)
    }

    // MARK: HTTP/1.1

    static func encode(method: String, path: String, host: String, headers: [String: String], body: Data?) -> Data {
        let hostHeader = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(hostHeader)\r\n"
        let lowered = Set(headers.keys.map { $0.lowercased() })
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        if !lowered.contains("content-length") {
            head += "Content-Length: \(body?.count ?? 0)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        if let body { data.append(body) }
        return data
    }

    /// The response, and whether the connection can carry another request.
    static func readResponse(_ connection: Connection, expectsBody: Bool, maxBody: Int) async throws -> (Response, Bool) {
        while true {
            let headerEnd = try await connection.readUntil(Data("\r\n\r\n".utf8), limit: 64 << 10)
            let head = connection.take(headerEnd)
            guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else {
                throw Failure.malformed("header encoding")
            }
            var lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
            guard !lines.isEmpty else { throw Failure.malformed("empty response") }
            let statusLine = lines.removeFirst()
            let parts = statusLine.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]) else {
                throw Failure.malformed("status line")
            }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { throw Failure.malformed("header line") }
                headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            // An interim response (100 Continue): the real one follows.
            if (100..<200).contains(status) && status != 101 { continue }

            var reusable = parts[0] == "HTTP/1.1" && headers["connection"]?.lowercased() != "close"
            let body: Data
            if !expectsBody || status == 204 || status == 304 {
                body = Data()
            } else if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
                body = try await readChunked(connection, maxBody: maxBody)
            } else if let lengthText = headers["content-length"] {
                guard let length = Int(lengthText), length >= 0 else { throw Failure.malformed("content-length") }
                guard length <= maxBody else { throw Failure.tooLarge }
                try await connection.fill(length)
                body = connection.take(length)
            } else {
                body = try await connection.readToEnd(limit: maxBody)
                reusable = false
            }
            return (Response(status: status, headers: headers, body: body), reusable)
        }
    }

    static func readChunked(_ connection: Connection, maxBody: Int) async throws -> Data {
        var body = Data()
        while true {
            let lineEnd = try await connection.readUntil(Data("\r\n".utf8), limit: 1024)
            let line = String(decoding: connection.take(lineEnd), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let sizeText = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else { throw Failure.malformed("chunk size") }
            if size == 0 {
                // Trailers, then the blank line.
                while true {
                    let end = try await connection.readUntil(Data("\r\n".utf8), limit: 8 << 10)
                    if connection.take(end).count == 2 { return body }
                }
            }
            guard body.count + size <= maxBody else { throw Failure.tooLarge }
            try await connection.fill(size + 2)
            body.append(connection.take(size))
            guard connection.take(2) == Data("\r\n".utf8) else { throw Failure.malformed("chunk end") }
        }
    }

    static func withTimeout<T: Sendable>(_ timeout: Duration, cancelling connection: Connection,
                                         _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                // Ends whatever receive or send is outstanding.
                connection.markTimedOut()
                connection.cancel()
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            do {
                guard let first = try await group.next() else { throw Failure.timedOut }
                return first
            } catch {
                throw connection.timedOut ? Failure.timedOut : error
            }
        }
    }

    // MARK: Connection

    /// One NWConnection and what it has received but not yet consumed. Used by one exchange at a
    /// time; the lock covers the callbacks Network.framework makes on its own queue.
    final class Connection: @unchecked Sendable {
        let nw: NWConnection
        private let lock = NSLock()
        private var buffer = Data()
        private var ended = false
        private var receivedAny = false
        private var didTimeOut = false
        private static let queue = DispatchQueue(label: "RAVECompanionHTTPClient")

        init(_ nw: NWConnection) { self.nw = nw }

        var receivedNothing: Bool { lock.withLock { !receivedAny } }
        var timedOut: Bool { lock.withLock { didTimeOut } }
        func markTimedOut() { lock.withLock { didTimeOut = true } }

        /// Forgets what the last exchange left, before the connection goes back to the pool.
        func reset() { lock.withLock { receivedAny = false } }

        func cancel() { nw.cancel() }

        func open() async throws {
            let once = Once()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                nw.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        once.run { continuation.resume() }
                    case .failed(let error), .waiting(let error):
                        once.run { continuation.resume(throwing: Failure.unreachable("\(error)")) }
                    case .cancelled:
                        once.run { continuation.resume(throwing: Failure.unreachable("cancelled")) }
                    default:
                        break
                    }
                }
                nw.start(queue: Self.queue)
            }
        }

        func send(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                nw.send(content: data, completion: .contentProcessed { error in
                    if error != nil { continuation.resume(throwing: Failure.closed) } else { continuation.resume() }
                })
            }
        }

        /// Receives once more into the buffer; false at the end of the stream.
        private func receiveMore() async throws -> Bool {
            if lock.withLock({ ended }) { return false }
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                nw.receive(minimumIncompleteLength: 1, maximumLength: 256 << 10) { [self] data, _, isComplete, error in
                    let got = lock.withLock { () -> Bool in
                        if let data, !data.isEmpty {
                            buffer.append(data)
                            receivedAny = true
                        }
                        if isComplete { ended = true }
                        return !(data?.isEmpty ?? true)
                    }
                    if got {
                        continuation.resume(returning: true)
                    } else if error != nil {
                        continuation.resume(throwing: Failure.closed)
                    } else {
                        continuation.resume(returning: !isComplete)
                    }
                }
            }
        }

        /// The length up to and including `marker`, receiving until it arrives.
        func readUntil(_ marker: Data, limit: Int) async throws -> Int {
            while true {
                let found: Int? = lock.withLock {
                    buffer.range(of: marker).map { $0.upperBound - buffer.startIndex }
                }
                if let found { return found }
                if lock.withLock({ buffer.count }) > limit { throw Failure.tooLarge }
                guard try await receiveMore() else { throw Failure.closed }
            }
        }

        /// Receives until at least `count` bytes are buffered.
        func fill(_ count: Int) async throws {
            while lock.withLock({ buffer.count }) < count {
                guard try await receiveMore() else { throw Failure.closed }
            }
        }

        func readToEnd(limit: Int) async throws -> Data {
            while try await receiveMore() {
                if lock.withLock({ buffer.count }) > limit { throw Failure.tooLarge }
            }
            return take(lock.withLock { buffer.count })
        }

        /// Removes and returns the first `count` buffered bytes.
        func take(_ count: Int) -> Data {
            lock.withLock {
                let out = Data(buffer.prefix(count))
                buffer = Data(buffer.dropFirst(count))
                return out
            }
        }
    }

    /// Runs its closure the first time only (a continuation resumes once).
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
}
