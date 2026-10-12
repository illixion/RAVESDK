/*
 RAVESlideshow - local in-process display sync

 Remote transport and server coordination stay above the SDK. This coordinator
 only mirrors already-loaded slideshow state between local engine instances.
 */

import Foundation

public struct RAVESlideshowLocalSyncPayload: Equatable, Sendable {
    public var current: RAVESlideshowDisplayedMedia?
    public var incoming: RAVESlideshowDisplayedMedia?
    public var prefetched: [RAVESlideshowPrefetchedMedia]
    public var queuedItems: [RAVESlideshowItem]
    public var history: [RAVESlideshowItem]
    public var displaySettings: RAVESlideshowDisplaySettings
    public var visualSettings: RAVESlideshowVisualSettings

    public init(
        current: RAVESlideshowDisplayedMedia?,
        incoming: RAVESlideshowDisplayedMedia?,
        prefetched: [RAVESlideshowPrefetchedMedia],
        queuedItems: [RAVESlideshowItem],
        history: [RAVESlideshowItem],
        displaySettings: RAVESlideshowDisplaySettings,
        visualSettings: RAVESlideshowVisualSettings
    ) {
        self.current = current
        self.incoming = incoming
        self.prefetched = prefetched
        self.queuedItems = queuedItems
        self.history = history
        self.displaySettings = displaySettings
        self.visualSettings = visualSettings
    }
}

@MainActor
public final class RAVESlideshowLocalSyncCoordinator {
    public static let shared = RAVESlideshowLocalSyncCoordinator()

    private final class WeakEngine {
        weak var value: RAVESlideshowEngine?
        init(_ value: RAVESlideshowEngine) { self.value = value }
    }

    private var participants: [ObjectIdentifier: WeakEngine] = [:]

    public init() {}

    public func register(_ engine: RAVESlideshowEngine) {
        participants[ObjectIdentifier(engine)] = WeakEngine(engine)
    }

    public func unregister(_ engine: RAVESlideshowEngine) {
        participants.removeValue(forKey: ObjectIdentifier(engine))
    }

    public func broadcast(from sender: RAVESlideshowEngine, payload: RAVESlideshowLocalSyncPayload? = nil) {
        guard !sender.isApplyingLocalSync else { return }
        let senderID = ObjectIdentifier(sender)
        let snapshot = payload ?? sender.makeLocalSyncPayload()
        var stale: [ObjectIdentifier] = []
        for (id, ref) in participants where id != senderID {
            if let engine = ref.value {
                engine.applyLocalSync(snapshot)
            } else {
                stale.append(id)
            }
        }
        for id in stale {
            participants.removeValue(forKey: id)
        }
    }

    public func removeAll() {
        participants.removeAll()
    }
}
