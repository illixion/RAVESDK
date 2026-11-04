/*
 RAVE SDK — system overlays for windows that host window pushes.

 Cross-platform on purpose: the views that use it also build for iOS, macOS
 and tvOS, where it is the plain `persistentSystemOverlays`. Only the push
 host (visionOS, `RAVEWindowPush.swift`) reads what it reports.
 */

import SwiftUI

/// What a window inside a push host wants for its system overlays (the
/// grabber, close button and window bar).
struct RAVESystemOverlaysKey: PreferenceKey {
    static let defaultValue: Visibility? = nil
    static func reduce(value: inout Visibility?, nextValue: () -> Visibility?) {
        value = nextValue() ?? value
    }
}

public extension View {
    /// `persistentSystemOverlays` for a window that hosts window pushes
    /// (`raveWindowPushHost`). Use this instead of the plain modifier there.
    ///
    /// The push host sits outside the window's own views and has to decide
    /// the final overlay value itself: it hides them while the window is
    /// pushed away, and re-asserts a hidden state after a resize (visionOS
    /// resets the overlays to visible on every resize and nothing else puts
    /// them back). A plain `persistentSystemOverlays` inside it is not seen by
    /// the host, so it can be overridden by the host's own value. This also
    /// applies the value directly, so the window behaves the same without a
    /// host.
    func raveSystemOverlays(_ visibility: Visibility) -> some View {
        persistentSystemOverlays(visibility)
            .preference(key: RAVESystemOverlaysKey.self, value: visibility)
    }
}
