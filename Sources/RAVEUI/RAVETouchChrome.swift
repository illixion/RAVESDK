/*
 RAVE SDK — touch chrome.

 The floating bar of glyph buttons that every one of these apps puts over its
 content: Spatial Stash's photo/video/viewer ornaments, Longwave's stream
 controls. On visionOS it is an ornament and gaze targeting makes a bare 24pt
 glyph perfectly hittable. On a phone the same glyph is a missed tap, so the
 touch target has to be grown to Apple's 44pt minimum *without* growing the
 glyph — which is what `RAVEChromeButtonStyle` does, and why it exists rather
 than each app padding its own buttons by eye.

 `RAVEChromeBar` is the capsule those buttons sit in for apps that do not
 already have their own bar background.
 */

import SwiftUI

// A `ButtonStyle` cannot delegate to a system style, so the visionOS spelling
// below re-creates what `.borderless` gave an ornament button: no background
// and a gaze hover highlight. What it deliberately does *not* copy is
// `.borderless`'s hit shape, which hugs the glyph: gaze lands on the hover
// highlight at the button's edge, but the pinch only counts inside the bare
// 24pt icon, so the edge of a button that looks hovered does nothing. Here
// the label is grown to a 60pt target (the same as `ravePlayerControlLabel`)
// and that one shape serves for hit-testing and the hover highlight, so
// what lights up is what a pinch presses.

/// Borderless glyph button with a generous hit target: Apple's 60-point
/// visionOS minimum under gaze, 44 points under a finger, plus a press/disabled
/// dimming. The transparent margin around the glyph counts as the button.
///
/// Prefer `View.raveChromeButtonStyle()` over naming this directly.
///
/// `contentShape` is what makes the transparent margin around the glyph count
/// as part of the button; without it the enlarged frame is inert.
public struct RAVEChromeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        #if os(visionOS)
        configuration.label
            .frame(minWidth: 60, minHeight: 60)
            .contentShape(.interaction, .capsule)
            .contentShape(.hoverEffect, .capsule)
            .hoverEffect(.highlight)
            .opacity(isEnabled ? (configuration.isPressed ? 0.5 : 1) : 0.35)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        #else
        configuration.label
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
            .opacity(isEnabled ? (configuration.isPressed ? 0.4 : 1) : 0.35)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        #endif
    }
}

public extension ButtonStyle where Self == RAVEChromeButtonStyle {
    /// A glyph button in floating chrome.
    static var raveChrome: RAVEChromeButtonStyle { RAVEChromeButtonStyle() }
}

public extension View {
    /// Styles the glyph buttons in this subtree as floating chrome, with a
    /// target far larger than the glyph (60pt on visionOS, 44pt elsewhere).
    ///
    /// Use this instead of `.buttonStyle(.borderless)`, whose hit area on
    /// visionOS is only the glyph itself.
    func raveChromeButtonStyle() -> some View {
        buttonStyle(RAVEChromeButtonStyle())
    }
}

// The capsule is a touch-platform thing: `glassEffect` is unavailable on
// visionOS (which has `glassBackgroundEffect` and real ornaments), and the
// package's macOS floor is 14 — it exists so `swift test` has a host platform
// — which predates Liquid Glass entirely.
#if !os(macOS) && !os(visionOS)

/// A capsule of chrome buttons, for content that does not bring its own
/// background.
///
/// The capsule deliberately swallows taps that land between its buttons: it
/// floats over interactive content, where a near miss would otherwise act on
/// whatever is underneath.
public struct RAVEChromeBar<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: RAVEChromeMetrics.spacing) {
            content
        }
        .raveChromeButtonStyle()
        .font(.title3)
        .padding(.horizontal, RAVEChromeMetrics.horizontalPadding)
        .padding(.vertical, RAVEChromeMetrics.verticalPadding)
        .glassEffect(in: .capsule)
        .contentShape(.capsule)
        // Deliberately empty: claims the tap so it never reaches the content
        // below. Buttons inside still win over this gesture.
        .onTapGesture {}
    }
}

#endif

/// The spacing a floating chrome bar puts around and between its buttons.
///
/// Two sets of numbers, because the two input models want opposite things. On
/// visionOS the buttons are small and generously spaced, so gaze can separate
/// them. On a phone `RAVEChromeButtonStyle` has already grown each button to
/// 44 points, so the same generous spacing pushes the bar past the width of
/// the screen — the padding has to come out of the gaps instead.
public enum RAVEChromeMetrics {
    #if os(visionOS)
    public static let spacing: CGFloat = 16
    public static let horizontalPadding: CGFloat = 20
    public static let verticalPadding: CGFloat = 12
    #else
    public static let spacing: CGFloat = 2
    public static let horizontalPadding: CGFloat = 10
    public static let verticalPadding: CGFloat = 4
    #endif
}
