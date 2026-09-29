/*
 RAVE SDK — the in-app log viewer's backend.

 Three apps grew this independently (Spatial Stash, Spatial Home, Longwave),
 each polling `OSLogStore`. That turned out to be the wrong source twice
 over: every `OSLogStore` read makes `logd` scan the whole system archive
 (~1.9 s flat; polling once a second slowed visionOS apps to a crawl), and the
 OS drops `.info` lines within minutes and never keeps `.debug`, so a console
 opened late showed almost nothing.

 The console now tails DebugTrace's `DebugLogBuffer`: the in-memory ring every
 `DebugLogger` writes to, with every level for the whole run. Reading it is a
 lock and a copy, so it is polled twice a second while a console is open.
 Lines the app doesn't log through `DebugLogger` (Apple frameworks, packages
 still on `os.Logger`) are not shown here; a debug trace carries them.

 **Polling is still reference-counted.** A console tab can sit visible in an
 ornament without anyone looking at it. Polling runs only while at least one
 viewer is registered, and this store's copy is released when the last one
 leaves. The shared buffer itself is untouched: traces read it too.

 **What the screen shows vs. what leaves the device.** Rows show a line as
 the device's own screen may (`revealedMessage`: private values in full in
 development mode, withheld in release). The copy button exports
 `exportMessage`: hidden values withheld and the redactor applied, because
 a clipboard ends up pasted into an LLM chat.
 */

import DebugTrace
import Foundation

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

    /// `DebugLogger.warning` is the error level underneath, as in os_log, so
    /// nothing arrives as `.warning`; it stays for callers that build entries
    /// themselves.
    public init(_ level: DebugLogLevel) {
        switch level {
        case .debug: self = .debug
        case .info: self = .info
        case .notice: self = .notice
        case .error, .fault: self = .error
        }
    }
}

/// One captured entry.
public struct RAVELogEntry: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let category: String
    public let level: RAVELogLevel
    /// For this device's own screen.
    public let message: String
    /// For anything that leaves the device: hidden values withheld and
    /// secrets redacted.
    public let exportMessage: String

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        category: String,
        level: RAVELogLevel,
        message: String,
        exportMessage: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.message = message
        self.exportMessage = exportMessage ?? message
    }

    init(record: DebugLogRecord, redactor: DebugRedactor) {
        self.init(timestamp: record.date, category: record.category, level: RAVELogLevel(record.level),
                  message: record.revealedMessage, exportMessage: redactor.redact(record.redactedMessage))
    }
}

/// Tails the app's `DebugLogBuffer` for the console.
@Observable
@MainActor
public final class RAVELogStore {

    /// The shared store, over the shared buffer every `DebugLogger` writes to.
    public static let shared = RAVELogStore()

    public private(set) var entries: [RAVELogEntry] = []

    /// Sorted, deduplicated category names seen so far. Maintained
    /// incrementally so the console's category picker doesn't rebuild a `Set`
    /// from `entries` on every render.
    public private(set) var categories: [String] = []
    public private(set) var isPolling = false

    public let buffer: DebugLogBuffer
    /// How many entries to show. Older ones are dropped from the view.
    public let maxEntries: Int
    public let pollInterval: Duration

    private var lastSequence = 0
    private var pollTask: Task<Void, Never>?
    private var categoriesSet: Set<String> = []
    private var viewerCount = 0

    public init(
        buffer: DebugLogBuffer = .shared,
        maxEntries: Int = 5_000,
        pollInterval: Duration = .milliseconds(500)
    ) {
        self.buffer = buffer
        self.maxEntries = maxEntries
        self.pollInterval = pollInterval
    }

    // MARK: Viewer registration

    /// Register an open console. Starts polling on the first one.
    public func addViewer() {
        viewerCount += 1
        guard viewerCount == 1 else { return }
        startPolling()
    }

    /// Unregister a console. Stops polling and releases this store's copy
    /// when the last one leaves — a tab that is merely *available* must not
    /// cost anything.
    public func removeViewer() {
        guard viewerCount > 0 else { return }
        viewerCount -= 1
        guard viewerCount == 0 else { return }
        stopPolling()
        entries.removeAll()
        categoriesSet.removeAll()
        categories.removeAll()
        lastSequence = 0
    }

    /// Hide everything captured so far. The shared buffer keeps it, so a
    /// trace taken afterwards still has the whole run.
    public func clear() {
        entries.removeAll()
        categoriesSet.removeAll()
        categories.removeAll()
        lastSequence = buffer.nextSequence - 1
    }

    // MARK: Polling

    private func startPolling() {
        guard !isPolling else { return }
        isPolling = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                pull()
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    private func stopPolling() {
        isPolling = false
        pollTask?.cancel()
        pollTask = nil
    }

    /// Takes what arrived since the last pull. Cheap enough for the main
    /// actor: a lock and a copy of the new records only.
    func pull() {
        let records = buffer.records(after: lastSequence)
        guard let last = records.last else { return }
        lastSequence = last.sequence
        let redactor = DebugTrace.configuration.redactor
        let fresh = records.map { RAVELogEntry(record: $0, redactor: redactor) }
        entries.append(contentsOf: fresh)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        var addedCategory = false
        for entry in fresh where categoriesSet.insert(entry.category).inserted {
            addedCategory = true
        }
        if addedCategory {
            categories = categoriesSet.sorted()
        }
    }

    // MARK: Filtering

    /// Entries matching a filter, in capture order.
    ///
    /// Pure over its inputs, so the filtering rule is testable without a live
    /// buffer — which is the part that was worth extracting, since all three
    /// apps had hand-written and slightly different versions of it.
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
    /// One line, the shape all three apps' clipboard export produced. Uses
    /// `exportMessage`: a clipboard leaves the device.
    func exportLine(formatter: DateFormatter) -> String {
        "\(formatter.string(from: timestamp)) [\(level.label)] \(category): \(exportMessage)"
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
