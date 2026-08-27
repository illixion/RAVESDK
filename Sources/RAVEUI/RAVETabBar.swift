/*
 RAVE SDK — the ornament tab bar.

 Three apps carry this and the button is byte-identical in all three: an
 icon-only capsule that expands into a labelled glass pill when selected, 44×32
 minimum, 10/14pt horizontal padding by selection, `.smooth(duration: 0.22)`.
 Longwave's copy even credits Spatial Stash's in a comment.

 What is deliberately *not* here is the bar's contents. Spatial Stash puts a
 slideshow launcher past a divider, Longwave puts live broadcast indicators
 there, Spatial Home puts nothing — and which tabs are visible depends on app
 settings in two of the three. So the container takes the tabs and a trailing
 accessory, and the app keeps deciding both.
 */

// `glassBackgroundEffect` and `hoverEffect` are visionOS-only.
#if os(visionOS)

import SwiftUI

/// Anything the tab bar can display.
///
/// Apps already model their tabs as a `String`-raw-valued enum whose raw value
/// is the display name, so that is the shape adopted here rather than invented.
public protocol RAVETabItem: Hashable, Identifiable {
    /// Shown in the pill when selected, and as the accessibility/help label.
    var title: String { get }
    /// SF Symbol name.
    var systemImage: String { get }
    /// What XCUITest matches this tab on. Defaults to the title, which is
    /// display copy — override it with something stable (an enum case name) in
    /// any app whose tab titles are expected to change.
    var accessibilityIdentifier: String { get }
}

public extension RAVETabItem where Self: RawRepresentable, Self.RawValue == String {
    var title: String { rawValue }
}

public extension RAVETabItem where Self: Hashable {
    var id: Self { self }
}

public extension RAVETabItem {
    var accessibilityIdentifier: String { RAVEA11y.tab(title) }
}

/// The ornament bar: a row of tab buttons, optionally followed by app-specific
/// trailing content past a divider.
///
/// Mount it the way all three apps do:
/// ```swift
/// .ornament(attachmentAnchor: .scene(.bottomFront)) {
///     RAVETabBar(tabs: visibleTabs, selection: $selectedTab)
/// }
/// ```
public struct RAVETabBar<Tab: RAVETabItem, Accessory: View>: View {
    private let tabs: [Tab]
    @Binding private var selection: Tab
    private let onSelect: ((Tab) -> Void)?
    private let accessory: () -> Accessory

    /// Sit below the window's bottom edge so a protruding foreground layer —
    /// a volumetric diorama, a front-plane video — doesn't visually clip the
    /// bar. Discovered independently by two of the three apps.
    private let bottomLift: CGFloat = 20

    public init(
        tabs: [Tab],
        selection: Binding<Tab>,
        onSelect: ((Tab) -> Void)? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.tabs = tabs
        self._selection = selection
        self.onSelect = onSelect
        self.accessory = accessory
    }

    public var body: some View {
        HStack(spacing: 8) {
            ForEach(tabs) { tab in
                RAVETabBarButton(
                    title: tab.title,
                    systemImage: tab.systemImage,
                    isSelected: selection == tab,
                    identifier: tab.accessibilityIdentifier,
                    action: {
                        // A hook, not a replacement: an app that wants to
                        // notice re-selection of the current tab (a "pop to
                        // root" gesture) needs to see the tap even when the
                        // selection does not change.
                        if let onSelect {
                            onSelect(tab)
                        } else {
                            selection = tab
                        }
                    }
                )
            }
            accessory()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassBackgroundEffect()
        .padding(.top, bottomLift)
    }
}

public extension RAVETabBar where Accessory == EmptyView {
    init(
        tabs: [Tab],
        selection: Binding<Tab>,
        onSelect: ((Tab) -> Void)? = nil
    ) {
        self.init(tabs: tabs, selection: selection, onSelect: onSelect) { EmptyView() }
    }
}

/// One tab button. Icon only until selected, then icon + label in a glass pill.
public struct RAVETabBarButton: View {
    public let title: String
    public let systemImage: String
    public let isSelected: Bool
    /// Nil derives one from the title. See `RAVEA11y`.
    public let identifier: String?
    public let action: () -> Void

    public init(
        title: String,
        systemImage: String,
        isSelected: Bool,
        identifier: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.identifier = identifier
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title3)
                if isSelected {
                    Text(title)
                        .font(.callout)
                        .fontWeight(.medium)
                        .transition(.opacity)
                }
            }
            .frame(minWidth: 44, minHeight: 32)
            .padding(.horizontal, isSelected ? 14 : 10)
            .padding(.vertical, 8)
            .contentShape(Capsule())
        }
        .buttonStyle(RAVETabBarButtonStyle(isSelected: isSelected))
        .hoverEffect(.highlight)
        .help(title)
        // The button is icon-only until selected, so without an explicit label
        // VoiceOver and XCUITest both see an SF Symbol name.
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier ?? RAVEA11y.tab(title))
        .animation(.smooth(duration: 0.22), value: isSelected)
    }
}

/// The tab button's selected/unselected treatment, exposed so app-specific
/// accessories in the same bar can match it exactly rather than approximate it.
public struct RAVETabBarButtonStyle: ButtonStyle {
    public let isSelected: Bool

    public init(isSelected: Bool) {
        self.isSelected = isSelected
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? .primary : .secondary)
            .background {
                if isSelected {
                    Capsule()
                        .fill(.thinMaterial)
                        .overlay(
                            Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                        )
                }
            }
    }
}

/// An icon button sized and styled to sit in the tab bar beside the tabs
/// without being one — Spatial Stash's slideshow launcher, and the shape any
/// future bar accessory should take.
public struct RAVETabBarActionButton: View {
    public let systemImage: String
    public let help: String
    /// Nil derives one from the symbol name — which, unlike `help`, is not
    /// display copy. See `RAVEA11y`.
    public let identifier: String?
    public let action: () -> Void

    public init(
        systemImage: String,
        help: String,
        identifier: String? = nil,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.help = help
        self.identifier = identifier
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(minWidth: 44, minHeight: 32)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Capsule())
        }
        .buttonStyle(RAVETabBarButtonStyle(isSelected: false))
        .hoverEffect(.highlight)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(identifier ?? RAVEA11y.tabAction(systemImage))
    }
}

/// A non-interactive chip matching the tab buttons' metrics — Longwave's
/// broadcast/view-sharing indicators.
public struct RAVETabBarIndicator: View {
    public let systemImage: String
    public let help: String
    public let tint: Color

    public init(systemImage: String, help: String, tint: Color = .red) {
        self.systemImage = systemImage
        self.help = help
        self.tint = tint
    }

    public var body: some View {
        Image(systemName: systemImage)
            .font(.title3)
            .foregroundStyle(tint)
            .frame(minWidth: 44, minHeight: 32)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .help(help)
            .transition(.opacity)
    }
}

/// The vertical rule the apps put between the tabs and their accessories.
public struct RAVETabBarDivider: View {
    public let height: CGFloat

    public init(height: CGFloat = 28) {
        self.height = height
    }

    public var body: some View {
        Divider()
            .frame(height: height)
            .padding(.horizontal, 4)
    }
}

#endif
