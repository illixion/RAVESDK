/*
 RAVEBrowserLab - RAVEPageAgent on the Mac, against a model on Ollama.

   swift run RAVEBrowserLab --model gemma3:12b
   swift run RAVEBrowserLab --model qwen3.5:9b --task wiki-fact --verbose
   swift run RAVEBrowserLab --list

 Measures the agent loop the apps ship, without a headset: the page runs in a
 1280×800 window here (watch it browse), the model on the Mac's Ollama picks
 each step, and success is judged from the page a task ends on, not from what
 the model says. Prints one JSON line per task and a summary line.

 Options:
   --model NAME      an Ollama model (required unless --list)
   --task ID         run one task (repeatable); default all
   --steps N         step budget per task (default 10)
   --text-only       no snapshots: the element outline alone
   --ollama URL      default http://127.0.0.1:11434
   --verbose         print every step to stderr
 */

import AppKit
import Foundation
import RAVEBrowser
import RAVELLM
import WebKit

struct LabTask {
    let id: String
    let start: String
    let goal: String
    /// Judged from the URL the task ends on and the model's answer.
    let passes: (String, String) -> Bool
}

let tasks: [LabTask] = [
    LabTask(id: "wiki-search", start: "https://en.wikipedia.org/wiki/Red_fox",
            goal: "Search Wikipedia for \"arctic fox\" and open its article.",
            passes: { url, _ in url.contains("/wiki/Arctic_fox") }),
    LabTask(id: "wiki-genus", start: "https://en.wikipedia.org/wiki/Red_fox",
            goal: "Open the Wikipedia article about the genus the red fox belongs to.",
            passes: { url, _ in url.hasSuffix("/wiki/Vulpes") }),
    LabTask(id: "wiki-fact", start: "https://en.wikipedia.org/wiki/Red_fox",
            goal: "Find out how much an adult red fox typically weighs, and answer with the numbers.",
            passes: { _, answer in answer.lowercased().contains("kg") && answer.contains(where: \.isNumber) }),
    LabTask(id: "reddit-top-post", start: "https://www.reddit.com/r/visionosdev/",
            goal: "Open the first post in this subreddit's feed.",
            passes: { url, _ in url.contains("/comments/") }),
    LabTask(id: "reddit-read", start: "https://www.reddit.com/r/visionosdev/",
            goal: "Open the first post in the feed and tell me in one sentence what it is about.",
            passes: { url, answer in url.contains("/comments/") && answer.count > 20 }),
    LabTask(id: "reddit-other-sub", start: "https://www.reddit.com/r/visionosdev/",
            goal: "Go to the r/VisionPro subreddit and open its first post.",
            passes: { url, _ in url.lowercased().contains("/r/visionpro/comments/") }),
    // Client-rendered sites: a click rewrites the page instead of loading
    // one, so these lean on the driver waiting for the page to go quiet.
    LabTask(id: "github-issues", start: "https://github.com/ollama/ollama",
            goal: "Open this repository's list of open issues.",
            passes: { url, _ in url.contains("/ollama/ollama/issues") }),
    LabTask(id: "mdn-search", start: "https://developer.mozilla.org/en-US/",
            goal: "Use the site's search to find the page about JavaScript's Array.prototype.flat() method, and open it.",
            passes: { url, _ in url.contains("/Array/flat") }),
    LabTask(id: "npm-search", start: "https://www.npmjs.com/",
            goal: "Search for the package \"left-pad\" and open its package page.",
            passes: { url, _ in url.hasSuffix("/package/left-pad") }),
]

struct Options {
    var model = ""
    var tasks: [String] = []
    var steps = 10
    var textOnly = false
    var ollama = URL(string: "http://127.0.0.1:11434")!
    var verbose = false
    var list = false

    init(_ arguments: [String]) {
        var it = arguments.dropFirst().makeIterator()
        while let argument = it.next() {
            switch argument {
            case "--model": model = it.next() ?? ""
            case "--task": if let id = it.next() { tasks.append(id) }
            case "--steps": steps = Int(it.next() ?? "") ?? steps
            case "--text-only": textOnly = true
            case "--ollama": ollama = URL(string: it.next() ?? "") ?? ollama
            case "--verbose", "-v": verbose = true
            case "--list": list = true
            default: FileHandle.standardError.write(Data("unknown option \(argument)\n".utf8)); exit(2)
            }
        }
    }
}

func stderr(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }
/// Unbuffered, so a redirected run shows each task as it finishes.
func emit(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }

func json(_ object: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

@MainActor
func runLab(_ options: Options) async -> Int32 {
    if options.list {
        for task in tasks { emit("\(task.id)\t\(task.goal)") }
        return 0
    }
    guard !options.model.isEmpty else { stderr("--model is required"); return 2 }

    // A real, visible window: WebKit treats a page in no window, or an
    // unshown one, as hidden and stops rendering it — the same thing the
    // headset's pause relies on — and a hidden page cannot be snapshotted.
    let frame = NSRect(x: 80, y: 80, width: 1280, height: 800)
    let window = NSWindow(contentRect: frame, styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
    window.title = "RAVEBrowserLab — \(options.model)"
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: configuration)
    window.contentView = view
    window.orderFrontRegardless()

    let driver = RAVEPageDriver(webView: view)
    let agent = RAVEPageAgent(driver: driver)
    agent.maxSteps = options.steps
    agent.usesSnapshots = !options.textOnly
    if options.verbose {
        agent.onStep = { index, record in
            let step = record.step.map { $0.brief + ($0.why.map { " (\($0))" } ?? "") } ?? "-"
            let outcome = record.outcome.split(separator: "\n").first.map(String.init) ?? ""
            stderr(String(format: "    %2d  %5.1f s  %@  →  %@", index, record.modelSeconds, step, String(outcome.prefix(100))))
        }
    }
    // The adapter the apps use, so the bench measures what ships. Each turn
    // is one self-contained request carrying its own bounded history.
    let model = RAVEChatPageModel(model: RAVEOllama(baseURL: options.ollama, model: options.model))

    let chosen = tasks.filter { options.tasks.isEmpty || options.tasks.contains($0.id) }
    var passed = 0, totalSeconds = 0.0, totalSteps = 0
    for task in chosen {
        if options.verbose { stderr("\(task.id): \(task.goal)") }
        do {
            try await driver.navigate(to: URL(string: task.start)!)
            try await Task.sleep(for: .seconds(1))
            _ = try await driver.dismissOverlays()
        } catch {
            emit(json(["task": task.id, "ok": false, "error": "could not open \(task.start): \(error.localizedDescription)"]))
            continue
        }
        let result = await agent.run(goal: task.goal, model: model)
        let ok = task.passes(result.url, result.answer ?? "")
        passed += ok ? 1 : 0
        totalSeconds += result.seconds
        totalSteps += result.records.count
        let modelSeconds = result.records.reduce(0) { $0 + $1.modelSeconds }
        emit(json(["task": task.id, "ok": ok, "finished": result.finished, "steps": result.records.count,
                    "seconds": (result.seconds * 10).rounded() / 10,
                    "modelSeconds": (modelSeconds * 10).rounded() / 10,
                    "url": result.url, "answer": result.answer ?? ""]))
    }
    emit("\(options.model)\(options.textOnly ? " (text only)" : ""): \(passed)/\(chosen.count) tasks, "
          + "\(totalSteps) steps, \(Int(totalSeconds)) s")
    return passed == chosen.count ? 0 : 1
}

let options = Options(CommandLine.arguments)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    let code = await runLab(options)
    exit(code)
}
app.run()
