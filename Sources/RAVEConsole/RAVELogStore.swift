/*
 RAVE SDK — the in-app log viewer's backend.

 Three apps grew this independently (Spatial Stash, Spatial Home, Longwave) and
 all three do the same thing: poll `OSLogStore` for this process's entries in
 this app's subsystem, keep a capped in-memory buffer, and filter it by level,
 category and text. They differ only in incidental typing — one kept
 `OSLogEntryLog.Level` raw, one mapped it to its own enum, one put the filter
 state in the store and one in the view.

 Two details are load-bearing and easy to lose in a rewrite:

 **Polling is reference-counted.** A console tab can sit visible in an ornament
 without anyone looking at it, and `OSLogStore.getEntries` is not free. Polling
 runs only while at least one viewer is registered, and the buffer is released
 when the last one leaves.

 **Polling is paced by what a read costs, not a fixed clock.** A read is not
 incremental: `position(date:)` is ignored, and `getEntries` makes `logd` scan
 the whole system log archive whatever the predicate says. Measured on macOS
 27, that is ~1.9 s per read, flat, with no CPU charged to this process — the
 work happens in `logd`, outside the app's own priority. Reading once a second
 kept `logd` scanning nonstop, which is what slowed visionOS apps to a crawl
 while the console was open. So each read runs at background QoS (XPC carries
 it to `logd`), and the gap before the next one is at least `busyRatio` times
 as long as the read took, which bounds `logd`'s duty cycle at ~20%.
 `refresh()` reads immediately for a viewer who doesn't want to wait.

 **`.debug` entries are not in the store.** The unified log keeps `.debug` in a
 memory ring buffer only — `OSLogStore` never returns them, so a console set to
 "Debug" would silently show nothing. The workaround is to *promote* debug calls
 to `.info` while a viewer is open, which is what `isViewing` exists for. It is
 read from any thread, so call sites can consult it cheaply.
 */

import Foundation
import OSLog
import os

/// Log severity, ordered so a minimum-level filter is a comparison.
public enum RAVELogLevel: Int, CaseIterable, Identifiable, Sendable, Comparable {
    case debug = 0
    case info = 1
    case notice = 2
    case warning = 3
    case error = 4

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .debug: "Debug"
        case .info: "Info"
        case .notice: "Notice"
        case .warning: "Warning"
        case .error: "Error"
        }
    }

    public static func < (lhs: RAVELogLevel, rhs: RAVELogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(osLogLevel: OSLogEntryLog.Level) {
        switch osLogLevel {
        case .debug: self = .debug
        case .info: self = .info
        case .notice: self = .notice
        case .error: self = .error
        case .fault: self = .error
        default: self = .info
        }
    }
}

/// One captured entry.
public struct RAVELogEntry: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let category: String
    public let level: RAVELogLevel
    public let message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        category: String,
        level: RAVELogLevel,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.message = message
    }
}

/// Reads this process's log entries out of the unified logging system.
@Observable
@MainActor
public final class RAVELogStore {

    /// The shared store, reading the main bundle's identifier as its subsystem.
    /// An app that logs under a different subsystem should make its own.
    public static let shared = RAVELogStore()

    public private(set) var entries: [RAVELogEntry] = []

    /// Sorted, deduplicated category names seen so far. Maintained
    /// incrementally so the console's category picker doesn't rebuild a `Set`
    /// from `entries` on every render.
    public private(set) var categories: [String] = []
    public private(set) var isPolling = false
    /// True while a read is in flight, for a refresh spinner.
    public private(set) var isFetching = false

    public let subsystem: String
    /// How many entries to retain. Older ones are dropped.
    public let maxEntries: Int
    /// How far back the first poll reaches.
    public let initialHistory: TimeInterval
    /// The shortest gap between reads. The actual gap stretches with what the
    /// last read cost — see `nextPollDelay(afterFetchTaking:minimum:)`.
    public let minimumPollInterval: Duration

    /// How many times longer than a read the idle gap after it must be.
    public nonisolated static let busyRatio = 4

