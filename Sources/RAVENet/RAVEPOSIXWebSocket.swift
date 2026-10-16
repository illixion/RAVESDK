/*
 RAVENet - POSIX WebSocket client

 RFC 6455 over a plain TCP socket, for `ws://` on Linux. FoundationNetworking's
 `URLSessionWebSocketTask` (libcurl underneath) spins its dispatch threads
 while a socket is open: an idle connection costs most of a core, which on a
 Pi 3 is a third of the machine. This client blocks a single reader thread
 in `recv` instead and costs nothing while nothing arrives.

 Scope is what the transport needs and no more: text and binary messages
 (fragmented ones reassembled), answering pings, and the close handshake.
 No TLS (`wss://` keeps URLSession), no extensions, no subprotocols. The
 server's `Sec-WebSocket-Accept` isn't verified (that needs SHA-1, which
 Foundation on Linux doesn't have); a 101 with `Upgrade: websocket` is
 accepted, which is all a misdirected request could fake anyway.

 Errors are `URLError`s with the codes URLSession uses for the same failure,
 and a server's close frame sets `closeCode`, so the transport's failure
 policy reads the same on either backend.
 */

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class RAVEPOSIXWebSocket: @unchecked Sendable {
    private let request: URLRequest
    private let timeout: TimeInterval

    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var isOpen = false
    private var isCancelled = false
    private var inbox: [URLSessionWebSocketTask.Message] = []
    private var failure: (any Error)?
    private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, any Error>?
    /// Sends made before the handshake finished, flushed in order once it has.
    private var pending: [(frame: [UInt8], completion: @Sendable ((any Error)?) -> Void)] = []
    private var closeCodeValue: URLSessionWebSocketTask.CloseCode = .invalid
    private var closeReasonValue: Data?

    /// Writes from any thread go out one whole frame at a time. The reader
    /// also holds it to close the descriptor, so a write never lands on a
    /// closed descriptor whose number was handed out again (an image fetch,
    /// mpv). Taken before `lock` when both are held.
    private let writeLock = NSLock()

    init(request: URLRequest, timeout: TimeInterval) {
        self.request = request
        self.timeout = timeout
    }

    var closeCode: URLSessionWebSocketTask.CloseCode { lock.withLock { closeCodeValue } }
    var closeReason: Data? { lock.withLock { closeReasonValue } }

    func resume() {
        let thread = Thread { [self] in run() }
        thread.name = "rave.net.websocket"
        thread.start()
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !inbox.isEmpty {
                let message = inbox.removeFirst()
                lock.unlock()
                continuation.resume(returning: message)
            } else if let failure {
                lock.unlock()
                continuation.resume(throwing: failure)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func send(_ text: String, completion: @escaping @Sendable ((any Error)?) -> Void) {
        let frame = RAVEWebSocketFrame.encode(opcode: .text, payload: Array(text.utf8))
        lock.lock()
        if let failure {
            lock.unlock()
            completion(failure)
        } else if !isOpen {
            pending.append((frame, completion))
            lock.unlock()
        } else {
            lock.unlock()
            completion(write(frame))
        }
    }

    /// Sends a close frame if the socket is up, then shuts it down, which
    /// also wakes the reader blocked in `recv`.
    func cancel(closeCode: URLSessionWebSocketTask.CloseCode) {
        lock.lock()
        guard !isCancelled else { lock.unlock(); return }
        isCancelled = true
        let wasOpen = isOpen
        lock.unlock()
        if wasOpen {
            var code = UInt16(clamping: closeCode.rawValue).bigEndian
            let payload = withUnsafeBytes(of: &code) { Array($0) }
            _ = write(RAVEWebSocketFrame.encode(opcode: .close, payload: payload))
        }
        // Under the lock: the reader closes the descriptor only while holding it.
        lock.withLock {
            if descriptor >= 0 { _ = shutdown(descriptor, Int32(SHUT_RDWR)) }
        }
        fail(URLError(.cancelled))
    }

    // MARK: - Reader thread

    private func run() {
        do {
            let descriptor = try connect()
            lock.lock()
            if isCancelled {
                lock.unlock()
                close(descriptor)
                return
            }
            self.descriptor = descriptor
            lock.unlock()
            var buffer = try handshake(descriptor)
            open()
            try readFrames(descriptor, buffer: &buffer)
        } catch {
            fail(error)
        }
        writeLock.lock()
        lock.lock()
        let descriptor = self.descriptor
        self.descriptor = -1
        lock.unlock()
        if descriptor >= 0 { close(descriptor) }
        writeLock.unlock()
    }

    /// Flushes the sends queued during the handshake. The write lock is held
    /// from before `isOpen` flips, so a send that sees it open queues behind
    /// the flush instead of overtaking it.
    private func open() {
        writeLock.lock()
        defer { writeLock.unlock() }
        lock.lock()
        isOpen = true
        let queued = pending
        pending = []
        lock.unlock()
        for (frame, completion) in queued {
            completion(writeHoldingLock(frame))
        }
    }

    private func connect() throws -> Int32 {
        guard let url = request.url, let host = url.host, !host.isEmpty else { throw URLError(.badURL) }
        let port = url.port ?? 80
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var results: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &results) == 0, let first = results else {
            throw URLError(.cannotFindHost)
        }
        defer { freeaddrinfo(results) }

        var lastError = URLError(.cannotConnectToHost)
        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let info = candidate {
            candidate = info.pointee.ai_next
            let descriptor = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard descriptor >= 0 else { continue }
            let flags = fcntl(descriptor, F_GETFL, 0)
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
            var result = posixConnect(descriptor, info.pointee.ai_addr, info.pointee.ai_addrlen)
            if result != 0 && errno == EINPROGRESS {
                var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                if poll(&poller, 1, Int32(timeout * 1000)) == 1 {
                    var error: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length)
                    result = error == 0 ? 0 : -1
                    if error != 0 { errno = error }
                } else {
                    lastError = URLError(.timedOut)
                    close(descriptor)
                    continue
                }
            }
            guard result == 0 else {
                close(descriptor)
                continue
            }
            _ = fcntl(descriptor, F_SETFL, flags)
            var on: Int32 = 1
            setsockopt(descriptor, Int32(IPPROTO_TCP), TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(descriptor, SOL_SOCKET, SO_KEEPALIVE, &on, socklen_t(MemoryLayout<Int32>.size))
            // A peer that stops reading can't block a send (and with it the
            // transport actor, and the reconnect that would recover) forever.
            var sendTimeout = timeval(tv_sec: .init(timeout), tv_usec: 0)
            setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
            #if canImport(Darwin)
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            #endif
            return descriptor
        }
        throw lastError
    }

    /// Sends the upgrade request and reads the response head. Returns any
    /// bytes that arrived after it (the start of the first frame).
    private func handshake(_ descriptor: Int32) throws -> [UInt8] {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { target += "?" + query }
        var hostHeader = components.host ?? ""
        if let port = components.port { hostHeader += ":\(port)" }
        var keyBytes = [UInt8](repeating: 0, count: 16)
        for index in keyBytes.indices { keyBytes[index] = UInt8.random(in: 0...255) }

        var head = "GET \(target) HTTP/1.1\r\n"
        head += "Host: \(hostHeader)\r\n"
        head += "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        head += "Sec-WebSocket-Key: \(Data(keyBytes).base64EncodedString())\r\n"
        head += "Sec-WebSocket-Version: 13\r\n"
        let reserved: Set<String> = ["host", "upgrade", "connection", "sec-websocket-key", "sec-websocket-version"]
        for (name, value) in request.allHTTPHeaderFields ?? [:] where !reserved.contains(name.lowercased()) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        if let error = write(Array(head.utf8)) { throw error }

        let deadline = Date().addingTimeInterval(timeout)
        var buffer: [UInt8] = []
        let terminator: [UInt8] = [13, 10, 13, 10]
        while true {
            if let end = buffer.firstRange(of: terminator) {
                let response = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let lines = response.split(separator: "\r\n")
                let status = lines.first?.split(separator: " ").dropFirst().first.flatMap { Int($0) }
                let upgraded = lines.dropFirst().contains {
                    $0.lowercased().hasPrefix("upgrade:") && $0.lowercased().contains("websocket")
                }
                guard status == 101, upgraded else { throw URLError(.badServerResponse) }
                return Array(buffer[end.upperBound...])
            }
            guard buffer.count < 16_384 else { throw URLError(.badServerResponse) }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw URLError(.timedOut) }
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, Int32(remaining * 1000)) == 1 else { throw URLError(.timedOut) }
            guard try read(descriptor, into: &buffer) else { throw URLError(.networkConnectionLost) }
        }
    }

    private func readFrames(_ descriptor: Int32, buffer: inout [UInt8]) throws {
        var message: (opcode: RAVEWebSocketFrame.Opcode, payload: [UInt8])?
        while true {
            while let frame = try RAVEWebSocketFrame.parse(buffer) {
                buffer.removeFirst(frame.length)
                switch frame.opcode {
                case .ping:
                    _ = write(RAVEWebSocketFrame.encode(opcode: .pong, payload: frame.payload))
                case .pong:
                    break
                case .close:
                    var code = URLSessionWebSocketTask.CloseCode.invalid
                    if frame.payload.count >= 2 {
                        code = URLSessionWebSocketTask.CloseCode(rawValue: Int(frame.payload[0]) << 8 | Int(frame.payload[1])) ?? .invalid
                    }
                    lock.withLock {
                        closeCodeValue = code
                        closeReasonValue = frame.payload.count > 2 ? Data(frame.payload[2...]) : nil
                    }
                    _ = write(RAVEWebSocketFrame.encode(opcode: .close, payload: Array(frame.payload.prefix(2))))
                    throw URLError(.networkConnectionLost)
                case .continuation:
                    guard message != nil else { throw URLError(.cannotParseResponse) }
                    message?.payload += frame.payload
                case .text, .binary:
                    message = (frame.opcode, frame.payload)
                }
                if frame.fin, let complete = message, frame.opcode == complete.opcode || frame.opcode == .continuation {
                    message = nil
                    deliver(complete.opcode == .text
                            ? .string(String(decoding: complete.payload, as: UTF8.self))
                            : .data(Data(complete.payload)))
                }
                if let partial = message, partial.payload.count > RAVEWebSocketFrame.maxPayload {
                    throw URLError(.dataLengthExceedsMaximum)
                }
            }
            guard try read(descriptor, into: &buffer) else { throw URLError(.networkConnectionLost) }
        }
    }

    /// Appends what `recv` returns; false at end of stream.
    private func read(_ descriptor: Int32, into buffer: inout [UInt8]) throws -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = recv(descriptor, &chunk, chunk.count, 0)
            if count > 0 {
                buffer += chunk[..<count]
                return true
            }
            if count == 0 { return false }
            if errno == EINTR { continue }
            throw lock.withLock { isCancelled } ? URLError(.cancelled) : URLError(.networkConnectionLost)
        }
    }

    private func write(_ bytes: [UInt8]) -> (any Error)? {
        writeLock.lock()
        defer { writeLock.unlock() }
        return writeHoldingLock(bytes)
    }

    /// The caller holds `writeLock`.
    private func writeHoldingLock(_ bytes: [UInt8]) -> (any Error)? {
        let descriptor = lock.withLock { self.descriptor }
        guard descriptor >= 0 else { return URLError(.networkConnectionLost) }
        var offset = 0
        while offset < bytes.count {
            #if canImport(Glibc)
            let flags = Int32(MSG_NOSIGNAL)
            #else
            let flags: Int32 = 0
            #endif
            let count = bytes.withUnsafeBytes { posixSend(descriptor, $0.baseAddress! + offset, bytes.count - offset, flags) }
            if count > 0 {
                offset += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                return URLError(.networkConnectionLost)
            }
        }
        return nil
    }

    private func deliver(_ message: URLSessionWebSocketTask.Message) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: message)
        } else {
            inbox.append(message)
            lock.unlock()
        }
    }

    /// The first failure wins; later ones (a cancel after a drop) are ignored.
    private func fail(_ error: any Error) {
        lock.lock()
        guard failure == nil else { lock.unlock(); return }
        failure = error
        let waiter = waiter
        self.waiter = nil
        let queued = pending
        pending = []
        lock.unlock()
        waiter?.resume(throwing: error)
        queued.forEach { $0.completion(error) }
    }
}

