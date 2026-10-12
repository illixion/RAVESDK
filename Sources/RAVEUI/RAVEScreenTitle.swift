import SwiftUI

// A screen's title that scrolls with its content on tvOS.
//
// tvOS 26 keeps a navigation bar's large title where it is while the content scrolls under
// it, so the title ends up drawn over the cells (Hypnos's grids, Apparition's setup cards).
// On tvOS the bar gets no title instead (it keeps any toolbar buttons) and the title is a
// heading at the top of the scrolling content, which scrolls away with it. Everywhere else
// this is plain `navigationTitle`.
//
// Two halves, because a modifier can't reach inside a ScrollView, Form or List:
//
//     ScrollView {
//         VStack {
//             RAVEScreenHeading("Setup")
//             cards
//         }
//     }
//     .raveScreenTitle("Setup")
//
// In a Form or List, put the heading in as the first row (it draws no row background).

public extension View {
    /// `navigationTitle`, except on tvOS, where `RAVEScreenHeading` draws the title in the
    /// content instead and the bar is left without one. The bar itself stays, because hiding
    /// it would hide the screen's toolbar buttons too.
    @ViewBuilder
    func raveScreenTitle(_ title: String) -> some View {
        #if os(tvOS)
        self
        #else
        navigationTitle(title)
        #endif
    }
}

/// The title as the first thing in a screen's scrolling content, on tvOS only (elsewhere the
/// navigation bar shows it, and this draws nothing). Pair with `raveScreenTitle(_:)`.
public struct RAVEScreenHeading: View {
    private let title: String
    private let takesFocus: Bool

    /// `takesFocus`: whether the heading can be focused on tvOS. A Form or List needs it, or
    /// moving up from its first control gets stuck below the heading. A ScrollView of cards
    /// reaches the tab bar without it, and there it would only cost an extra click each way.
    public init(_ title: String, takesFocus: Bool = true) {
        self.title = title
        self.takesFocus = takesFocus
    }

    public var body: some View {
        #if os(tvOS)
        Text(title)
            .font(.title2.weight(.bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .listRowBackground(Color.clear)
            // Focusable so that moving up from the first control scrolls back to the top
            // (tvOS scrolls only to what takes focus); from here, up reaches the tab bar.
            // Without it, a Form whose first control sits below the heading got stuck there.
            .focusable(takesFocus)
            .accessibilityAddTraits(.isHeader)
        #else
        EmptyView()
        #endif
    }
}
