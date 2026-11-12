//
//  RAVESupportView.swift
//  RAVESupport
//
//  Two ways to show the card:
//
//      ContentView().raveSupportWelcome(RAVESupportConfig(appName: "Longwave", appID: "pro.longwave.ios"))
//          a one-time "Hi, I'm Ixion" sheet the first time the app appears, then a one-time
//          "Thank you for staying" nudge once 24 hours have passed since that first use (a thank-you
//          that says it is the last reminder); never again
//
//      RAVESupportCard(config)
//          the same card inline, for Settings or About, always available
//
//  Each is a single page with one sponsor button and a way out; nothing blocks the app.
//  tvOS has no browser to open, so there the card shows the address instead.
//
//  Layouts: on macOS and tvOS the sheets put the picture on the left at a larger size, since
//  those screens are wide, and the macOS sheet is a Liquid Glass panel (macOS 26). On iOS the
//  sheet's buttons are full width at the bottom, within reach of a thumb. The inline card keeps
//  the stacked layout everywhere, as Settings panes are narrow.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

public struct RAVESupportCard: View {
    /// Which copy and artwork the card uses.
    public enum Kind: Sendable { case welcome, nudge, inline }

    private let config: RAVESupportConfig
    private let kind: Kind
    private let onDismiss: (() -> Void)?
    @Environment(\.openURL) private var openURL

    /// `onDismiss` adds the way-out button used by the sheets; the inline card leaves it nil.
    public init(_ config: RAVESupportConfig, kind: Kind = .inline, onDismiss: (() -> Void)? = nil) {
        self.config = config
        self.kind = kind
        self.onDismiss = onDismiss
    }

    private var pose: RAVESupportPose {
        switch kind { case .welcome: .welcome; case .nudge: .nudge; case .inline: .card }
    }
    private var title: String { kind == .nudge ? config.nudgeTitle : config.title }
    private var message: String { kind == .nudge ? config.nudgeMessage : config.message }
    private var dismissLabel: String { kind == .nudge ? "Close" : "Maybe later" }
    private var isSheet: Bool { kind != .inline }

    public var body: some View {
        #if os(macOS) || os(tvOS)
        if isSheet { wide } else { stacked }
        #else
        stacked
        #endif
    }

    // MARK: Stacked: iOS, visionOS, and every inline card

    private var stacked: some View {
        VStack(spacing: 16) {
            #if os(iOS)
            if isSheet { Spacer(minLength: 0) }
            #endif
            RAVESupportArtwork(pose: pose)
                .accessibilityHidden(true)
            Text(title).font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(message).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            #if os(iOS)
            if isSheet {
                Spacer(minLength: 24)
                reachableActions
            } else {
                compactActions
            }
            #else
            compactActions
            #endif
        }
        .padding(24)
        #if os(iOS)
        .frame(maxWidth: isSheet ? 560 : nil, maxHeight: isSheet ? .infinity : nil)
        #endif
    }

    /// Centred, content-sized buttons: visionOS, the inline card, and the stacked macOS/tvOS card.
    @ViewBuilder private var compactActions: some View {
        sponsorAction
            .buttonStyle(.borderedProminent)
        if let onDismiss {
            Button(dismissLabel, action: onDismiss)
        }
    }

    #if os(iOS)
    /// Stock iOS sheet actions: a full-width, tall primary button at the bottom, and the way out
    /// under it, also full width so the whole row is a target.
    private var reachableActions: some View {
        VStack(spacing: 8) {
            Button {
                openURL(config.sponsorURL)
                onDismiss?()
            } label: {
                Label("Sponsor on GitHub", systemImage: "heart.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if let onDismiss {
                Button(action: onDismiss) {
                    Text(dismissLabel)
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .controlSize(.large)
            }
        }
    }
    #endif

    // MARK: Wide: the macOS and tvOS sheets

    #if os(macOS) || os(tvOS)
    #if os(macOS)
    // About 840 pt wide with the welcome art: room on a 16:9 screen, and no wider than a modest
    // app window, which a sheet should not overhang.
    private let artHeight: CGFloat = 280
    private let textWidth: CGFloat = 360
    private let spacing: CGFloat = 28
    #else
    private let artHeight: CGFloat = 560
    private let textWidth: CGFloat = 820
    private let spacing: CGFloat = 64
    #endif

    private var wide: some View {
        HStack(alignment: .center, spacing: spacing) {
            RAVESupportArtwork(pose: pose, maxHeight: artHeight, fixedSize: true)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.title.bold())
                Text(message)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                wideActions
                    .padding(.top, 10)
            }
            .frame(width: textWidth, alignment: .leading)
        }
        .padding(spacing)
    }

