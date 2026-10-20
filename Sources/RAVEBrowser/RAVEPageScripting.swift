//
//  RAVEPageScripting.swift
//  RAVEBrowser
//
//  Whether a driver may run JavaScript its caller wrote
//  (`RAVEPageDriver.evaluate`). The app that makes the driver decides, once,
//  when it makes it; nothing a caller passes later can raise it.
//
//  Why it is tiered rather than simply on or off: page text reaches the
//  model, and a model that can be talked into running a script can do
//  anything the page can (read its cookies' effects, post as the user,
//  exfiltrate what the page shows). How much that matters depends on who is
//  watching, so each consumer states it:
//
//  - **never**: spatial-ai-character's ambient browsing. A small model reads
//    pages on its own with nobody watching each step; no script, ever.
//  - **ask**: Raven's assistant. The person is in the chat and decides, the
//    first time a script is wanted in a chat session.
//  - **always**: Raven for Mac's agent harness (its MCP server). The person
//    set up the agent, runs it, and turned the harness on; the tool exists
//    for that agent, the way Chrome MCP's `javascript_tool` does.
//
//  The check is in the driver, the one place every adapter goes through, so
//  no tool layer can forget it.
//

#if canImport(WebKit)
import Foundation
import JavaScriptCore

/// What `RAVEPageDriver.evaluate` does. Fixed when the driver is made.
@MainActor
public enum RAVEScriptPolicy {
    /// Refused: `evaluate` throws `scriptingNotAllowed`, and an agent is not
    /// offered the action at all.
    case never
    /// Each script is put to `consent` first, which may wait for a person.
    case ask(any RAVEScriptConsent)
    /// Allowed without asking.
    case always

    /// Whether a script could run at all: false only for `never`. An agent
    /// offers the action, and a tool catalog lists the tool, on this.
    public var permitsScripts: Bool {
        if case .never = self { return false }
        return true
    }
}

/// One script a caller wants run, as consent sees it.
public struct RAVEScriptRequest: Sendable, Equatable {
    /// The page's origin (`https://example.com`): who the script would run as.
    public var origin: String
    public var url: String
    public var source: String

    public init(origin: String, url: String, source: String) {
        self.origin = origin
        self.url = url
        self.source = source
    }
}

/// Decides whether a script may run.
@MainActor
public protocol RAVEScriptConsent: AnyObject {
    func allows(_ request: RAVEScriptRequest) async -> Bool
}

/// Asks the first time, and after a yes for the session stops asking until
/// `reset()`: Raven's rule is one question per chat. Two scripts wanted at
/// once share one question rather than stacking two.
@MainActor
public final class RAVEScriptSessionConsent: RAVEScriptConsent {
    public enum Answer: Sendable, Equatable {
        /// Allow this one and every later one, until `reset()`.
        case allowForSession
        case allowOnce
        case deny
    }

    public private(set) var isGranted = false
    private let ask: @MainActor (RAVEScriptRequest) async -> Answer
    private var pending: Task<Answer, Never>?

    /// - Parameter ask: puts the request to the person and returns their
    ///   answer. A cancelled ask should return `.deny`.
    public init(ask: @escaping @MainActor (RAVEScriptRequest) async -> Answer) {
        self.ask = ask
    }

    public func allows(_ request: RAVEScriptRequest) async -> Bool {
        if isGranted { return true }
        let task = pending ?? Task { await ask(request) }
        pending = task
        let answer = await task.value
        if pending == task { pending = nil }
        switch answer {
        case .allowForSession:
            isGranted = true
            return true
        case .allowOnce:
            return true
        case .deny:
            return false
        }
    }

    /// A new session: the next script asks again.
    public func reset() {
        isGranted = false
        pending?.cancel()
        pending = nil
    }
}

/// Parses JavaScript without running it, with the engine WebKit itself uses,
/// so `evaluate` knows whether it was handed an expression or statements
/// before the page sees either.
enum RAVEScriptSyntax {
    /// Nil when `body` compiles as an async function's body; otherwise the
    /// parser's message (`SyntaxError: Unexpected token ')'`).
    static func error(compiling body: String) -> String? {
        guard let context = JSContext() else { return nil }
        context.setObject(body, forKeyedSubscript: "__body" as NSString)
        let result = context.evaluateScript("""
            (() => {
                try { new (Object.getPrototypeOf(async function () {}).constructor)(__body); return null; }
                catch (e) { return String(e); }
            })()
            """)
        guard let result, !result.isNull, !result.isUndefined else { return nil }
        return result.toString()
    }
}
#endif
