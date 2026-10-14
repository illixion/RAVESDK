//
//  RAVEChatPageModel.swift
//  RAVEBrowser
//
//  Any RAVELLM chat model as a page agent's model: one request per turn,
//  with the agent's instructions as the system prompt, the turn as the user
//  message (plus its marked snapshot), and decoding held to the step schema.
//  Every consumer of `RAVEPageAgent` uses this, so the agent is measured on
//  the Mac (RAVEBrowserLab) exactly as the apps run it.
//

#if canImport(WebKit)
import Foundation
import RAVELLM

public struct RAVEChatPageModel: RAVEPageAgentModel {
    public let model: any RAVEChatModel
    public var contextLength: Int?

    public init(model: any RAVEChatModel, contextLength: Int? = nil) {
        self.model = model
        self.contextLength = contextLength
    }

    public struct Unusable: LocalizedError {
        public let errorDescription: String?
    }

    public func step(for turn: RAVEPageAgentTurn) async throws -> RAVEPageAgentStep {
        let request = RAVEChatRequest(
            messages: [.system(RAVEPageAgent.instructions),
                       .user(turn.prompt, images: turn.snapshot.map { [$0] } ?? [])],
            schemaObject: RAVEPageAgent.stepSchema, temperature: 0, contextLength: contextLength)
        let content = try await model.reply(to: request)
        do {
            return try JSONDecoder().decode(RAVEPageAgentStep.self, from: Data(content.utf8))
        } catch {
            throw Unusable(errorDescription: "not a step: \(content.prefix(200))")
        }
    }
}
#endif
