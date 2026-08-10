/*
 RAVE SDK — the in-app log viewer.

 Reading logs on the headset is the difference between diagnosing something and
 guessing at it, so this is deliberately a first-class screen rather than a
 debug afterthought: level and category filters, text search, auto-scroll, a
 clipboard export, and a count.

 The richest of the three apps' versions is the basis. It gets one thing none
 of them had: the pop-out button is driven by a closure rather than a hardcoded
 `openWindow(id: "console")`, because two of the five apps have no tab bar to
 embed it in and reach it as a window in the first place.
 */

#if canImport(SwiftUI)

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

public struct RAVEConsoleView: View {
    /// Where the entries come from. Defaults to the shared store.
    private let store: RAVELogStore
    /// Called by the pop-out button. Nil hides it — which is what a console
    /// that *is* the pop-out window wants.
    private let onPopOut: (() -> Void)?

    @State private var filter = RAVELogFilter()
    @State private var autoScroll = true

    public init(store: RAVELogStore = .shared, onPopOut: (() -> Void)? = nil) {
        self.store = store
        self.onPopOut = onPopOut
    }

    public var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            logList
        }
        // Registration, not `isPolling`, is what starts and stops the poll —
        // several consoles can be open at once and the last one out turns off
        // the light.
        .onAppear { store.addViewer() }
        .onDisappear { store.removeViewer() }
    }

    // MARK: Filter bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Level", selection: $filter.minimumLevel) {
                ForEach(RAVELogLevel.allCases) { level in
                    Text(level.label).tag(level)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)

            Picker("Category", selection: $filter.category) {
                Text("All Categories").tag(nil as String?)
                ForEach(store.categories, id: \.self) { category in
                    Text(category).tag(category as String?)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 220)

            TextField("Filter…", text: $filter.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)

            Spacer()

            Toggle(isOn: $autoScroll) {
                Image(systemName: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .help("Auto-scroll to newest")

            Button {
                copyToClipboard()
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .help("Copy filtered entries to clipboard")
            .disabled(entries.isEmpty)

            Text("\(entries.count)")
                .foregroundStyle(.secondary)
                .font(.caption.monospacedDigit())
                .frame(minWidth: 40, alignment: .trailing)

            Button(role: .destructive) {
                store.clear()
            } label: {
                Image(systemName: "trash")
            }
            .help("Clear log entries")

            if let onPopOut {
                Button(action: onPopOut) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Open in separate window")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: List

    private var entries: [RAVELogEntry] { store.filtered(filter) }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(entries) { entry in
                        RAVELogEntryRow(entry: entry).id(entry.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView {
                        Label("No log entries", systemImage: "text.alignleft")
                    } description: {
                        // The failure mode worth naming: the unified log drops
                        // `.debug` from the persistent store, so a call site
                        // that logs at `.debug` without promoting is invisible
                        // here no matter how the filter is set.
                        Text(store.isPolling
                             ? "Nothing matches the current filter yet."
                             : "Not polling — the console is not registered as a viewer.")
                    }
                }
            }
            .onChange(of: store.entries.count) { _, _ in
                guard autoScroll, let last = entries.last?.id else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
    }

    private func copyToClipboard() {
        let text = entries.exportText()
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

/// One row: time, severity initial, category chip, message.
struct RAVELogEntryRow: View {
    let entry: RAVELogEntry

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)

            Text(entry.level.label.prefix(1))
                .font(.system(.caption2, design: .monospaced))
                .fontWeight(.bold)
                .foregroundStyle(levelColor)
                .frame(width: 12)

            Text(entry.category)
                .font(.system(.caption2, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .frame(minWidth: 100, alignment: .leading)

            Text(entry.message)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(messageColor)
                .lineLimit(nil)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private var levelColor: Color {
        switch entry.level {
        case .error: .red
        case .warning: .orange
        case .notice: .blue
        case .info: .primary
        case .debug: .secondary
        }
    }

    private var messageColor: Color {
        switch entry.level {
        case .error: .red
        case .warning: .orange
        default: .primary
        }
    }
}

/// The console wrapped in a `NavigationStack` with a title — what a tab or a
/// standalone window wants, as opposed to embedding `RAVEConsoleView` bare.
public struct RAVEConsoleScreen: View {
    private let store: RAVELogStore
    private let onPopOut: (() -> Void)?

    public init(store: RAVELogStore = .shared, onPopOut: (() -> Void)? = nil) {
        self.store = store
        self.onPopOut = onPopOut
    }

    public var body: some View {
        NavigationStack {
            RAVEConsoleView(store: store, onPopOut: onPopOut)
                .navigationTitle("Console")
        }
    }
}

#endif
