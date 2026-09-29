import DebugTrace
import Foundation
import Testing
@testable import RAVEConsole

private func entry(
    _ message: String,
    level: RAVELogLevel = .info,
    category: String = "App",
    at seconds: TimeInterval = 0
) -> RAVELogEntry {
    RAVELogEntry(
        timestamp: Date(timeIntervalSince1970: seconds),
        category: category,
        level: level,
        message: message
    )
}

private let sample: [RAVELogEntry] = [
    entry("connecting", level: .debug, category: "Net", at: 1),
    entry("connected", level: .info, category: "Net", at: 2),
    entry("slow response", level: .warning, category: "Net", at: 3),
    entry("cache miss", level: .debug, category: "Cache", at: 4),
    entry("write failed", level: .error, category: "Cache", at: 5),
]

@Suite("Log levels")
struct RAVELogLevelTests {

    @Test("Levels order by severity so a minimum-level filter is a comparison")
    func ordering() {
        #expect(RAVELogLevel.debug < .info)
        #expect(RAVELogLevel.info < .notice)
        #expect(RAVELogLevel.notice < .warning)
        #expect(RAVELogLevel.warning < .error)
    }

    @Test("A fault is surfaced as an error, not swallowed")
    func faultMapsToError() {
        // Nothing in the console UI distinguishes them, and a fault silently
        // becoming "info" would be the worst possible rounding.
        #expect(RAVELogLevel(DebugLogLevel.fault) == .error)
        #expect(RAVELogLevel(DebugLogLevel.error) == .error)
        #expect(RAVELogLevel(DebugLogLevel.debug) == .debug)
        #expect(RAVELogLevel(DebugLogLevel.notice) == .notice)
    }
}

@Suite("Log filtering")
struct RAVELogFilterTests {

    @Test("The default filter shows everything")
    func defaultShowsAll() {
        #expect(RAVELogStore.filter(sample, with: RAVELogFilter()).count == 5)
    }

    @Test("Minimum level is inclusive of itself")
    func minimumLevelIsInclusive() {
        let warnings = RAVELogStore.filter(sample, with: .init(minimumLevel: .warning))
        #expect(warnings.map(\.message) == ["slow response", "write failed"])
    }

    @Test("Category narrows to one source")
    func categoryFilter() {
        let net = RAVELogStore.filter(sample, with: .init(category: "Net"))
        #expect(net.count == 3)
        #expect(net.allSatisfy { $0.category == "Net" })
    }

    @Test("Search matches the message or the category, case-insensitively")
    func searchMatchesBothFields() {
        #expect(RAVELogStore.filter(sample, with: .init(searchText: "FAIL")).count == 1)
        // "cache" appears as a category on two entries and in no message.
        #expect(RAVELogStore.filter(sample, with: .init(searchText: "cache")).count == 2)
    }

    @Test("Filters compose rather than override each other")
    func filtersCompose() {
        let filter = RAVELogFilter(minimumLevel: .warning, category: "Cache", searchText: "write")
        let result = RAVELogStore.filter(sample, with: filter)
        #expect(result.map(\.message) == ["write failed"])
    }

    @Test("A filter that matches nothing returns nothing rather than everything")
    func emptyResult() {
        #expect(RAVELogStore.filter(sample, with: .init(searchText: "zzz")).isEmpty)
    }

    @Test("Capture order is preserved — a log read out of order is unreadable")
    func orderPreserved() {
        let result = RAVELogStore.filter(sample, with: RAVELogFilter())
        #expect(result.map(\.timestamp) == result.map(\.timestamp).sorted())
    }
}

@Suite("Log export")
struct RAVELogExportTests {

    @Test("An exported line carries time, level, category and message")
    func exportLine() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let line = entry("hello", level: .warning, category: "Net", at: 0)
            .exportLine(formatter: formatter)
        #expect(line == "00:00:00.000 [Warning] Net: hello")
    }

    @Test("Exporting the whole view is one line per entry")
    func exportText() {
        let text = sample.exportText()
        #expect(text.split(separator: "\n").count == sample.count)
        #expect(text.contains("write failed"))
    }

    @Test("An empty selection exports an empty string, not a stray newline")
    func exportEmpty() {
        #expect([RAVELogEntry]().exportText().isEmpty)
    }
}

@MainActor
@Suite("Store lifecycle")
struct RAVELogStoreLifecycleTests {

    @Test("Polling is reference-counted so an unopened console costs nothing")
    func viewerCounting() {
        let store = RAVELogStore(buffer: DebugLogBuffer(mode: .development))
        #expect(!store.isPolling)

        store.addViewer()
        #expect(store.isPolling)

        // A second console must not stop the first one's feed when it closes.
        store.addViewer()
        store.removeViewer()
        #expect(store.isPolling)

        store.removeViewer()
        #expect(!store.isPolling)
    }

    @Test("Unbalanced removal does not drive the count negative")
    func removalIsSafe() {
        let store = RAVELogStore(buffer: DebugLogBuffer(mode: .development))
        store.removeViewer()
        store.addViewer()
        #expect(store.isPolling)
        store.removeViewer()
        #expect(!store.isPolling)
    }
}

@MainActor
@Suite("Tailing the log buffer")
struct RAVELogStoreBufferTests {

    @Test("A console opened late still shows the whole run, debug lines included")
    func lateOpenSeesHistory() {
        let buffer = DebugLogBuffer(mode: .development)
        let log = DebugLogger(subsystem: "pro.rave.tests.console", category: "Net", buffer: buffer)
        log.debug("probe \(1)")
        log.info("connected")
        let store = RAVELogStore(buffer: buffer)
        store.pull()
        #expect(store.entries.map(\.message) == ["probe 1", "connected"])
        #expect(store.entries.map(\.level) == [.debug, .info])
        #expect(store.categories == ["Net"])

        log.error("dropped")
        store.pull()
        #expect(store.entries.map(\.message) == ["probe 1", "connected", "dropped"])
    }

    @Test("The screen may show a private value; the clipboard never does")
    func exportWithholdsPrivateValues() {
        let buffer = DebugLogBuffer(mode: .development)
        let log = DebugLogger(subsystem: "pro.rave.tests.console", category: "Auth", buffer: buffer)
        log.info("signed in as \("ixion@example.com")")
        let store = RAVELogStore(buffer: buffer)
        store.pull()
        let entry = try! #require(store.entries.first)
        #expect(entry.message == "signed in as ixion@example.com")
        #expect(entry.exportMessage == "signed in as <private>")
        #expect(!store.entries.exportText().contains("ixion@"))
    }

    @Test("Clearing hides lines from the view but leaves the buffer for traces")
    func clearKeepsBuffer() {
        let buffer = DebugLogBuffer(mode: .development)
        let log = DebugLogger(subsystem: "pro.rave.tests.console", category: "C", buffer: buffer)
        log.info("before")
        let store = RAVELogStore(buffer: buffer)
        store.pull()
        store.clear()
        #expect(store.entries.isEmpty)
        log.info("after")
        store.pull()
        #expect(store.entries.map(\.message) == ["after"])
        #expect(buffer.records().count == 2)
    }
}
