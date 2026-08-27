/*
 RAVE SDK — RAVEUI tests.

 These are *unit* tests despite the name colliding with XCUITest's conventions:
 SwiftPM has no UI-testing product type, and XCUITest needs a host app to
 attach to, so a package cannot carry one. Driving the shared views through a
 real window happens in a host app's UI test target instead — Spatial Stash's
 `SpatialStashUITests` links RAVEUI and matches on `RAVEA11y` identifiers, which
 is what makes these two halves fit together.

 What is testable here is the arithmetic and the bookkeeping: column sizing,
 the archive shape window sizes are persisted in, the identifier vocabulary the
 UI tests match on, and the main-window count. The views themselves are
 visionOS-only and `swift test` runs on macOS, so anything touching them would
 have to be `#if os(visionOS)`-guarded and would not run here at all.
 */

import Foundation
import Testing
@testable import RAVEUI

#if canImport(SwiftUI)

// MARK: - Grid columns

@Suite("Grid column layout")
struct RAVEGridColumnLayoutTests {

    /// The whole reason this isn't `.adaptive`: a narrow window must shrink the
    /// cells rather than drop a column.
    @Test("The minimum column count holds when the width can't fit it at the preferred size")
    func minimumCountHolds() {
        let resolution = RAVEGridColumnLayout.resolve(
            width: 300, preferredCellSize: 200, minColumns: 3, spacing: 20, contentInset: 24
        )
        #expect(resolution.columnCount == 3)
        #expect(resolution.columnWidth < 200)
    }

    @Test("A wide window gets the count adaptive sizing would have picked")
    func naturalCountAtWidth() {
        // 1200 - 48 inset = 1152 available; (1152 + 20) / (200 + 20) = 5.32 → 5.
        let resolution = RAVEGridColumnLayout.resolve(
            width: 1200, preferredCellSize: 200, minColumns: 3, spacing: 20, contentInset: 24
        )
        #expect(resolution.columnCount == 5)
    }

    /// Columns are `.flexible()` precisely so the grid hugs the window edges —
    /// leftover width there is what makes resize grabbers float.
    @Test("Columns plus spacing exactly fill the available width", arguments: [320.0, 700.0, 1200.0, 2400.0])
    func columnsFillAvailableWidth(width: Double) {
        let spacing: CGFloat = 20
        let inset: CGFloat = 24
        let resolution = RAVEGridColumnLayout.resolve(
            width: width, preferredCellSize: 200, minColumns: 3, spacing: spacing, contentInset: inset
        )
        let available = max(200, width - inset * 2)
        let used = resolution.columnWidth * CGFloat(resolution.columnCount)
            + spacing * CGFloat(resolution.columnCount - 1)
        #expect(abs(used - available) < 0.001)
    }

    /// A `GeometryReader` reports 0 for one frame before layout settles, and a
    /// negative width is reachable when the caller subtracts its own padding.
    @Test("A non-positive width falls back instead of producing nonsense", arguments: [0.0, -48.0])
    func nonPositiveWidthFallsBack(width: Double) {
        let resolution = RAVEGridColumnLayout.resolve(
            width: width, preferredCellSize: 200, minColumns: 3
        )
        #expect(resolution.columnCount == 3)
        #expect(resolution.columnWidth == 200)
    }

    @Test("The GridItem array matches the resolved count")
    func columnsMatchResolution() {
        let (columns, columnWidth) = RAVEGridColumnLayout.columns(
            width: 1200, preferredCellSize: 200, minColumns: 3, spacing: 20, contentInset: 24
        )
        let resolution = RAVEGridColumnLayout.resolve(
            width: 1200, preferredCellSize: 200, minColumns: 3, spacing: 20, contentInset: 24
        )
        #expect(columns.count == resolution.columnCount)
        #expect(columnWidth == resolution.columnWidth)
    }
}

// MARK: - Persisted window size

@Suite("Codable size")
struct RAVECodableSizeTests {

    @Test("Round-trips through JSON")
    func roundTrip() throws {
        let original = RAVECodableSize(CGSize(width: 1234.5, height: 678.25))
        let decoded = try JSONDecoder().decode(
            RAVECodableSize.self, from: JSONEncoder().encode(original)
        )
        #expect(decoded == original)
        #expect(decoded.cgSize == original.cgSize)
    }

    /// The archive is written by visionOS scene restoration, and the keys are
    /// therefore load-bearing: renaming one silently drops every window size
    /// persisted by a previous build. Spatial Stash's existing archives were
    /// written when this type still lived in the app as `CodableSize`, which is
    /// why the property names had to be kept identical.
    @Test("Encodes as flat width/height keys")
    func encodedShape() throws {
        let data = try JSONEncoder().encode(RAVECodableSize(width: 100, height: 200))
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(json.keys.sorted() == ["height", "width"])
    }
}

