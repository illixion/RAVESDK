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
        #expect(RAVELogLevel(osLogLevel: .fault) == .error)
        #expect(RAVELogLevel(osLogLevel: .error) == .error)
        #expect(RAVELogLevel(osLogLevel: .debug) == .debug)
        #expect(RAVELogLevel(osLogLevel: .undefined) == .info)
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
        let store = RAVELogStore(subsystem: "pro.rave.tests.lifecycle")
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
        let store = RAVELogStore(subsystem: "pro.rave.tests.unbalanced")
        store.removeViewer()
        store.addViewer()
        #expect(store.isPolling)
        store.removeViewer()
        #expect(!store.isPolling)
    }

    @Test("The gap between reads stretches with what a read cost")
    func pollPacing() {
        // A read makes `logd` scan the whole archive (~1.9 s measured), so a
        // fixed one-second clock kept it busy nonstop. The gap is at least
        // `busyRatio` times the read, bounding the duty cycle.
        let minimum = Duration.seconds(2)
        #expect(RAVELogStore.nextPollDelay(afterFetchTaking: .milliseconds(50), minimum: minimum) == minimum)
        #expect(RAVELogStore.nextPollDelay(afterFetchTaking: .seconds(2), minimum: minimum)
                == .seconds(2 * RAVELogStore.busyRatio))
    }

    @Test("A refresh while not polling is harmless")
    func refreshWhileIdle() {
        let store = RAVELogStore(subsystem: "pro.rave.tests.refresh")
        store.refresh()
        #expect(!store.isPolling)
        #expect(!store.isFetching)
    }

    @Test("The nonisolated viewing flag drives the debug-level promotion")
    func debugPromotion() {
        // The unified log keeps .debug in a ring buffer only, so OSLogStore
        // never returns it — call sites must promote to .info while a console
        // is open or the console shows nothing at Debug.
        let store = RAVELogStore(subsystem: "pro.rave.tests.promotion")
        store.addViewer()
        #expect(RAVELogStore.isViewing)
        #expect(RAVELogStore.effectiveDebugLevel == .info)
        store.removeViewer()
        #expect(!RAVELogStore.isViewing)
        #expect(RAVELogStore.effectiveDebugLevel == .debug)
    }
}
