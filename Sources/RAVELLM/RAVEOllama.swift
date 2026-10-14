//
//  RAVEOllama.swift
//  RAVELLM
//
//  The slice of Ollama's HTTP API the apps need: list a server's models, ask
//  what one can do, and run a chat turn, whole or streamed, optionally
//  constrained to a JSON schema.
//
//  Every request says `Host: localhost`. Ollama bound to loopback refuses any
//  other host name with a 403 (its DNS-rebinding guard, with no setting to
//  widen it), and the intended route from a headset is `tailscale serve` in
//  front of that loopback listener, which forwards the tailnet name. Tailscale
//  routes by port, so the rewrite costs nothing there, and it lets Ollama stay
//  off the LAN.
//
//  Thinking is turned off: every caller wants the answer, and a reasoning
//  trace only adds seconds before it.
//

import Foundation

public struct RAVEOllama: RAVEChatModel {
    public var baseURL: URL
    public var model: String
    public var name: String { model }

    /// The Mac's Ollama behind `tailscale serve --https=11434`.
    public static let defaultURL = URL(string: "https://pegasus.akita-city.ts.net:11434")!

    public init(baseURL: URL = Self.defaultURL, model: String) {
        self.baseURL = baseURL
        self.model = model
    }

    public struct Model: Identifiable, Hashable, Sendable {
        public let name: String
        public let parameterSize: String?
        public var id: String { name }
    }

    public enum ClientError: LocalizedError {
        case badStatus(Int, String)
        case badResponse

        public var errorDescription: String? {
            switch self {
            case .badStatus(let code, let body): "Ollama returned HTTP \(code): \(body)"
            case .badResponse: "Ollama sent a response that could not be read."
            }
        }
    }

    /// The models the server at `baseURL` has, by name.
    public static func models(at baseURL: URL) async throws -> [Model] {
        let object = try await request(baseURL, "api/tags", body: nil, timeout: 5)
        guard let models = object["models"] as? [[String: Any]] else { throw ClientError.badResponse }
        return models.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let details = entry["details"] as? [String: Any]
            return Model(name: name, parameterSize: details?["parameter_size"] as? String)
        }
        .sorted { $0.name < $1.name }
    }

    /// What the model reports it can do: "completion", "vision", "tools",
    /// "thinking", ...
    public func capabilities() async throws -> [String] {
        let object = try await Self.request(baseURL, "api/show", body: ["model": model], timeout: 10)
        return object["capabilities"] as? [String] ?? []
    }

    public func acceptsImages() async throws -> Bool {
        try await capabilities().contains("vision")
    }

    public func reply(to request: RAVEChatRequest) async throws -> String {
        // A cold 27B model takes a while to load before its first token.
        let object = try await Self.request(baseURL, "api/chat", body: try body(request, stream: false), timeout: 300)
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? String else { throw ClientError.badResponse }
        return content
    }

    /// Ollama streams one JSON object per line, each carrying the next piece
    /// of the message, until one says `done`.
    public func stream(_ request: RAVEChatRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = Self.urlRequest(baseURL, "api/chat", timeout: 300)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: try body(request, stream: true))
                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 300 { break } }
                        throw ClientError.badStatus(http.statusCode, String(body.prefix(300)))
                    }
                    for try await line in bytes.lines {
                        guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                            throw ClientError.badResponse
                        }
                        if let error = object["error"] as? String { throw ClientError.badStatus(200, error) }
                        if let message = object["message"] as? [String: Any],
                           let piece = message["content"] as? String, !piece.isEmpty {
                            continuation.yield(piece)
                        }
                        if object["done"] as? Bool == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Plumbing

    private func body(_ request: RAVEChatRequest, stream: Bool) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "stream": stream,
            "think": false,
            "messages": request.messages.map { message -> [String: Any] in
                var entry: [String: Any] = ["role": message.role.rawValue, "content": message.content]
                if !message.images.isEmpty { entry["images"] = message.images.map { $0.base64EncodedString() } }
                return entry
            },
        ]
        if let schema = request.schema { body["format"] = try JSONSerialization.jsonObject(with: schema) }
        var options: [String: Any] = [:]
        if let temperature = request.temperature { options["temperature"] = temperature }
        if let contextLength = request.contextLength { options["num_ctx"] = contextLength }
        if !options.isEmpty { body["options"] = options }
        return body
    }

    private static func urlRequest(_ baseURL: URL, _ path: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: timeout)
        request.setValue("localhost", forHTTPHeaderField: "Host")
        return request
    }

    private static func request(_ baseURL: URL, _ path: String, body: [String: Any]?,
                                timeout: TimeInterval) async throws -> [String: Any] {
        var request = urlRequest(baseURL, path, timeout: timeout)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.badStatus(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.badResponse
        }
        return object
    }
}
