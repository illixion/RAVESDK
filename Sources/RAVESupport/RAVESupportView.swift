//
//  RAVESupportView.swift
//  RAVESupport
//
//  Two ways to show the card:
//
//      ContentView().raveSupportWelcome(RAVESupportConfig(appName: "Longwave", appID: "pro.longwave.ios"))
//          a one-time "Hi, I'm Ixion" sheet the first time the app appears, then a one-time
//          "Enjoying this app?" nudge once 24 hours have passed since that first use; never again
//
//      RAVESupportCard(config)
//          the same card inline, for Settings or About, always available
//
//  Each is a single page with one sponsor button and a way out; nothing blocks the app.
//  tvOS has no browser to open, so there the card shows the address instead.
//

import SwiftUI

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
    private var dismissLabel: String { kind == .nudge ? "Not now" : "Maybe later" }

    public var body: some View {
        VStack(spacing: 16) {
            if let image = pose.image {
                image.resizable().scaledToFit().frame(maxHeight: 220)
                    .accessibilityHidden(true)
            }
            Text(title).font(.title2.bold())
            Text(message).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            #if os(tvOS)
            Text(config.sponsorURL.absoluteString).font(.callout).foregroundStyle(.secondary)
            #else
            Button {
                openURL(config.sponsorURL)
                onDismiss?()
            } label: {
                Label("Sponsor on GitHub", systemImage: "heart.fill")
            }
            .buttonStyle(.borderedProminent)
            #endif
            if let onDismiss {
                Button(dismissLabel, action: onDismiss)
            }
        }
        .padding(24)
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
                    .frame(minWidth: 380)
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

extension RAVESupportCard.Kind: Identifiable {
    public var id: Self { self }
}
