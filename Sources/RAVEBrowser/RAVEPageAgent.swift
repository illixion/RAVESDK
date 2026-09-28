//
//  RAVEPageAgent.swift
//  RAVEBrowser
//
//  A model reaching a goal on a page, one action at a time, through
//  RAVEPageDriver. The loop and its contract (instructions, the JSON a step
//  must be, what each turn shows) live here so every consumer — the
//  character's reader, Raven's assistant, RAVEBrowserLab's bench — runs and
//  measures the same thing. The model is the consumer's: Ollama, the on-device
//  model, anything that can answer a `RAVEPageAgentTurn` with a step.
//
//  Each turn is self-contained and bounded: the current page only (title,
//  URL, the element outline and optionally a marked snapshot), one line per
//  earlier step, and the previous action's result. Page text from `read`
//  lasts exactly one turn. An earlier version sent the whole conversation
//  back every turn — every page's outline and every read — and a 12B model's
//  time per step grew from 6 s to 50 s within one task.
//

#if canImport(WebKit)
import Foundation

/// One action, as a model writes it: a flat JSON object, which is what small
/// models produce reliably under a schema.
public struct RAVEPageAgentStep: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable, CaseIterable {
        case click, type, scroll, find, read, back, navigate, done
    }

    public var why: String?
    public var action: Action
    public var ref: Int?
    public var text: String?
    public var submit: Bool?
    public var direction: String?
    public var url: String?
    public var answer: String?

    public init(why: String? = nil, action: Action, ref: Int? = nil, text: String? = nil, submit: Bool? = nil,
                direction: String? = nil, url: String? = nil, answer: String? = nil) {
        self.why = why
        self.action = action
        self.ref = ref
        self.text = text
        self.submit = submit
        self.direction = direction
        self.url = url
        self.answer = answer
    }

    /// `click 12`, `type 3 "arctic fox"`, … for the history lines.
    public var brief: String {
        switch action {
        case .click: "click \(ref ?? 0)"
        case .type: "type \(ref ?? 0) \"\(text ?? "")\"" + (submit == false ? "" : " and submit")
        case .scroll: "scroll \(direction ?? "down")"
        case .find: "find \"\(text ?? "")\""
        case .read: "read"
        case .back: "back"
        case .navigate: "go to \(url ?? "")"
        case .done: "done"
        }
    }
}

/// What the model sees on one turn.
public struct RAVEPageAgentTurn: Sendable {
    public var goal: String
    public var step: Int
    public var maxSteps: Int
    public var title: String
    public var url: String
    public var outline: String
    /// A JPEG with each element's number drawn on, when snapshots are on.
    public var snapshot: Data?
    /// One line per earlier step, oldest first.
    public var history: [String]
    /// The previous action's full result, page text included.
    public var previous: String

    /// The turn as one user message.
    public var prompt: String {
        var lines = ["Goal: \(goal)", "", "Step \(step) of \(maxSteps).",
                     "Page: \(title)", "URL: \(url)"]
        if !history.isEmpty { lines += ["", "Steps so far:"] + history }
        lines += ["", "Result of the last step: \(previous)", "", "Elements:", outline, "",
                  "If the goal is already reached, answer with done now."]
        return lines.joined(separator: "\n")
    }
}

/// Whatever answers a turn with a step.
public protocol RAVEPageAgentModel: Sendable {
    func step(for turn: RAVEPageAgentTurn) async throws -> RAVEPageAgentStep
}

public struct RAVEPageAgentRecord: Sendable {
    public var step: RAVEPageAgentStep?
    /// What the action did, or why the model's answer was unusable.
    public var outcome: String
    /// How long the model took.
    public var modelSeconds: Double
}

public struct RAVEPageAgentResult: Sendable {
    public var answer: String?
    public var finished: Bool
    public var records: [RAVEPageAgentRecord]
    public var url: String
    public var seconds: Double
}

@MainActor
public final class RAVEPageAgent {
    public let driver: RAVEPageDriver
    public var maxSteps = 10
    /// Send a marked snapshot each turn; off means the outline alone, for
    /// text-only models.
    public var usesSnapshots = true
    public var snapshotWidth = 1024
    public var elementLimit = 80
    public var readCharacters = 3000
    /// The same step with the same result this many times in a row ends the
    /// run: a model that loops will not stop looping by itself.
    public var repeatLimit = 3
    /// Called after every step, for live logging.
    public var onStep: ((Int, RAVEPageAgentRecord) -> Void)?

