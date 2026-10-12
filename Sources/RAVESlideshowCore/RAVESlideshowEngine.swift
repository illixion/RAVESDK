/*
 RAVESlideshow - source-agnostic slideshow state machine

 The engine owns lifecycle, bounded prefetch, navigation, local sync snapshots,
 and pause/background semantics. It intentionally does not know about app
 windows, RoboFrame frames, Stash filters, depth caches, or WebSocket transport.
 */

import Foundation
import Observation

@MainActor
@Observable
public final class RAVESlideshowEngine {
    public enum State: Equatable, CustomStringConvertible, Sendable {
        case idle
        case loading
        case displaying
        case transitioning
        case paused
        case backgrounded
        case stopped

        public var description: String {
            switch self {
            case .idle: "idle"
            case .loading: "loading"
            case .displaying: "displaying"
            case .transitioning: "transitioning"
            case .paused: "paused"
            case .backgrounded: "backgrounded"
            case .stopped: "stopped"
            }
        }
    }

    public private(set) var state: State = .idle
    public private(set) var current: RAVESlideshowDisplayedMedia?
    public private(set) var incoming: RAVESlideshowDisplayedMedia?
    public private(set) var prefetched: [RAVESlideshowPrefetchedMedia] = []
    public private(set) var queuedItems: [RAVESlideshowItem] = []
    public private(set) var history: [RAVESlideshowItem] = []
    public private(set) var previousItem: RAVESlideshowItem?
    public private(set) var isLoading = false
    public private(set) var fetchReturnedEmpty = false
    public private(set) var lastError: Error?
    public private(set) var stateVersion = 0
    public private(set) var isApplyingLocalSync = false

    public var displaySettings: RAVESlideshowDisplaySettings {
        didSet {
            let resolved = displaySettings.resolved(for: configuration.platformCapabilities)
            guard resolved == displaySettings else {
                displaySettings = resolved
                return
            }
            onSettingsChanged?(displaySettings, visualSettings)
        }
    }
    public var visualSettings: RAVESlideshowVisualSettings {
        didSet { onSettingsChanged?(displaySettings, visualSettings) }
    }
    public var blockedItemIDs: Set<String> = []
    public var blockedTags: Set<String> = []
    public var preferredAspectRatio: Double?
    public var onTransition: ((RAVESlideshowDisplayedMedia) -> Void)?
    public var onSettingsChanged: ((RAVESlideshowDisplaySettings, RAVESlideshowVisualSettings) -> Void)?

    public var effectiveColorAdjustments: RAVESlideshowColorAdjustments {
        let automatic = current?.automaticColorAdjustment ?? .neutral
        return RAVESlideshowColorAdjustments(
            brightness: automatic.brightness + visualSettings.brightness,
            contrast: automatic.contrast * visualSettings.contrast,
            saturation: automatic.saturation * visualSettings.saturation
        )
    }

    public var peekedNext: RAVESlideshowPrefetchedMedia? {
        if configuration.serverDriven, let authoritativeNextItemID {
            return prefetched.first(where: { $0.item.id == authoritativeNextItemID })
        }
        return prefetched.first
    }

    private var provider: any RAVESlideshowContentProvider
    private let configuration: RAVESlideshowConfiguration
    private var runLoopTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var prefetchInProgress = false
    private var stateBeforeBackground: State?
    private var pauseStartedAt: Date?
    private var displayDeadline: Date?
    private var pendingItem: RAVESlideshowItem?
    private var authoritativeCurrentItem: RAVESlideshowItem?
    private var authoritativeNextItemID: String?
    private var generation = 0

    public init(
        provider: any RAVESlideshowContentProvider,
        displaySettings: RAVESlideshowDisplaySettings = RAVESlideshowDisplaySettings(),
        visualSettings: RAVESlideshowVisualSettings = .neutral,
        configuration: RAVESlideshowConfiguration = RAVESlideshowConfiguration()
    ) {
        self.provider = provider
        self.configuration = configuration
        self.displaySettings = displaySettings.resolved(for: configuration.platformCapabilities)
        self.visualSettings = visualSettings
    }

    isolated deinit {
        runLoopTask?.cancel()
        prefetchTask?.cancel()
    }

