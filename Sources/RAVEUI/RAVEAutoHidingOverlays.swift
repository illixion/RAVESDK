/*
 RAVE SDK — auto-reasserting `persistentSystemOverlays`.

 A plain visionOS window snapped flat to a wall (Spatial Home's light cube,
 wall-mounted media) hides its window controls by conditioning
 `persistentSystemOverlays` on some state (e.g. "is this snapped to a wall").
 That works until the user resizes the window: visionOS silently resets the
 overlay to visible on every resize, regardless of what the modifier's value
 currently says. Because the condition itself hasn't changed, SwiftUI never
 re-issues the call on its own, so the controls come back and stay up for
 good — the window looks broken rather than transiently interacted with.

 This modifier watches the window's geometry and, whenever it changes while
 hiding is wanted, flips the *applied* value off and back on after a short
 settle delay. The flip — not the settle — is what forces SwiftUI to reapply
 `persistentSystemOverlays`, since re-setting an unchanged value is a no-op.
 */

#if os(visionOS)

import SwiftUI

private struct RAVEAutoHidingOverlaysModifier: ViewModifier {
    /// Whether the overlays should be hidden right now (e.g. "snapped to a
    /// wall"). Tracks the caller's own condition; `appliedHidden` is what's
    /// actually fed to `persistentSystemOverlays` and can lag behind this
    /// briefly across a resize.
    let isHidden: Bool
    var resettleDelay: Duration

    @State private var appliedHidden = false
    @State private var resettleTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .persistentSystemOverlays(appliedHidden ? .hidden : .automatic)
            .onChange(of: isHidden, initial: true) { _, wantsHidden in
                apply(wantsHidden)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
                guard isHidden else { return }
                // Force a genuine value transition now (the OS just reset the
                // real overlay state to visible), then reassert once the
                // resize has settled rather than on every intermediate frame.
                resettleTask?.cancel()
                appliedHidden = false
                resettleTask = Task { @MainActor in
                    try? await Task.sleep(for: resettleDelay)
                    guard !Task.isCancelled else { return }
                    apply(isHidden)
                }
            }
    }

    private func apply(_ hidden: Bool) {
        resettleTask?.cancel()
        resettleTask = nil
        appliedHidden = hidden
    }
}

public extension View {
    /// Keeps `persistentSystemOverlays` hidden while `condition` holds,
    /// automatically re-hiding them after a user resize settles.
    ///
    /// Use this instead of `.persistentSystemOverlays(condition ? .hidden :
    /// .automatic)` directly on any window whose overlay-hidden state is tied
    /// to a fixed condition (surface snapping, a "chromeless" mode, …) — the
    /// plain form only survives until the first resize.
    func autoHidingSystemOverlays(
        when condition: Bool,
        resettleDelay: Duration = .seconds(0.6)
    ) -> some View {
        modifier(RAVEAutoHidingOverlaysModifier(isHidden: condition, resettleDelay: resettleDelay))
    }
}

#endif