    /// Where the next `read` continues, per page.
    private var readPosition: (url: String, offset: Int) = ("", 0)

    public init(driver: RAVEPageDriver) {
        self.driver = driver
    }

    /// The contract a model follows: pass as its system prompt.
    public nonisolated static let instructions = """
        You operate a web browser for a user, one action at a time, to reach a goal.

        Each turn you get the page's title and URL, the steps taken so far, the result of \
        the last one, and the elements you can use as a list like `[12] link "Title" → url`. \
        You may also get a screenshot in which every element has a box with its number. \
        Refer to elements only by those numbers.

        Answer with one action as JSON:
        {"action": "click", "ref": N}
        {"action": "type", "ref": N, "text": "...", "submit": true}   (a search box: submit)
        {"action": "scroll", "direction": "down"}   (or "up": to see more of the page)
        {"action": "find", "text": "..."}   (jump to text on the page and get the lines around it)
        {"action": "read"}   (the page's article text, a part at a time: read again for the next part)
        {"action": "back"}
        {"action": "navigate", "url": "https://..."}
        {"action": "done", "answer": "..."}   (the goal is reached; the answer is what you tell the user)

        Add "why" in a few words. When the last result already holds what the goal asks for, \
        answer with done at once. Never repeat a step that changed nothing: try something else.
        """

    /// The JSON schema a step must match, for models that constrain decoding.
    /// Built on each read, so a non-Sendable dictionary never crosses actors.
    public nonisolated static var stepSchema: [String: Any] { [
        "type": "object",
        "properties": [
            "why": ["type": "string"],
            "action": ["type": "string", "enum": RAVEPageAgentStep.Action.allCases.map(\.rawValue)],
            "ref": ["type": "integer"],
            "text": ["type": "string"],
            "submit": ["type": "boolean"],
            "direction": ["type": "string", "enum": ["down", "up"]],
            "url": ["type": "string"],
            "answer": ["type": "string"],
        ],
        "required": ["why", "action"],
    ] }

    public func run(goal: String, model: some RAVEPageAgentModel) async -> RAVEPageAgentResult {
        let started = Date()
        readPosition = ("", 0)
        var records: [RAVEPageAgentRecord] = []
        var history: [String] = []
        var previous = "none yet"
        var lastBrief = "", lastOutcome = "", repeats = 0
        for index in 1...maxSteps {
            let before = try? await driver.info()
            let elements = try? await driver.elements(limit: elementLimit)
            var snapshot: Data?
            if usesSnapshots, let elements {
                snapshot = try? await driver.snapshot(width: snapshotWidth, marks: elements)
            }
            let turn = RAVEPageAgentTurn(
                goal: goal, step: index, maxSteps: maxSteps,
                title: before?.title ?? "", url: before?.url ?? "",
                outline: elements?.outline() ?? "(the page's elements could not be listed)",
                snapshot: snapshot, history: Array(history.suffix(12)), previous: previous)

            let asked = Date()
            let step: RAVEPageAgentStep
            do {
                step = try await model.step(for: turn)
            } catch {
                let record = RAVEPageAgentRecord(step: nil, outcome: "unusable answer: \(error.localizedDescription)",
                                                 modelSeconds: Date().timeIntervalSince(asked))
                records.append(record)
                onStep?(index, record)
                history.append("\(index). (an unusable answer)")
                previous = "your last answer was not a valid action"
                continue
            }
            let modelSeconds = Date().timeIntervalSince(asked)

            if step.action == .done {
                let record = RAVEPageAgentRecord(step: step, outcome: "done", modelSeconds: modelSeconds)
                records.append(record)
                onStep?(index, record)
                return RAVEPageAgentResult(answer: step.answer ?? "", finished: true, records: records,
                                           url: before?.url ?? "", seconds: Date().timeIntervalSince(started))
            }

            var outcome = await perform(step)
            if step.brief == lastBrief, outcome == lastOutcome {
                repeats += 1
            } else {
                repeats = 1
                lastBrief = step.brief
                lastOutcome = outcome
            }
            if step.action != .read, step.action != .find, let before, let after = try? await driver.info(),
               after.url == before.url, after.title == before.title,
               abs(after.viewport.scrollY - before.viewport.scrollY) < 1, !outcome.hasPrefix("error") {
                outcome += " (nothing on the page changed)"
            }
            if repeats >= 2 {
                outcome += "\nThat was the same step with the same result as before. If the goal is reached, "
                    + "answer with done; otherwise do something different."
            }
            let record = RAVEPageAgentRecord(step: step, outcome: outcome, modelSeconds: modelSeconds)
            records.append(record)
            onStep?(index, record)
            if repeats >= repeatLimit { break }
            let firstLine = outcome.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? outcome
            history.append("\(index). \(step.brief) → \(firstLine.prefix(120))")
            previous = outcome
        }
        let url = (try? await driver.info())?.url ?? ""
        return RAVEPageAgentResult(answer: nil, finished: false, records: records, url: url,
                                   seconds: Date().timeIntervalSince(started))
    }

