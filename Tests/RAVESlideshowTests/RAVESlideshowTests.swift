import Foundation
import Testing
@testable import RAVESlideshow

@MainActor
@Suite("RAVESlideshowEngine", .serialized)
struct RAVESlideshowEngineTests {
    @Test("Start displays the first item and fills a bounded prefetch buffer")
    func startDisplaysFirstItemAndPrefetches() async throws {
        let provider = FixtureProvider(items: Self.items(5))
        let engine = RAVESlideshowEngine(
            provider: provider,
            displaySettings: .init(delay: 60, transitionDuration: 0),
            configuration: .init(prefetchLimit: 2, automaticAdvancement: false, platformCapabilities: .iOSFallback)
        )
        defer { engine.stop() }

        engine.start()
        await engine.waitUntilIdleForTesting()

        #expect(engine.current?.item.id == "item-0")
        #expect(engine.prefetched.map(\.item.id) == ["item-1", "item-2"])
        #expect(engine.prefetched.count <= 2)
        #expect(provider.displayed == ["item-0"])
    }

    @Test("Manual next and previous navigate through history")
    func manualNavigationUsesHistory() async throws {
        let provider = FixtureProvider(items: Self.items(4))
        let engine = RAVESlideshowEngine(
            provider: provider,
            displaySettings: .init(delay: 60, transitionDuration: 0),
            configuration: .init(prefetchLimit: 1, automaticAdvancement: false, platformCapabilities: .iOSFallback)
        )
        defer { engine.stop() }

        engine.start()
        await engine.waitUntilIdleForTesting()
        engine.advanceToNext()
        await engine.waitUntilIdleForTesting()
        #expect(engine.current?.item.id == "item-1")

        engine.previous()
        await engine.waitUntilIdleForTesting()
        #expect(engine.current?.item.id == "item-0")
    }

    @Test("Reset cancels stale loads before they can replace the new source")
    func resetCancelsStaleLoads() async throws {
        let provider = FixtureProvider(items: Self.items(1), loadDelay: 0.15)
        let engine = RAVESlideshowEngine(
            provider: provider,
            displaySettings: .init(delay: 60, transitionDuration: 0),
            configuration: .init(prefetchLimit: 1, automaticAdvancement: false, platformCapabilities: .iOSFallback)
        )
        defer { engine.stop() }

        engine.start()
        provider.items = [Self.item("replacement")]
        engine.resetSource(clearCurrent: true)
        await engine.waitUntilIdleForTesting()

        #expect(engine.current?.item.id == "replacement")
    }

    @Test("Pause and background preserve the current item and trim lookahead")
    func pauseAndBackgroundPreserveCurrentContent() async throws {
        let provider = FixtureProvider(items: Self.items(5))
        let engine = RAVESlideshowEngine(
            provider: provider,
            displaySettings: .init(delay: 60, transitionDuration: 0),
            configuration: .init(prefetchLimit: 3, automaticAdvancement: false, platformCapabilities: .iOSFallback)
        )
        defer { engine.stop() }

        engine.start()
        await engine.waitUntilIdleForTesting()
        #expect(engine.prefetched.count == 3)

        engine.togglePause()
        #expect(engine.state == .paused)
        engine.setVisible(false)
        #expect(engine.state == .backgrounded)
        #expect(engine.current?.item.id == "item-0")
        #expect(engine.prefetched.isEmpty)

        engine.setVisible(true)
        #expect(engine.state == .paused)
        #expect(engine.current?.item.id == "item-0")
    }

    @Test("Local sync copies media state and suppresses feedback broadcasts")
    func localSyncCopiesPayloadWithoutFeedback() async throws {
        let providerA = FixtureProvider(items: Self.items(3))
        let providerB = FixtureProvider(items: Self.items(3).map { item in
            var copy = item
            copy.id = "other-\(item.id)"
            return copy
        })
        let a = RAVESlideshowEngine(
            provider: providerA,
            displaySettings: .init(delay: 60, transitionDuration: 0),
            visualSettings: .init(brightness: 0.1, contrast: 1.2, saturation: 0.8, opacity: 0.9),
            configuration: .init(automaticAdvancement: false, platformCapabilities: .iOSFallback)
        )
        let b = RAVESlideshowEngine(
            provider: providerB,
            displaySettings: .init(delay: 60, transitionDuration: 0),
            configuration: .init(automaticAdvancement: false, platformCapabilities: .iOSFallback)
        )
        let hub = RAVESlideshowLocalSyncCoordinator()
        defer {
            a.stop()
            b.stop()
            hub.removeAll()
        }
        hub.register(a)
        hub.register(b)

        a.start()
        await a.waitUntilIdleForTesting()
        hub.broadcast(from: a)

        #expect(b.current?.item.id == a.current?.item.id)
        #expect(b.visualSettings == a.visualSettings)
        #expect(!b.isApplyingLocalSync)
    }