// The C calls, reachable past the methods of the same name.
private func posixConnect(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 {
    connect(descriptor, address, length)
}

private func posixSend(_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int, _ flags: Int32) -> Int {
    send(descriptor, bytes, count, flags)
}

/// WebSocket framing (RFC 6455 §5), client side: frames sent are masked,
/// frames received aren't.
enum RAVEWebSocketFrame {
    enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    struct Parsed: Equatable {
        let fin: Bool
        let opcode: Opcode
        let payload: [UInt8]
        /// Bytes the frame took in the buffer.
        let length: Int
    }

    /// Larger frames or messages are refused rather than buffered.
    static let maxPayload = 16 * 1024 * 1024

    static func encode(opcode: Opcode, payload: [UInt8], mask: [UInt8]? = nil) -> [UInt8] {
        let mask = mask ?? (0..<4).map { _ in UInt8.random(in: 0...255) }
        var frame: [UInt8] = [0x80 | opcode.rawValue]
        switch payload.count {
        case ..<126:
            frame.append(0x80 | UInt8(payload.count))
        case ..<65_536:
            frame.append(0x80 | 126)
            frame += [UInt8(payload.count >> 8 & 0xFF), UInt8(payload.count & 0xFF)]
        default:
            frame.append(0x80 | 127)
            frame += (0..<8).reversed().map { UInt8(UInt64(payload.count) >> (UInt64($0) * 8) & 0xFF) }
        }
        frame += mask
        frame += payload.enumerated().map { $0.element ^ mask[$0.offset & 3] }
        return frame
    }

    /// The first whole frame in `buffer`, or nil until enough bytes are in.
    static func parse(_ buffer: [UInt8]) throws -> Parsed? {
        guard buffer.count >= 2 else { return nil }
        guard let opcode = Opcode(rawValue: buffer[0] & 0x0F) else { throw URLError(.cannotParseResponse) }
        let fin = buffer[0] & 0x80 != 0
        let masked = buffer[1] & 0x80 != 0
        var length = Int(buffer[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = Int(buffer[2]) << 8 | Int(buffer[3])
            offset = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return nil }
            let value = buffer[2..<10].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            guard value <= UInt64(maxPayload) else { throw URLError(.dataLengthExceedsMaximum) }
            length = Int(value)
            offset = 10
        }
        guard length <= maxPayload else { throw URLError(.dataLengthExceedsMaximum) }
        var mask: [UInt8]?
        if masked {
            guard buffer.count >= offset + 4 else { return nil }
            mask = Array(buffer[offset..<offset + 4])
            offset += 4
        }
        guard buffer.count >= offset + length else { return nil }
        var payload = Array(buffer[offset..<offset + length])
        if let mask {
            for index in payload.indices { payload[index] ^= mask[index & 3] }
        }
        return Parsed(fin: fin, opcode: opcode, payload: payload, length: offset + length)
    }
}
