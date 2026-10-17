/*
 RAVE SDK — the Home ornament on pop-out windows.

 visionOS brings back whichever windows were open when the app was last used,
 and an icon tap summons the nearest one. So a pop-out (a stream, a console, a
 call) can come back alone, with no route to the main window: close it and the
 app is gone, keep it and there is nothing else to reach. Every pop-out
 therefore carries a Home button in an ornament under it. Longwave
 (`HomeOrnament`) and Spatial Home (its console and system windows) each grew
 a copy; spatial-ai-character was the third.

 The ornament is shared, what Home does is not. Longwave opens a value-keyed
 main window, Spatial Home goes through its app model, and an app whose main
 window may still be open elsewhere has to dismiss and reopen it rather than
 call `openWindow` on the live scene (see `RAVEWindowRegistry.summon` for why).
 So the app passes the action, and may add its own buttons after Home.
 */

// Ornaments and `glassBackgroundEffect` are visionOS-only.
#if os(visionOS)

import SwiftUI

private struct RAVEHomeOrnament<Accessory: View>: ViewModifier {
    let title: String
    let systemImage: String
    let action: @MainActor () -> Void
    let accessory: Accessory

    func body(content: Content) -> some View {
        content.ornament(attachmentAnchor: .scene(.bottomFront)) {
            HStack(spacing: 12) {
                Button(action: action) {
                    Label(title, systemImage: systemImage)
                        .labelStyle(.iconOnly)
                }
                .help(title)
                .accessibilityIdentifier("rave.home")
                accessory
            }
            .padding(8)
            .glassBackgroundEffect()
        }
    }
}

public extension View {
    /// A bar under the window with a Home button, then `accessory`. Apply to
    /// the root view of every window that isn't the main one.
    func raveHomeOrnament<Accessory: View>(
        _ title: String = "Home", systemImage: String = "house",
        action: @escaping @MainActor () -> Void,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        modifier(RAVEHomeOrnament(title: title, systemImage: systemImage, action: action, accessory: accessory()))
    }

    /// A bar under the window with just a Home button.
    func raveHomeOrnament(
        _ title: String = "Home", systemImage: String = "house",
        action: @escaping @MainActor () -> Void
    ) -> some View {
        raveHomeOrnament(title, systemImage: systemImage, action: action) { EmptyView() }
    }
}

#endif
