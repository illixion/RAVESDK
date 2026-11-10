//
//  RAVESupportView.swift
//  RAVESupport
//
//  Two ways to show the card:
//
//      ContentView().raveSupportWelcome(RAVESupportConfig(appName: "Longwave", appID: "pro.longwave.ios"))
//          one-time sheet the first time the app appears, never again afterwards
//
//      RAVESupportCard(config)
//          the same card inline, for Settings or About, always available
//
//  Both are a single sponsor button plus a way out; nothing blocks the app.
//  tvOS has no browser to open, so there the card shows the address instead.
//

import SwiftUI

public struct RAVESupportCard: View {
    private let config: RAVESupportConfig
    private let pose: RAVESupportPose
    private let onDismiss: (() -> Void)?
    @Environment(\.openURL) private var openURL

    /// `onDismiss` adds a "Maybe later" button (the welcome sheet's); the inline card leaves it nil.
    public init(_ config: RAVESupportConfig, pose: RAVESupportPose = .card, onDismiss: (() -> Void)? = nil) {
        self.config = config
        self.pose = pose
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 16) {
            if let image = pose.image {
                image.resizable().scaledToFit().frame(maxHeight: 220)
                    .accessibilityHidden(true)
            }
            Text(config.title).font(.title2.bold())
            Text(config.message).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            #if os(tvOS)
            Text(config.sponsorURL.absoluteString).font(.callout).foregroundStyle(.secondary)
            #else
            Button {
                openURL(config.sponsorURL)
            } label: {
                Label("Sponsor on GitHub", systemImage: "heart.fill")
            }
            .buttonStyle(.borderedProminent)
            #endif
            if let onDismiss {
                Button("Maybe later", action: onDismiss)
            }
        }
        .padding(24)
    }
}

public extension View {
    /// Shows the welcome card as a sheet the first time this view appears in the app's life.
    /// Put it on the root view; it records that it ran as soon as it shows.
    func raveSupportWelcome(_ config: RAVESupportConfig) -> some View {
        modifier(RAVESupportWelcome(config: config))
    }
}

struct RAVESupportWelcome: ViewModifier {
    let config: RAVESupportConfig
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            .task {
                let store = RAVESupportStore(appID: config.appID)
                guard !store.welcomeShown else { return }
                store.markWelcomeShown()
                showing = true
            }
            .sheet(isPresented: $showing) {
                RAVESupportCard(config, pose: .welcome) { showing = false }
                    #if os(macOS)
                    .frame(minWidth: 380)
                    #endif
            }
    }
}