    public func start() {
        guard state == .idle else { return }
        transition(to: .loading)
        startRunLoop()
    }

    public func stop() {
        transition(to: .stopped)
        runLoopTask?.cancel()
        runLoopTask = nil
        cancelPrefetch()
        generation += 1
    }

    public func resetSource(clearCurrent: Bool = false) {
        generation += 1
        queuedItems.removeAll()
        prefetched.removeAll()
        pendingItem = nil
        fetchReturnedEmpty = false
        cancelPrefetch()
        provider.resetPagination()
        if clearCurrent {
            current = nil
            incoming = nil
            history.removeAll()
            previousItem = nil
        }
        if state != .stopped {
            transition(to: .loading)
        }
    }

    public func setAuthoritativeCurrent(_ item: RAVESlideshowItem?) {
        authoritativeCurrentItem = item
        reconcileAuthoritativeCurrent()
    }

    public func setAuthoritativeNextItemID(_ itemID: String?) {
        authoritativeNextItemID = itemID
    }

    public func prunePrefetched(keeping itemIDs: Set<String>) {
        guard configuration.serverDriven else { return }
        prefetched.removeAll { !itemIDs.contains($0.item.id) }
    }

    public func advanceToNext() {
        guard !configuration.serverDriven else { return }
        pendingItem = nil
        if state != .stopped {
            transition(to: .loading)
        }
    }

    public func previous() {
        guard history.count >= 2 else { return }
        if let currentItem = current?.item {
            queuedItems.insert(currentItem, at: 0)
        }
        history.removeLast()
        pendingItem = history.last
        if state != .stopped {
            transition(to: .loading)
        }
    }

    public func jump(to item: RAVESlideshowItem) {
        pendingItem = item
        if state != .stopped {
            transition(to: .loading)
        }
    }

    public func togglePause() {
        switch state {
        case .displaying, .loading, .transitioning:
            transition(to: .paused)
        case .paused:
            transition(to: current == nil ? .loading : .displaying)
        default:
            break
        }
    }

    public func setVisible(_ visible: Bool) {
        if visible {
            guard state == .backgrounded else { return }
            let restore = stateBeforeBackground ?? .displaying
            stateBeforeBackground = nil
            transition(to: restore == .paused ? .paused : (current == nil ? .loading : .displaying))
            triggerPrefetch()
            reconcileAuthoritativeCurrent()
        } else {
            guard state != .stopped, state != .idle, state != .backgrounded else { return }
            stateBeforeBackground = state
            trimForBackground()
            transition(to: .backgrounded)
        }
    }

    public func trimForBackground() {
        prefetched.removeAll(keepingCapacity: false)
        cancelPrefetch()
    }

    public func trimForMemoryPressure(keepingPrefetched count: Int = 1) {
        if prefetched.count > count {
            prefetched = Array(prefetched.prefix(max(0, count)))
        }
    }

    public func makeLocalSyncPayload() -> RAVESlideshowLocalSyncPayload {
        RAVESlideshowLocalSyncPayload(
            current: current,
            incoming: incoming,
            prefetched: prefetched,
            queuedItems: queuedItems,
            history: history,
            displaySettings: displaySettings,
            visualSettings: visualSettings
        )
    }

    public func applyLocalSync(_ payload: RAVESlideshowLocalSyncPayload) {
        isApplyingLocalSync = true
        defer { isApplyingLocalSync = false }

        generation += 1
        cancelPrefetch()
        current = payload.current
        incoming = payload.incoming
        prefetched = payload.prefetched
        queuedItems = payload.queuedItems
        history = payload.history
        displaySettings = payload.displaySettings.resolved(for: configuration.platformCapabilities)
        visualSettings = payload.visualSettings
        if state != .stopped {
            transition(to: current == nil ? .loading : .displaying)
        }
    }

