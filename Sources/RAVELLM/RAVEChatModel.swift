//
//  RAVEChatModel.swift
//  RAVELLM
//
//  A language model as the apps use one: a list of messages in, text out,
//  optionally constrained to a JSON schema and optionally streamed. Ollama on
//  the Mac is the implementation today (`RAVEOllama`); Private Cloud Compute
//  or the on-device model slot in behind the same protocol later, so what is
//  built on it (RAVEBrowser's page agent, Raven's assistant, the character's
//  brain) does not change with the backend.
//
//  Stateless: the conversation lives with the caller, and each request
//  carries all of it.
//

import Foundation

public struct RAVEChatMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant
    }

    public var role: Role
    public var content: String
    /// JPEG or PNG bytes, for models that take images.
    public var images: [Data]

    public init(_ role: Role, _ content: String, images: [Data] = []) {
        self.role = role
        self.content = content
        self.images = images
    }

    public static func system(_ content: String) -> Self { Self(.system, content) }
    public static func user(_ content: String, images: [Data] = []) -> Self { Self(.user, content, images: images) }
    public static func assistant(_ content: String) -> Self { Self(.assistant, content) }
}

public struct RAVEChatRequest: Sendable {
    public var messages: [RAVEChatMessage]
    /// A JSON schema the reply must match, as JSON bytes. A dictionary is
    /// not Sendable, so the schema travels encoded.
    public var schema: Data?
    public var temperature: Double?
    /// Tokens of context the model is given. Leave it the same across a
    /// session's requests: Ollama reloads the model when it changes.
    public var contextLength: Int?

    public init(messages: [RAVEChatMessage], schema: Data? = nil, temperature: Double? = nil,
                contextLength: Int? = nil) {
        self.messages = messages
        self.schema = schema
        self.temperature = temperature
        self.contextLength = contextLength
    }

    /// With the schema given as a JSON-shaped dictionary.
    public init(messages: [RAVEChatMessage], schemaObject: [String: Any], temperature: Double? = nil,
                contextLength: Int? = nil) {
        self.init(messages: messages, schema: try? JSONSerialization.data(withJSONObject: schemaObject),
                  temperature: temperature, contextLength: contextLength)
    }
}

public protocol RAVEChatModel: Sendable {
    /// Which model this is, for logs and settings: "gemma3:12b".
    var name: String { get }
    /// Whether `RAVEChatMessage.images` reach the model.
    func acceptsImages() async throws -> Bool
    func reply(to request: RAVEChatRequest) async throws -> String
    /// The reply as it is written, a piece at a time.
    func stream(_ request: RAVEChatRequest) -> AsyncThrowingStream<String, Error>
}

public extension RAVEChatModel {
    func acceptsImages() async throws -> Bool { false }

    /// A model that can't stream gives its whole reply as one piece.
    func stream(_ request: RAVEChatRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(try await reply(to: request))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
