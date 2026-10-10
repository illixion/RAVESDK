/*
 RAVE SDK — focus a text field from the padding around it.

 Every app here puts TextFields in Form rows, and on visionOS the row is much
 taller than the field that takes input. Hypnos, Longwave, Raven, Spatial
 Home, xrTimer and the RoboFrame client all had the same dead padding.
 */

import SwiftUI

extension View {
    /// Makes the space around a text field focus it when tapped.
    ///
    /// A `TextField`/`SecureField` is only as tall as its text, while the Form
    /// row or bordered shell drawn around it is much taller. That padding takes
    /// no input, so on visionOS a pinch while looking slightly above or below
    /// the text (a miscalibrated gaze, or simply a small target) does nothing.
    /// This puts a tap target behind the field that reaches `outset` points
    /// past its top and bottom edges and focuses the field. Taps on the field
    /// itself still land on the field (it is in front), so cursor placement is
    /// unaffected. On visionOS the target also highlights under gaze, so the
    /// user can see the shell is aimable.
    ///
    /// No-op on tvOS (focus engine, no taps) and macOS (a precise pointer).
    public func textFieldTapTarget(outset: CGFloat = 10) -> some View {
        modifier(OwnFocusTapTarget(outset: outset))
    }

    /// The same, for a field that already has a `.focused(_:)` binding of its
    /// own: the target sets that binding instead of adding a second one. Apply
    /// it after the caller's `.focused`.
    public func textFieldTapTarget(focus: FocusState<Bool>.Binding, outset: CGFloat = 10) -> some View {
        modifier(TextFieldTapTarget(outset: outset) { focus.wrappedValue = true })
    }
}

private struct OwnFocusTapTarget: ViewModifier {
    let outset: CGFloat
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        #if os(visionOS) || os(iOS)
        content
            .focused($isFocused)
            .modifier(TextFieldTapTarget(outset: outset) { isFocused = true })
        #else
        content
        #endif
    }
}

private struct TextFieldTapTarget: ViewModifier {
    let outset: CGFloat
    let focus: () -> Void

    func body(content: Content) -> some View {
        #if os(visionOS) || os(iOS)
        content
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    #if os(visionOS)
                    .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 10))
                    .hoverEffect(.highlight)
                    #endif
                    .onTapGesture(perform: focus)
                    // Negative padding grows the target past the field's own
                    // frame, into the row padding, without changing layout.
                    .padding(.vertical, -outset)
            }
        #else
        content
        #endif
    }
}