    public func waitUntilIdleForTesting() async {
        while isLoading || prefetchInProgress || state == .loading || state == .transitioning {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func transition(to newState: State) {
        guard state != newState else { return }
        guard state != .stopped || newState == .stopped else { return }

        let oldState = state
        let wasPaused = oldState == .paused || (oldState == .backgrounded && stateBeforeBackground == .paused)
        let willPause = newState == .paused || (newState == .backgrounded && oldState == .paused)
        if !wasPaused && willPause {
            pauseStartedAt = Date()
        } else if wasPaused && !willPause {
            if let start = pauseStartedAt, let deadline = displayDeadline {
                displayDeadline = deadline.addingTimeInterval(Date().timeIntervalSince(start))
            }
            pauseStartedAt = nil
        }

        state = newState
        stateVersion += 1
    }

    private func startRunLoop() {
        guard runLoopTask == nil else { return }
        runLoopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.state != .stopped {
                switch self.state {
                case .loading:
                    await self.runLoadingPhase()
                case .displaying:
                    await self.runDisplayingPhase()
                case .paused, .backgrounded:
                    await self.waitForStateChange()
                case .transitioning:
                    try? await Task.sleep(for: .milliseconds(10))
                case .idle:
                    await self.waitForStateChange()
                case .stopped:
                    return
                }
            }
        }
    }

    private func waitForStateChange() async {
        let version = stateVersion
        while stateVersion == version && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func runLoadingPhase() async {
        isLoading = true
        defer { isLoading = false }

        let runGeneration = generation
        let selected: RAVESlideshowPrefetchedMedia?
        if let pendingItem {
            self.pendingItem = nil
            selected = await loadForDisplay(pendingItem, generation: runGeneration)
        } else if let first = prefetched.first {
            prefetched.removeFirst()
            selected = first
        } else {
            if queuedItems.isEmpty {
                await fetchMoreItems(reason: current == nil ? .initial : .prefetch)
            }
            if let next = nextAllowedQueuedItem() {
                selected = await loadForDisplay(next, generation: runGeneration)
            } else {
                selected = nil
            }
        }

        guard runGeneration == generation, state == .loading else { return }

        if let selected {
            await display(selected, generation: runGeneration)
            triggerPrefetch()
        } else {
            if current == nil {
                lastError = RAVESlideshowError.noContent
            }
            displayDeadline = Date().addingTimeInterval(configuration.steadyStateRetryDelay)
            transition(to: current == nil ? .idle : .displaying)
            triggerPrefetch()
        }
    }

    private func runDisplayingPhase() async {
        guard configuration.automaticAdvancement else {
            await waitForStateChange()
            return
        }
        if configuration.serverDriven {
            await waitForStateChange()
            return
        }
        if displayDeadline == nil {
            advanceDisplayDeadline()
        }
        let version = stateVersion
        while state == .displaying, stateVersion == version {
            let remaining = displayDeadline?.timeIntervalSince(Date()) ?? 0
            if remaining <= 0 { break }
            try? await Task.sleep(for: .milliseconds(Int(min(remaining, 0.25) * 1000)))
        }
        if state == .displaying, stateVersion == version {
            transition(to: .loading)
        }
    }

    private func loadForDisplay(_ item: RAVESlideshowItem, generation: Int) async -> RAVESlideshowPrefetchedMedia? {
        let resolution = displaySettings.mode3D == .off ? displaySettings.maxImageResolution2D : displaySettings.maxImageResolution3D
        for attempt in 0...configuration.retryLimit {
            do {
                let media = try await provider.loadMedia(for: item, maxResolution: resolution)
                guard generation == self.generation, !Task.isCancelled else { return nil }
                return RAVESlideshowPrefetchedMedia(item: item, media: media)
            } catch {
                lastError = error
                guard attempt < configuration.retryLimit else { return nil }
                try? await Task.sleep(for: .milliseconds(attempt == 0 ? 100 : 250))
            }
        }
        return nil
    }

    private func display(_ prefetched: RAVESlideshowPrefetchedMedia, generation: Int) async {
        guard generation == self.generation else { return }
        previousItem = current?.item
        let displayed = RAVESlideshowDisplayedMedia(
            item: prefetched.item,
            media: prefetched.media,
            automaticColorAdjustment: automaticAdjustment(for: prefetched.media)
        )

        if current == nil || displaySettings.reduceMotion || displaySettings.transitionDuration <= 0 {
            current = displayed
            incoming = nil
        } else {
            transition(to: .transitioning)
            incoming = displayed
            try? await Task.sleep(for: .milliseconds(Int(displaySettings.transitionDuration * 1000)))
            guard generation == self.generation, state == .transitioning else { return }
            current = displayed
            incoming = nil
        }

        history.append(prefetched.item)
        if history.count > 100 { history.removeFirst(history.count - 100) }
        advanceDisplayDeadline()
        if state == .transitioning || state == .loading {
            transition(to: .displaying)
        }
        onTransition?(displayed)
        await provider.didDisplay(prefetched.item)
    }

    private func automaticAdjustment(for media: RAVESlideshowLoadedMedia) -> RAVESlideshowColorAdjustments {
        guard displaySettings.enableDynamicBrightness else { return .neutral }
        guard case .still(let data, _) = media else { return .neutral }
        let sample = data.prefix(128).reduce(0) { $0 + Int($1) }
        guard !data.isEmpty else { return .neutral }
        let luminance = Double(sample) / Double(min(data.count, 128) * 255)
        guard luminance < 0.3 else { return .neutral }
        let boost = (0.3 - luminance) * 0.5
        return RAVESlideshowColorAdjustments(brightness: boost, contrast: 1 + boost * 0.5, saturation: 1)
    }

    private func advanceDisplayDeadline() {
        let delay = effectiveDelay
        let now = Date()
        if let previous = displayDeadline, now >= previous {
            let continued = previous.addingTimeInterval(delay)
            displayDeadline = continued > now ? continued : now.addingTimeInterval(delay)
        } else {
            displayDeadline = now.addingTimeInterval(delay)
        }
        pauseStartedAt = nil
    }

    private var effectiveDelay: TimeInterval {
        if case .video = current?.media, let duration = current?.item.duration, duration > displaySettings.delay {
            return duration
        }
        return displaySettings.delay
    }

    private func triggerPrefetch() {
        guard !prefetchInProgress, state != .stopped, state != .backgrounded else { return }
        prefetchInProgress = true
        let runGeneration = generation
        prefetchTask = Task { [weak self] in
            await self?.prefetch(generation: runGeneration)
            await MainActor.run {
                self?.prefetchInProgress = false
            }
        }
    }

    private func cancelPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchInProgress = false
    }

    private func prefetch(generation: Int) async {
        while generation == self.generation,
              prefetched.count < configuration.prefetchLimit,
              !Task.isCancelled {
            if queuedItems.isEmpty {
                await fetchMoreItems(reason: .prefetch)
            }
            guard let item = nextAllowedQueuedItem() else { break }
            guard let loaded = await loadForDisplay(item, generation: generation) else { continue }
            guard generation == self.generation, !Task.isCancelled else { return }
            prefetched.append(loaded)
        }
    }

    private func fetchMoreItems(reason: RAVESlideshowFetchRequest.Reason) async {
        do {
            let request = RAVESlideshowFetchRequest(
                reason: reason,
                preferredAspectRatio: displaySettings.useAspectRatio ? preferredAspectRatio : nil,
                excludedItemIDs: blockedItemIDs,
                excludedTags: blockedTags
            )
            let items = try await provider.fetchMoreContent(request)
            let allowed = items.filter(isAllowed)
            queuedItems.append(contentsOf: allowed)
            fetchReturnedEmpty = items.isEmpty
        } catch {
            lastError = error
            fetchReturnedEmpty = true
        }
    }

    private func nextAllowedQueuedItem() -> RAVESlideshowItem? {
        while !queuedItems.isEmpty {
            let item = queuedItems.removeFirst()
            if isAllowed(item) { return item }
        }
        return nil
    }

    private func isAllowed(_ item: RAVESlideshowItem) -> Bool {
        !blockedItemIDs.contains(item.id) && item.tags.isDisjoint(with: blockedTags)
    }

    private func reconcileAuthoritativeCurrent() {
        guard configuration.serverDriven, let target = authoritativeCurrentItem else { return }
        guard state == .displaying || state == .idle else { return }
        guard target.id != current?.item.id else { return }
        pendingItem = target
        transition(to: .loading)
    }
}

public enum RAVESlideshowError: Error, Equatable, Sendable {
    case noContent
}