    private var lastPollDate: Date?
    private var pollTask: Task<Void, Never>?
    /// The sleep between reads, held so `refresh()` can cut it short.
    private var waitTask: Task<Void, Error>?
    /// Bumped on every start, so a read that outlives the viewers who asked
    /// for it — and a restart after them — is discarded instead of applied.
    private var generation = 0
    private var categoriesSet: Set<String> = []
    private var viewerCount = 0

    public init(
        subsystem: String = Bundle.main.bundleIdentifier ?? "pro.rave.app",
        maxEntries: Int = 2000,
        initialHistory: TimeInterval = 60,
        minimumPollInterval: Duration = .seconds(2)
    ) {
        self.subsystem = subsystem
        self.maxEntries = maxEntries
        self.initialHistory = initialHistory
        self.minimumPollInterval = minimumPollInterval
    }

    // MARK: Viewer registration

    /// True while at least one console is open, readable from any thread.
    ///
    /// Call sites pass `RAVELogStore.effectiveDebugLevel` to
    /// `Logger.log(level:_:)` so their debug lines are promoted to `.info` and
    /// become visible here, and stay `.debug` — and free — otherwise.
    public nonisolated static var isViewing: Bool {
        viewingFlag.withLock { $0 }
    }

    /// `.info` while a console is open, `.debug` otherwise.
    public nonisolated static var effectiveDebugLevel: OSLogType {
        isViewing ? .info : .debug
    }

    private nonisolated static let viewingFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Register an open console. Starts polling on the first one.
    public func addViewer() {
        viewerCount += 1
        guard viewerCount == 1 else { return }
        Self.viewingFlag.withLock { $0 = true }
        startPolling()
    }

    /// Unregister a console. Stops polling and releases the buffer when the
    /// last one leaves — a tab that is merely *available* must not cost
    /// anything.
    public func removeViewer() {
        guard viewerCount > 0 else { return }
        viewerCount -= 1
        guard viewerCount == 0 else { return }
        Self.viewingFlag.withLock { $0 = false }
        stopPolling()
        entries.removeAll()
        categoriesSet.removeAll()
        categories.removeAll()
        lastPollDate = nil
    }

    /// Drop everything captured so far without disturbing polling.
    public func clear() {
        entries.removeAll()
        categoriesSet.removeAll()
        categories.removeAll()
        lastPollDate = Date()
    }

    // MARK: Polling

    /// Read now instead of waiting out the current gap. Does nothing while
    /// not polling, and never starts a second read alongside one in flight.
    public func refresh() {
        waitTask?.cancel()
    }

    /// The gap before the next read: at least `minimum`, and at least
    /// `busyRatio` times what the last read took.
    public nonisolated static func nextPollDelay(
        afterFetchTaking elapsed: Duration,
        minimum: Duration
    ) -> Duration {
        max(minimum, elapsed * busyRatio)
    }

    private func startPolling() {
        guard !isPolling else { return }
        isPolling = true
        generation += 1
        pollTask = Task { [weak self] in
            // The first read produces the initial history. Running it through
            // the same detached path keeps the main thread free during the
            // cold open.
            while !Task.isCancelled {
                guard let elapsed = await self?.performFetch() else { return }
                guard !Task.isCancelled, let self else { return }
                let delay = Self.nextPollDelay(afterFetchTaking: elapsed, minimum: minimumPollInterval)
                let wait = Task { try await Task.sleep(for: delay) }
                waitTask = wait
                // Cancelled either by `refresh()`, which reads again at once,
                // or by `stopPolling()`, which the loop condition catches.
                _ = try? await wait.value
            }
        }
    }

    private func stopPolling() {
        isPolling = false
        isFetching = false
        pollTask?.cancel()
        pollTask = nil
        waitTask?.cancel()
        waitTask = nil
    }

    /// One fetch cycle, returning how long the read took. The `OSLogStore`
    /// read runs on a detached background task: the main actor stays free,
    /// and the low QoS follows the request into `logd`, which does the work.
    private func performFetch() async -> Duration {
        let generation = self.generation
        let since = lastPollDate
        let subsystem = self.subsystem
        let history = initialHistory
        isFetching = true
        let clock = ContinuousClock()
        let start = clock.now
        let result = await Task.detached(priority: .background) {
            Self.readEntries(since: since, subsystem: subsystem, initialHistory: history)
        }.value
        let elapsed = clock.now - start
        guard generation == self.generation else { return elapsed }
        isFetching = false
        apply(result)
        return elapsed
    }