    @ViewBuilder private var wideActions: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 20) {
            sponsorAction
            if let onDismiss { Button(dismissLabel, action: onDismiss) }
        }
        #else
        HStack(spacing: 12) {
            sponsorAction
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            if let onDismiss {
                Button(dismissLabel, action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .controlSize(.large)
        #endif
    }
    #endif

    // MARK: Shared

    /// The sponsor button, or on tvOS (no browser) the address to visit.
    @ViewBuilder private var sponsorAction: some View {
        #if os(tvOS)
        Text(config.sponsorURL.absoluteString).font(.callout).foregroundStyle(.secondary)
        #else
        Button {
            openURL(config.sponsorURL)
            onDismiss?()
        } label: {
            Label("Sponsor on GitHub", systemImage: "heart.fill")
        }
        #endif
    }
}

public extension View {
    /// Shows the welcome card the first time this view appears in the app's life, and the nudge the
    /// first time it appears (or the app becomes active) 24 hours or more after that. Put it on the
    /// root view; each card records that it ran as soon as it shows, so neither repeats.
    func raveSupportWelcome(_ config: RAVESupportConfig) -> some View {
        modifier(RAVESupportWelcome(config: config))
    }
}

struct RAVESupportWelcome: ViewModifier {
    let config: RAVESupportConfig
    @State private var showing: RAVESupportCard.Kind?
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task { evaluate() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { evaluate() } }
            .sheet(item: $showing) { kind in
                RAVESupportCard(config, kind: kind) { showing = nil }
                    #if os(macOS)
                    .modifier(RAVESupportGlassPanel())
                    #endif
            }
    }

    @MainActor private func evaluate() {
        guard showing == nil else { return }
        let store = RAVESupportStore(appID: config.appID)
        if !store.welcomeShown {
            store.markWelcomeShown()
            showing = .welcome
        } else if store.nudgeDue() {
            store.markNudgeShown()
            showing = .nudge
        }
    }
}

#if os(macOS)
/// The sheet as a Liquid Glass panel (macOS 26), refracting the window behind it. Before macOS 26
/// the system's sheet stays as it is.
///
/// `presentationBackground(.clear)` alone leaves a macOS sheet opaque: the sheet's `NSWindow`
/// still fills itself with its background colour, so the glass has nothing to refract. The window
/// is made non-opaque with a clear background, the same step an Electron app takes before adding
/// an `NSGlassEffectView` under its content (vscode-vibrancy-continued's liquid-glass type).
struct RAVESupportGlassPanel: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: 26))
                .presentationBackground(.clear)
                .background(ClearWindow())
        } else {
            content
        }
    }

    private struct ClearWindow: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { Probe() }
        func updateNSView(_ nsView: NSView, context: Context) {}

        final class Probe: NSView {
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                guard let window else { return }
                window.isOpaque = false
                window.backgroundColor = .clear
                // AppKit backs a sheet with its own `.sheet`-material effect view, a sibling of the
                // hosting view in the window's frame view. Left showing, it is a near-opaque panel
                // under the glass; hidden, the glass is the sheet's only background.
                DispatchQueue.main.async { [weak window] in
                    for view in window?.contentView?.superview?.subviews ?? [] {
                        if let effect = view as? NSVisualEffectView, effect.material == .sheet { effect.isHidden = true }
                    }
                }
            }
        }
    }
}
#endif

extension RAVESupportCard.Kind: Identifiable {
    public var id: Self { self }
}
