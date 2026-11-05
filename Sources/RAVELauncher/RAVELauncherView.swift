//
//  RAVELauncherView.swift
//  RAVELauncher
//
//  The launcher screen: a title, sections of tiles on glass platters, and one
//  status line that reports what the last action did ("No app accepted that
//  launch link."). Builds on every platform the package declares; the shape is
//  Apparition's visionOS Home tab.
//

import CoreGraphics
import Foundation
import ImageIO
import RAVEUI
import SwiftUI

public struct RAVELauncherView: View {
    public struct EmptyState {
        public var title: String
        public var systemImage: String
        public var message: String

        public init(title: String, systemImage: String = "square.grid.2x2", message: String) {
            self.title = title
            self.systemImage = systemImage
            self.message = message
        }
    }

    let title: String
    let subtitle: String?
    let sections: [RAVELauncherSection]
    let emptyState: EmptyState

    @Environment(\.openURL) private var openURL
    @State private var status: String?
    @State private var running: Set<String> = []

    public init(title: String = "Home", subtitle: String? = nil, sections: [RAVELauncherSection],
                emptyState: EmptyState) {
        self.title = title
        self.subtitle = subtitle
        self.sections = sections
        self.emptyState = emptyState
    }

    private static let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 20)]

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // The title is `raveScreenTitle`'s: the bar's on visionOS, a heading that
                // scrolls with the content on tvOS. A second one here showed it twice.
                if let subtitle { Text(subtitle).foregroundStyle(.secondary) }

                let anyItems = sections.contains { !$0.items.isEmpty }
                if anyItems {
                    ForEach(sections) { section in
                        sectionView(section)
                    }
                } else {
                    ContentUnavailableView(emptyState.title, systemImage: emptyState.systemImage,
                                           description: Text(emptyState.message))
                        .frame(maxWidth: .infinity, minHeight: 240)
                }

                if let status {
                    Label(status, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("launcherStatus")
                }
            }
            .padding(32)
        }
        .raveScreenTitle(title)
    }

    @ViewBuilder
    private func sectionView(_ section: RAVELauncherSection) -> some View {
        if !section.items.isEmpty || section.emptyMessage != nil {
            VStack(alignment: .leading, spacing: 16) {
                if let title = section.title {
                    Text(title).font(.title2.weight(.semibold))
                }
                if section.items.isEmpty, let message = section.emptyMessage {
                    Text(message).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: Self.columns, spacing: 20) {
                        ForEach(section.items) { item in
                            tile(item, in: section)
                        }
                    }
                }
            }
        }
    }

    private func tile(_ item: RAVELauncherItem, in section: RAVELauncherSection) -> some View {
        VStack(spacing: 12) {
            RAVELauncherIconView(icon: item.icon, name: item.title, size: 88)
            Text(item.title)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            ForEach(item.actions) { action in
                actionView(action, key: "\(section.id)/\(item.id)/\(action.id)")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 190)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .modifier(TileMenu(isEmpty: item.menu.isEmpty) {
            ForEach(item.menu) { action in
                menuEntry(action, key: "\(section.id)/\(item.id)/menu/\(action.id)")
            }
        })
    }

    /// A context menu only when there is something in it: an empty one still answers the
    /// long press with a lift and nothing to choose.
    private struct TileMenu<MenuContent: View>: ViewModifier {
        let isEmpty: Bool
        @ViewBuilder let menu: () -> MenuContent

        func body(content: Content) -> some View {
            if isEmpty {
                content
            } else {
                content.contextMenu { menu() }
            }
        }
    }

    @ViewBuilder
    private func actionView(_ action: RAVELauncherAction, key: String) -> some View {
        let label = actionLabel(action).frame(maxWidth: .infinity)
        Group {
            if action.children.isEmpty {
                let button = Button(role: action.style == .destructive ? .destructive : nil) { run(action, key: key) } label: { label }
                if action.style == .prominent {
                    button.buttonStyle(.borderedProminent)
                } else {
                    button.buttonStyle(.bordered)
                }
            } else {
                Menu {
                    ForEach(action.children) { child in
                        menuEntry(child, key: "\(key)/\(child.id)")
                    }
                } label: { label }
                .buttonStyle(.bordered)
            }
        }
        .disabled(action.isDisabled || running.contains(key))
        .accessibilityIdentifier(action.accessibilityIdentifier ?? key)
    }

    @ViewBuilder
    private func menuEntry(_ action: RAVELauncherAction, key: String) -> some View {
        Button(role: action.style == .destructive ? .destructive : nil) { run(action, key: key) } label: {
            actionLabel(action)
        }
        .disabled(action.isDisabled)
    }

    @ViewBuilder
    private func actionLabel(_ action: RAVELauncherAction) -> some View {
        if let systemImage = action.systemImage {
            Label(action.title, systemImage: systemImage)
        } else {
            Text(action.title)
        }
    }

    private func run(_ action: RAVELauncherAction, key: String) {
        guard let perform = action.perform, !running.contains(key) else { return }
        running.insert(key)
        let open = openURL
        let context = RAVELauncherContext { url in
            await withCheckedContinuation { continuation in
                open(url) { accepted in continuation.resume(returning: accepted) }
            }
        }
        Task {
            let message = await perform(context)
            running.remove(key)
            if let message { status = message }
        }
    }
}

/// A tile's icon: the image, or a lettered (or symbol) gradient tile when there is none or
/// it fails to load.
public struct RAVELauncherIconView: View {
    let icon: RAVELauncherIcon
    let name: String
    var size: CGFloat

    public init(icon: RAVELauncherIcon, name: String, size: CGFloat = 64) {
        self.icon = icon
        self.name = name
        self.size = size
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        content
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch icon {
        case .remote(let url?):
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    placeholder(symbol: nil)
                }
            }
        case .remote(nil):
            placeholder(symbol: nil)
        case .file(let url):
            decoded(CGImageSourceCreateWithURL(url as CFURL, nil))
        case .data(let data):
            decoded(CGImageSourceCreateWithData(data as CFData, nil))
        case .symbol(let name):
            placeholder(symbol: name)
        }
    }

    @ViewBuilder
    private func decoded(_ source: CGImageSource?) -> some View {
        if let source, let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            Image(decorative: image, scale: 1).resizable().scaledToFill()
        } else {
            placeholder(symbol: nil)
        }
    }

    private func placeholder(symbol: String?) -> some View {
        ZStack {
            LinearGradient(colors: [.indigo.opacity(0.8), .purple.opacity(0.6)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Text(name.prefix(1).uppercased())
                    .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
    }
}