    nonisolated private static func readEntries(
        since date: Date?,
        subsystem: String,
        initialHistory: TimeInterval
    ) -> (newEntries: [RAVELogEntry], latestDate: Date?) {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            // Ignored in practice — every read returns the whole process
            // history — but passed anyway in case an OS release honours it.
            // The `<= date` check below is what actually skips old entries.
            let position = store.position(date: date ?? Date().addingTimeInterval(-initialHistory))
            let predicate = NSPredicate(format: "subsystem == %@", subsystem)
            let logEntries = try store.getEntries(at: position, matching: predicate)

            var newEntries: [RAVELogEntry] = []
            var latestDate = date

            for entry in logEntries {
                guard let logEntry = entry as? OSLogEntryLog else { continue }
                // `position(date:)` is inclusive, so without this the boundary
                // entry is captured again on every poll.
                if let date, logEntry.date <= date { continue }

                newEntries.append(RAVELogEntry(
                    timestamp: logEntry.date,
                    category: logEntry.category,
                    level: RAVELogLevel(osLogLevel: logEntry.level),
                    message: logEntry.composedMessage
                ))

                if latestDate == nil || logEntry.date > latestDate! {
                    latestDate = logEntry.date
                }
            }
            return (newEntries, latestDate)
        } catch {
            return ([], date)
        }
    }

    private func apply(_ result: (newEntries: [RAVELogEntry], latestDate: Date?)) {
        if !result.newEntries.isEmpty {
            entries.append(contentsOf: result.newEntries)
            if entries.count > maxEntries {
                entries.removeFirst(entries.count - maxEntries)
            }
            var addedCategory = false
            for entry in result.newEntries where categoriesSet.insert(entry.category).inserted {
                addedCategory = true
            }
            if addedCategory {
                categories = categoriesSet.sorted()
            }
        }
        if let latestDate = result.latestDate {
            lastPollDate = latestDate
        }
    }

    // MARK: Filtering

    /// Entries matching a filter, in capture order.
    ///
    /// Pure over its inputs, so the filtering rule is testable without a live
    /// `OSLogStore` — which is the part that was worth extracting, since all
    /// three apps had hand-written and slightly different versions of it.
    public func filtered(_ filter: RAVELogFilter) -> [RAVELogEntry] {
        RAVELogStore.filter(entries, with: filter)
    }

    public nonisolated static func filter(
        _ entries: [RAVELogEntry],
        with filter: RAVELogFilter
    ) -> [RAVELogEntry] {
        entries.filter { entry in
            guard entry.level >= filter.minimumLevel else { return false }
            if let category = filter.category, entry.category != category { return false }
            guard !filter.searchText.isEmpty else { return true }
            return entry.message.localizedCaseInsensitiveContains(filter.searchText)
                || entry.category.localizedCaseInsensitiveContains(filter.searchText)
        }
    }
}

/// What the console is currently showing.
public struct RAVELogFilter: Sendable, Equatable {
    public var minimumLevel: RAVELogLevel
    /// Nil means every category.
    public var category: String?
    public var searchText: String

    public init(
        minimumLevel: RAVELogLevel = .debug,
        category: String? = nil,
        searchText: String = ""
    ) {
        self.minimumLevel = minimumLevel
        self.category = category
        self.searchText = searchText
    }
}

public extension RAVELogEntry {
    /// One line, the shape all three apps' clipboard export produced.
    func exportLine(formatter: DateFormatter) -> String {
        "\(formatter.string(from: timestamp)) [\(level.label)] \(category): \(message)"
    }
}

public extension Array where Element == RAVELogEntry {
    /// The whole filtered view as text, for the clipboard.
    func exportText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return map { $0.exportLine(formatter: formatter) }.joined(separator: "\n")
    }
}
