//
//  RAVELauncherItem.swift
//  RAVELauncher
//
//  What a launcher shows: tiles in sections, each with buttons. The launcher
//  knows nothing about what a tile opens. Apparition's tiles open installed
//  apps by URL and start JIT sessions; a host that runs apps as modules in its
//  own process opens them in place. Both are just actions.
//

import Foundation

public enum RAVELauncherIcon: Hashable, Sendable {
    /// Loaded over the network; nil draws the lettered placeholder.
    case remote(URL?)
    /// A PNG/JPEG on disk, such as a shortcut's saved icon.
    case file(URL)
    case data(Data)
    /// An SF Symbol drawn on the placeholder's gradient.
    case symbol(String)
}

/// What an action can reach while it runs.
@MainActor
public struct RAVELauncherContext {
    /// Hand `url` to the system (SwiftUI's `openURL`) and report whether an app took it.
    public let open: (URL) async -> Bool
}

public struct RAVELauncherAction: Identifiable {
    public enum Style: Sendable { case prominent, bordered, destructive }

    public let id: String
    public var title: String
    public var systemImage: String?
    public var style: Style
    public var isDisabled: Bool
    /// Set as the button's accessibility identifier, for UI tests and `_screen`.
    public var accessibilityIdentifier: String?
    /// Non-empty makes the action a menu of these instead of a button.
    public var children: [RAVELauncherAction]
    /// Runs on tap. A returned string is shown as the launcher's status line.
    public var perform: (@MainActor (RAVELauncherContext) async -> String?)?

    public init(id: String, title: String, systemImage: String? = nil, style: Style = .bordered,
                isDisabled: Bool = false, accessibilityIdentifier: String? = nil,
                children: [RAVELauncherAction] = [],
                perform: (@MainActor (RAVELauncherContext) async -> String?)? = nil) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.style = style
        self.isDisabled = isDisabled
        self.accessibilityIdentifier = accessibilityIdentifier
        self.children = children
        self.perform = perform
    }

    /// Open `url` in whatever app handles it, reporting whether one did.
    public static func open(_ url: URL, name: String, id: String = "open", title: String = "Open",
                            systemImage: String = "arrow.up.forward.app", style: Style = .prominent,
                            accessibilityIdentifier: String? = nil) -> RAVELauncherAction {
        RAVELauncherAction(id: id, title: title, systemImage: systemImage, style: style,
                           accessibilityIdentifier: accessibilityIdentifier) { context in
            await context.open(url) ? "Opened \(name)." : "No app accepted that launch link."
        }
    }
}

public struct RAVELauncherItem: Identifiable {
    public let id: String
    public var title: String
    public var icon: RAVELauncherIcon
    /// Stacked under the title, first one on top.
    public var actions: [RAVELauncherAction]
    /// The tile's context menu.
    public var menu: [RAVELauncherAction]

    public init(id: String, title: String, icon: RAVELauncherIcon,
                actions: [RAVELauncherAction] = [], menu: [RAVELauncherAction] = []) {
        self.id = id
        self.title = title
        self.icon = icon
        self.actions = actions
        self.menu = menu
    }
}

public struct RAVELauncherSection: Identifiable {
    public let id: String
    public var title: String?
    public var items: [RAVELauncherItem]
    /// Shown in place of an empty section while another section has tiles. With none,
    /// an empty section is left out.
    public var emptyMessage: String?

    public init(id: String, title: String? = nil, items: [RAVELauncherItem], emptyMessage: String? = nil) {
        self.id = id
        self.title = title
        self.items = items
        self.emptyMessage = emptyMessage
    }
}

public extension RAVELauncherShortcutStore {
    /// The approved shortcuts as tiles: Open, and Remove from Home in the menu.
    func items() -> [RAVELauncherItem] {
        shortcuts.map { shortcut in
            let icon: RAVELauncherIcon = iconFileURL(of: shortcut).map { .file($0) }
                ?? .remote(shortcut.iconURL.flatMap(URL.init(string:)))
            var actions: [RAVELauncherAction] = []
            if let url = URL(string: shortcut.targetURL) {
                actions.append(.open(url, name: shortcut.title))
            }
            let remove = RAVELauncherAction(id: "remove", title: "Remove from Home", systemImage: "trash",
                                            style: .destructive) { [weak self] _ in
                self?.remove(id: shortcut.id)
                return nil
            }
            return RAVELauncherItem(id: "shortcut-\(shortcut.id.uuidString)", title: shortcut.title,
                                    icon: icon, actions: actions, menu: [remove])
        }
    }
}
