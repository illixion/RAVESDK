/*
 RAVENet - the socket under the transport

 `URLSessionWebSocketTask` on Apple platforms and for `wss://`; on Linux a
 `ws://` endpoint gets `RAVEPOSIXWebSocket` instead, because
 FoundationNetworking's task keeps a core busy while its socket is open
 (see that file). The transport sees one shape either way.
 */

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class RAVEWebSocketConnection: @unchecked Sendable {
    private enum Backend {
        case task(URLSessionWebSocketTask)
        case posix(RAVEPOSIXWebSocket)
    }

    private let backend: Backend

    init(session: URLSession, url: URL, timeout: TimeInterval) {
        #if canImport(Darwin)
        backend = .task(session.webSocketTask(with: url))
        #else
        // FoundationNetworking's handshake sends `Connection: keep-alive`, not
        // `Upgrade`, and a server that checks for the upgrade token (Node's
        // http module does) answers it as a plain GET: a 404.
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Upgrade", forHTTPHeaderField: "Connection")
        if url.scheme?.lowercased() == "ws" {
            backend = .posix(RAVEPOSIXWebSocket(request: request, timeout: timeout))
        } else {
            backend = .task(session.webSocketTask(with: request))
        }
        #endif
    }

    func resume() {
        switch backend {
        case .task(let task): task.resume()
        case .posix(let socket): socket.resume()
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        switch backend {
        case .task(let task): try await task.receive()
        case .posix(let socket): try await socket.receive()
        }
    }

    func send(_ text: String, completion: @escaping @Sendable ((any Error)?) -> Void) {
        switch backend {
        case .task(let task): task.send(.string(text)) { completion($0) }
        case .posix(let socket): socket.send(text, completion: completion)
        }
    }

    func cancel() {
        switch backend {
        case .task(let task): task.cancel(with: .goingAway, reason: nil)
        case .posix(let socket): socket.cancel(closeCode: .goingAway)
        }
    }

    var closeCode: URLSessionWebSocketTask.CloseCode {
        switch backend {
        case .task(let task): task.closeCode
        case .posix(let socket): socket.closeCode
        }
    }

    var closeReason: Data? {
        switch backend {
        case .task(let task): task.closeReason
        case .posix(let socket): socket.closeReason
        }
    }
}
