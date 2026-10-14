import Foundation
import Testing
@testable import RAVELLM

/// Answers every request to the stub host from `StubOllama.handler`, and
/// records what was asked.
final class StubOllama: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [(URLRequest, [String: Any])] = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "ollama.stub" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        Self.requests.append((request, (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]))
        let (status, data) = Self.handler?(request, body) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct RAVEOllamaTests {
    let ollama = RAVEOllama(baseURL: URL(string: "https://ollama.stub:11434")!, model: "gemma3:12b")

    init() {
        URLProtocol.registerClass(StubOllama.self)
        StubOllama.requests = []
    }

    @Test func sendsTheRequestOllamaExpects() async throws {
        StubOllama.handler = { _, _ in (200, Data(#"{"message":{"role":"assistant","content":"{\"a\":1}"},"done":true}"#.utf8)) }
        let request = RAVEChatRequest(
            messages: [.system("be brief"), .user("look", images: [Data([1, 2, 3])])],
            schemaObject: ["type": "object"], temperature: 0, contextLength: 16384)
        let reply = try await ollama.reply(to: request)
        #expect(reply == #"{"a":1}"#)

        let (sent, body) = try #require(StubOllama.requests.last)
        #expect(sent.url?.path == "/api/chat")
        // Ollama behind `tailscale serve` only answers to localhost.
        #expect(sent.value(forHTTPHeaderField: "Host") == "localhost")
        #expect(body["model"] as? String == "gemma3:12b")
        #expect(body["stream"] as? Bool == false)
        #expect(body["think"] as? Bool == false)
        #expect((body["format"] as? [String: Any])?["type"] as? String == "object")
        let options = try #require(body["options"] as? [String: Any])
        #expect(options["temperature"] as? Double == 0)
        #expect(options["num_ctx"] as? Int == 16384)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        #expect(messages[1]["images"] as? [String] == [Data([1, 2, 3]).base64EncodedString()])
        #expect(messages[0]["images"] == nil)
    }

    @Test func streamsPiecesUntilDone() async throws {
        let lines = [
            #"{"message":{"role":"assistant","content":"Hel"},"done":false}"#,
            #"{"message":{"role":"assistant","content":"lo"},"done":false}"#,
            #"{"message":{"role":"assistant","content":""},"done":true}"#,
        ]
        StubOllama.handler = { _, _ in (200, Data(lines.joined(separator: "\n").utf8)) }
        var pieces: [String] = []
        for try await piece in ollama.stream(RAVEChatRequest(messages: [.user("hi")])) { pieces.append(piece) }
        #expect(pieces == ["Hel", "lo"])
        #expect(StubOllama.requests.last?.1["stream"] as? Bool == true)
        #expect(StubOllama.requests.last?.1["options"] == nil)
    }

    @Test func aStreamedErrorThrows() async throws {
        StubOllama.handler = { _, _ in (200, Data(#"{"error":"model not found"}"#.utf8)) }
        await #expect(throws: RAVEOllama.ClientError.self) {
            for try await _ in ollama.stream(RAVEChatRequest(messages: [.user("hi")])) {}
        }
    }

    @Test func badStatusCarriesTheBody() async throws {
        StubOllama.handler = { _, _ in (404, Data(#"{"error":"model 'x' not found"}"#.utf8)) }
        do {
            _ = try await ollama.reply(to: RAVEChatRequest(messages: [.user("hi")]))
            Issue.record("expected an error")
        } catch let error as RAVEOllama.ClientError {
            #expect(error.localizedDescription.contains("404"))
            #expect(error.localizedDescription.contains("not found"))
        }
    }

    @Test func listsModelsAndVision() async throws {
        StubOllama.handler = { request, _ in
            if request.url?.path == "/api/tags" {
                return (200, Data(#"{"models":[{"name":"qwen3.5:9b","details":{"parameter_size":"9.7B"}},{"name":"gemma3:12b","details":{}}]}"#.utf8))
            }
            return (200, Data(#"{"capabilities":["completion","vision"]}"#.utf8))
        }
        let models = try await RAVEOllama.models(at: ollama.baseURL)
        #expect(models.map(\.name) == ["gemma3:12b", "qwen3.5:9b"])
        #expect(models.last?.parameterSize == "9.7B")
        #expect(try await ollama.acceptsImages())
    }
}

@Suite struct RAVEChatModelDefaultsTests {
    struct Echo: RAVEChatModel {
        var name: String { "echo" }
        func reply(to request: RAVEChatRequest) async throws -> String { request.messages.last?.content ?? "" }
    }

    @Test func aModelThatCannotStreamGivesOnePiece() async throws {
        var pieces: [String] = []
        for try await piece in Echo().stream(RAVEChatRequest(messages: [.user("whole")])) { pieces.append(piece) }
        #expect(pieces == ["whole"])
        #expect(try await Echo().acceptsImages() == false)
    }
}
