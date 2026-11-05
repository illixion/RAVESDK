//
//  RAVELauncherShortcutStore.swift
//  RAVELauncher
//
//  The shortcuts the person approved, in UserDefaults under the app's key, with
//  each sent icon as a file beside them (icons can be 128 KB; defaults is no place
//  for a stack of those). Observable, so a launcher redraws when a request lands.
//

import Foundation
import Observation

@MainActor
@Observable
public final class RAVELauncherShortcutStore {
    /// Newest first.
    public private(set) var shortcuts: [RAVELauncherShortcut] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    @ObservationIgnored private let iconDirectory: URL

    /// - Parameters:
    ///   - key: the defaults key holding the JSON array. Keep an app's existing key
    ///     (Apparition: `launcher.shortcuts.v1`) or its pinned tiles vanish.
    ///   - iconDirectory: where sent icons are saved, created on first save.
    public init(defaults: UserDefaults = .standard, key: String, iconDirectory: URL) {
        self.defaults = defaults
        self.key = key
        self.iconDirectory = iconDirectory
        reload()
    }

    /// Reread defaults, for a change written by another store over the same key.
    public func reload() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RAVELauncherShortcut].self, from: data) else {
            shortcuts = []
            return
        }
        shortcuts = decoded
    }

    /// Save an approved request. A request for a target the same app already pinned
    /// replaces that tile (moved to the front, with the new title and icon) instead of
    /// adding a second.
    @discardableResult
    public func add(_ request: RAVELauncherShortcutRequest) throws -> RAVELauncherShortcut {
        let shortcutID = UUID()
        var iconFileName: String?
        if let data = request.iconData {
            try FileManager.default.createDirectory(at: iconDirectory, withIntermediateDirectories: true)
            let name = "\(shortcutID.uuidString).img"
            try data.write(to: iconDirectory.appendingPathComponent(name), options: .atomic)
            iconFileName = name
        }
        let shortcut = RAVELauncherShortcut(id: shortcutID, ownerBundleID: request.ownerBundleID,
                                            title: request.title, targetURL: request.targetURL,
                                            iconURL: request.iconURL, iconFileName: iconFileName)
        var updated = shortcuts
        let previous = updated.firstIndex {
            $0.ownerBundleID == request.ownerBundleID && $0.targetURL == request.targetURL
        }.map { updated.remove(at: $0) }
        updated.insert(shortcut, at: 0)
        do {
            try save(updated)
        } catch {
            if let iconFileName { try? FileManager.default.removeItem(at: iconDirectory.appendingPathComponent(iconFileName)) }
            throw error
        }
        if let previous { removeIcon(of: previous) }
        return shortcut
    }

    public func remove(id: UUID) {
        var updated = shortcuts
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        let removed = updated.remove(at: index)
        guard (try? save(updated)) != nil else { return }
        removeIcon(of: removed)
    }

    /// The saved image of a shortcut whose request sent one.
    public func iconFileURL(of shortcut: RAVELauncherShortcut) -> URL? {
        shortcut.iconFileName.map { iconDirectory.appendingPathComponent($0) }
    }

    private func save(_ updated: [RAVELauncherShortcut]) throws {
        defaults.set(try JSONEncoder().encode(updated), forKey: key)
        shortcuts = updated
    }

    private func removeIcon(of shortcut: RAVELauncherShortcut) {
        guard let url = iconFileURL(of: shortcut) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
