//
//  RAVEBrowserProfile.swift
//  RAVEBrowser
//
//  A browser profile's storage: an isolated cookie and login jar, so two tabs
//  on the same site can be two different accounts (Raven's windows), or a
//  logged-out page can sit beside a logged-in one (spatial-ai-character's
//  ambient screen beside a call).
//
//  A profile is an identity that resolves to a `WKWebsiteDataStore`, and
//  `dataStore` is the one place that resolution happens, so the default
//  sentinel can never leak into a `forIdentifier:` call by accident. What a
//  profile is *called*, its badge, where the list of them persists, all stay
//  with the app (Raven's `ProfileStore`).
//
//  The default profile is not a created one: it is `WKWebsiteDataStore
//  .default()`, the store every WKWebView uses unless told otherwise. It has
//  no separate on-disk store of its own, so it is never removed.
//
//  Its id is a fixed UUID because apps persist it (Raven keys bookmarks,
//  history and settings on it); changing it would orphan all of that.
//

#if canImport(WebKit)
import Foundation
import WebKit

public struct RAVEBrowserProfile: Hashable, Sendable, Identifiable {
    public let id: UUID

    /// The shared default store's id. Persisted by apps; never change it.
    public static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let `default` = RAVEBrowserProfile(id: defaultID)

    public init(id: UUID) {
        self.id = id
    }

    public var isDefault: Bool { id == Self.defaultID }

    /// The store a tab on this profile browses with. Every tab of a profile
    /// shares it, so a login in one is a login in all of them; a tab can
    /// never change store after it is built.
    @MainActor
    public var dataStore: WKWebsiteDataStore {
        isDefault ? .default() : WKWebsiteDataStore(forIdentifier: id)
    }

    /// Deletes a created profile's on-disk store. Best-effort: WebKit refuses
    /// while any `WKWebsiteDataStore` instance for the id is still alive, and
    /// tab teardown is ARC-timed, so a removal can race the last tab's
    /// release. `reclaimOrphanedStores(keeping:)` at the next launch is the
    /// backstop for exactly that race. Does nothing for the default profile.
    @MainActor
    public static func removeStore(for id: UUID) {
        guard id != defaultID else { return }
        WKWebsiteDataStore.remove(forIdentifier: id) { error in
            if let error {
                RAVEBrowserLog.browser.error("""
                could not reclaim profile store: \(error.raveLogCode, privacy: .public) \
                \(error.localizedDescription, privacy: .private)
                """)
            }
        }
    }

    /// Removes every store WebKit still has on disk for a profile that no
    /// longer exists — what a raced `removeStore(for:)` leaves behind. Run
    /// once at startup rather than retried in place: the failure is "another
    /// store instance was alive a moment ago", which a fresh launch has none
    /// of.
    @MainActor
    public static func reclaimOrphanedStores(keeping known: Set<UUID>) {
        WKWebsiteDataStore.fetchAllDataStoreIdentifiers { identifiers in
            for identifier in identifiers where !known.contains(identifier) {
                WKWebsiteDataStore.remove(forIdentifier: identifier) { _ in }
            }
        }
    }
}
#endif