// MARK: - Identifiers

@Suite("Accessibility identifiers")
struct RAVEA11yTests {

    @Test("Slugs collapse punctuation and trim the ends")
    func slugging() {
        #expect(RAVEA11y.slug("Pictures") == "pictures")
        #expect(RAVEA11y.slug("play.fill") == "play-fill")
        #expect(RAVEA11y.slug("  Spatial   Stash  ") == "spatial-stash")
        #expect(RAVEA11y.slug("photo.stack.fill") == "photo-stack-fill")
    }

    /// A UI test in another repository computes these strings without linking
    /// the app, so the exact spelling is the contract.
    @Test("Identifiers compose predictably")
    func composition() {
        #expect(RAVEA11y.tab("pictures") == "rave.tab.pictures")
        #expect(RAVEA11y.tabAction("play.fill") == "rave.tabAction.play-fill")
        #expect(RAVEA11y.windowRow("Gallery") == "rave.window.gallery")
        #expect(RAVEA11y.windowSummon("Gallery") == "rave.window.gallery.summon")
        #expect(RAVEA11y.windowClose("Gallery") == "rave.window.gallery.close")
    }

    @Test("Slugging is total — no input produces a crash or a nil")
    func sluggingIsTotal() {
        #expect(RAVEA11y.slug("") == "")
        #expect(RAVEA11y.slug("...") == "")
        #expect(RAVEA11y.slug("日本語") == "日本語")
    }
}

// MARK: - Main-window bookkeeping

/// Serialized: the registry is a singleton, so parallel tests would see each
/// other's counts.
@Suite("Window session registry", .serialized)
@MainActor
struct RAVEWindowSessionRegistryTests {

    /// Restores the count so a failure in one test doesn't cascade.
    private func withBalancedCount(_ body: (RAVEWindowSessionRegistry) -> Void) {
        let registry = RAVEWindowSessionRegistry.shared
        let before = registry.mainWindowCount
        body(registry)
        while registry.mainWindowCount > before { registry.unregisterMainWindow() }
    }

    @Test("Registering and unregistering balances out")
    func balances() {
        withBalancedCount { registry in
            let before = registry.mainWindowCount
            registry.registerMainWindow()
            registry.registerMainWindow()
            #expect(registry.mainWindowCount == before + 2)
            registry.unregisterMainWindow()
            #expect(registry.mainWindowCount == before + 1)
        }
    }

    /// `onDisappear` is not guaranteed to be balanced against `onAppear` across
    /// a scene teardown, and a negative count would make `ensureMainWindowVisible`
    /// think a window exists when none does.
    @Test("The count never goes negative")
    func neverNegative() {
        let registry = RAVEWindowSessionRegistry.shared
        while registry.mainWindowCount > 0 { registry.unregisterMainWindow() }
        registry.unregisterMainWindow()
        registry.unregisterMainWindow()
        #expect(registry.mainWindowCount == 0)
    }

    @Test("Registering stamps the time, which is how the intent tells a fresh window from a parked one")
    func stampsRegistrationTime() {
        withBalancedCount { registry in
            let before = Date()
            registry.registerMainWindow()
            let stamp = registry.lastMainWindowRegistration
            #expect(stamp != nil)
            #expect((stamp ?? .distantPast) >= before)
        }
    }

    /// With no `openWindow` captured there is nothing to call, and silently
    /// doing nothing is the failure that leaves an app with no window at all.
    @Test("A missing openWindow action is reported, not swallowed")
    func missingActionIsLogged() {
        let registry = RAVEWindowSessionRegistry.shared
        while registry.mainWindowCount > 0 { registry.unregisterMainWindow() }
        let previousLog = registry.log
        defer { registry.log = previousLog }

        var messages: [String] = []
        registry.log = { messages.append($0) }
        registry.openWindow = nil
        registry.ensureMainWindowVisible()
        registry.openNewMainWindow()

        #expect(messages.count == 2)
        #expect(messages.allSatisfy { $0.contains("no openWindow action captured") })
    }

    @Test("Ensure is a no-op while a main window is up")
    func ensureNoOpsWhenPresent() {
        withBalancedCount { registry in
            let previousLog = registry.log
            defer { registry.log = previousLog }

            var messages: [String] = []
            registry.log = { messages.append($0) }
            registry.registerMainWindow()
            registry.ensureMainWindowVisible()

            #expect(messages.isEmpty)
        }
    }
}

#endif
