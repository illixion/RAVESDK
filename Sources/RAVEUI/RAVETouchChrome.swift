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

// A `ButtonStyle` cannot delegate to a system style: `makeBody` hands back a
// view built from `configuration.label`, and there is no way to say "and then
// render that the way `.borderless` would". So on visionOS there is no custom
// style at all — the platform's own `.borderless` draws the gaze hover
// highlight and the padding that makes an ornament button look like one, and
// re-deriving those by hand would mean guessing at hover shape, glyph inset
// and pressed state, and drifting from them at the next OS release.
//
// `RAVEChromeButtonStyle` therefore does not exist on visionOS, which makes
// the mistake structural rather than visual: `.buttonStyle(.raveChrome)` in
// shared code fails to build for the headset instead of quietly shipping
// flat, hover-less chrome. Use `View.raveChromeButtonStyle()` — it resolves
// to the right thing on each platform.
#if !os(visionOS)

/// Borderless glyph button with a finger-sized hit target: an Apple-HIG
/// 44-point minimum touchable area, and a press/disabled dimming to replace
/// the feedback the system style would have given.
///
/// Prefer `View.raveChromeButtonStyle()` over naming this directly; it is the
/// spelling that also compiles on visionOS.
///
/// `contentShape` is what makes the transparent margin around the glyph count
/// as part of the button; without it the enlarged frame is inert.
public struct RAVEChromeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
            .opacity(isEnabled ? (configuration.isPressed ? 0.4 : 1) : 0.35)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == RAVEChromeButtonStyle {
    /// A glyph button in floating chrome on a touch platform.
    static var raveChrome: RAVEChromeButtonStyle { RAVEChromeButtonStyle() }
}

#endif

public extension View {
    /// Styles the glyph buttons in this subtree as floating chrome: the
    /// system `.borderless` style on visionOS, where gaze targeting and the
    /// platform's own hover highlight already make a bare glyph comfortable,
    /// and `RAVEChromeButtonStyle`'s 44-point touch target elsewhere.
    ///
    /// Use this instead of `.buttonStyle(.borderless)` for any control that
    /// has to be hittable by a finger as well as by gaze.
    func raveChromeButtonStyle() -> some View {
        #if os(visionOS)
        buttonStyle(.borderless)
        #else
        buttonStyle(RAVEChromeButtonStyle())
        #endif
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