    @Test("Unsupported platform capabilities disable spatial-only display settings")
    func platformCapabilitiesDisableSpatialSettings() {
        let settings = RAVESlideshowDisplaySettings(
            enableKenBurns: true,
            enableDiorama: true,
            mode3D: .immersive3D
        )

        let resolved = settings.resolved(for: .iOSFallback)

        #expect(resolved.mode3D == .off)
        #expect(!resolved.enableDiorama)
    }

    @Test("Empty sources surface no content and can recover after reset")
    func emptySourceCanRecoverAfterReset() async throws {
        let provider = FixtureProvider(items: [])
        let engine = RAVESlideshowEngine(
            provider: provider,
            displaySettings: .init(delay: 60, transitionDuration: 0),
            configuration: .init(automaticAdvancement: false, platformCapabilities: .iOSFallback)
        )
        defer { engine.stop() }

        engine.start()
        await engine.waitUntilIdleForTesting()
        #expect(engine.state == .idle)
        #expect(engine.current == nil)
        #expect(engine.lastError as? RAVESlideshowError == .noContent)

        provider.items = [Self.item("late")]
        engine.resetSource()
        await engine.waitUntilIdleForTesting()
        #expect(engine.current?.item.id == "late")
    }

    @Test("Server-driven engines do not advance from the local next command")
    func serverDrivenNextDoesNotLocallyAdvance() async throws {
        let provider = FixtureProvider(items: Self.items(3))
        let engine = RAVESlideshowEngine(
            provider: provider,
            displaySettings: .init(delay: 0.05, transitionDuration: 0),
            configuration: .init(
                prefetchLimit: 1,
                serverDriven: true,
                automaticAdvancement: true,
                platformCapabilities: .iOSFallback
            )
        )
        defer { engine.stop() }

        engine.start()
        await engine.waitUntilIdleForTesting()
        let first = engine.current?.item.id

        engine.advanceToNext()
        try? await Task.sleep(for: .milliseconds(120))

        #expect(engine.current?.item.id == first)
    }

    @Test("Visual changes publish the merged settings callback")
    func visualSettingsNotifyConsumers() {
        let provider = FixtureProvider(items: Self.items(1))
        let engine = RAVESlideshowEngine(
            provider: provider,
            configuration: .init(automaticAdvancement: false, platformCapabilities: .iOSFallback)
        )
        defer { engine.stop() }
        var seen: RAVESlideshowVisualSettings?
        engine.onSettingsChanged = { _, visual in seen = visual }

        engine.visualSettings = .init(brightness: 0.2, contrast: 1.1, saturation: 0.7, opacity: 0.5)

        #expect(seen == engine.visualSettings)
    }

    private static func items(_ count: Int) -> [RAVESlideshowItem] {
        (0..<count).map { item("item-\($0)") }
    }

    private static func item(_ id: String) -> RAVESlideshowItem {
        RAVESlideshowItem(
            id: id,
            title: id,
            mediaKind: .image,
            fileExtension: "jpg",
            metadata: ["url": "https://example.com/\(id).jpg"]
        )
    }
}

@MainActor
private final class FixtureProvider: RAVESlideshowContentProvider {
    var items: [RAVESlideshowItem]
    var displayed: [String] = []
    var loadDelay: TimeInterval

    init(items: [RAVESlideshowItem], loadDelay: TimeInterval = 0) {
        self.items = items
        self.loadDelay = loadDelay
    }

    func fetchMoreContent(_ request: RAVESlideshowFetchRequest) async throws -> [RAVESlideshowItem] {
        let batch = Array(items.prefix(max(1, request.minimumBatchSize)))
        items.removeFirst(min(items.count, batch.count))
        return batch
    }

    func loadMedia(for item: RAVESlideshowItem, maxResolution: Int) async throws -> RAVESlideshowLoadedMedia {
        if loadDelay > 0 {
            try? await Task.sleep(for: .milliseconds(Int(loadDelay * 1000)))
        }
        return .still(data: Data(item.id.utf8), displayURL: displayURL(for: item))
    }

    func displayURL(for item: RAVESlideshowItem) -> URL? {
        URL(string: item.metadata["url"] ?? "https://example.com/\(item.id)")
    }

    func didDisplay(_ item: RAVESlideshowItem) async {
        displayed.append(item.id)
    }
}