    /// Runs a step and says what happened, in words for the next turn.
    private func perform(_ step: RAVEPageAgentStep) async -> String {
        do {
            switch step.action {
            case .click:
                guard let ref = step.ref, ref > 0 else { return "error: click needs the number of an element in the list" }
                let action = try await driver.click(ref: ref)
                return "clicked \(action.target)" + (action.info.map { ", now on \"\($0.title)\"" } ?? "")
            case .type:
                guard let ref = step.ref, ref > 0, let text = step.text else {
                    return "error: type needs the number of a text field in the list, and text"
                }
                let action = try await driver.type(ref: ref, text: text, submit: step.submit ?? true)
                return "typed into \(action.target)" + (action.info.map { ", now on \"\($0.title)\"" } ?? "")
            case .scroll:
                let scroll = try await driver.scroll(by: step.direction == "up" ? -0.8 : 0.8)
                if !scroll.moved { return "the page did not move: already at the \(scroll.atTop ? "top" : "bottom")" }
                return scroll.atBottom ? "scrolled; this is the bottom of the page" : "scrolled"
            case .find:
                guard let text = step.text, !text.isEmpty else { return "error: find needs text" }
                let found = try await driver.find(text)
                guard found.count > 0 else { return "no \"\(text)\" on this page" }
                return "\(found.count) match(es) for \"\(text)\", the first scrolled into view:\n"
                    + found.snippets.prefix(5).map { "- \($0)" }.joined(separator: "\n")
            case .read:
                // A page in parts: re-reading from the top can never reach
                // what is further down, and a small model will keep trying.
                let reading = try await driver.read(maxCharacters: 400_000)
                let text = reading.text
                let offset = readPosition.url == reading.url ? readPosition.offset : 0
                guard offset < text.count else {
                    readPosition = (reading.url, 0)
                    return "that was the end of the page's text; reading again starts from the top"
                }
                let start = text.index(text.startIndex, offsetBy: offset)
                var end = text.index(start, offsetBy: readCharacters, limitedBy: text.endIndex) ?? text.endIndex
                // End on a paragraph break when one is near, not mid-sentence.
                if end < text.endIndex, let br = text[start..<end].range(of: "\n\n", options: .backwards),
                   text.distance(from: start, to: br.lowerBound) > readCharacters / 2 {
                    end = br.upperBound
                }
                readPosition = (reading.url, text.distance(from: text.startIndex, to: end))
                let parts = max(1, Int((Double(text.count) / Double(readCharacters)).rounded(.up)))
                let part = min(parts, offset / readCharacters + 1)
                let more = end < text.endIndex ? "; read again for the next part" : "; the end"
                return "page text, part \(part) of about \(parts)\(more):\n" + text[start..<end]
            case .back:
                let info = try await driver.goBack()
                return "went back to \"\(info.title)\""
            case .navigate:
                guard let string = step.url, let url = URL(string: string), url.scheme?.hasPrefix("http") == true else {
                    return "error: navigate needs an http(s) url"
                }
                let info = try await driver.navigate(to: url)
                return "opened \"\(info.title)\""
            case .done:
                return "done"
            }
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }
}
#endif
