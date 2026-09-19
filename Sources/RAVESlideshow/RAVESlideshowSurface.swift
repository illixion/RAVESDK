/*
 RAVESlideshow - reusable SwiftUI render surfaces

 Apps keep window composition, ornaments, and media-specific renderers. These
 surfaces provide the common slot selection/crossfade scaffolding and pass
 neutral media values into app-supplied hooks.
 */

import SwiftUI

public struct RAVESlideshowRenderContext: Equatable, Sendable {
    public var media: RAVESlideshowDisplayedMedia
    public var role: Role
    public var displaySettings: RAVESlideshowDisplaySettings
    public var visualSettings: RAVESlideshowVisualSettings

    public enum Role: String, Equatable, Sendable {
        case current
        case incoming
    }

    public init(
        media: RAVESlideshowDisplayedMedia,
        role: Role,
        displaySettings: RAVESlideshowDisplaySettings,
        visualSettings: RAVESlideshowVisualSettings
    ) {
        self.media = media
        self.role = role
        self.displaySettings = displaySettings
        self.visualSettings = visualSettings
    }
}

public struct RAVESlideshowSurface<Still: View, Animated: View, Video: View, Placeholder: View>: View {
    private let engine: RAVESlideshowEngine
    private let still: (RAVESlideshowRenderContext) -> Still
    private let animated: (RAVESlideshowRenderContext) -> Animated
    private let video: (RAVESlideshowRenderContext) -> Video
    private let placeholder: () -> Placeholder

    @State private var windowSize: CGSize = .zero
    @State private var kenBurnsScale: CGFloat = 1.0
    @State private var kenBurnsOffset: CGSize = .zero

    public init(
        engine: RAVESlideshowEngine,
        @ViewBuilder still: @escaping (RAVESlideshowRenderContext) -> Still,
        @ViewBuilder animated: @escaping (RAVESlideshowRenderContext) -> Animated,
        @ViewBuilder video: @escaping (RAVESlideshowRenderContext) -> Video,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.engine = engine
        self.still = still
        self.animated = animated
        self.video = video
        self.placeholder = placeholder
    }

    public var body: some View {
        ZStack {
            if let current = engine.current {
                // Bottom layer stays at a constant opacity regardless of an
                // incoming crossfade — only the incoming layer above animates.
                // Coupling this layer's opacity to `incoming == nil` used to
                // make the engine's atomic current/incoming commit (see
                // `RAVESlideshowEngine.display()`) double as an animation
                // trigger: the content swap and a redundant fade-in landed in
                // the same transaction, producing a visible flash/glitch
                // right as the crossfade finished.
                render(current, role: .current)
                    .opacity(engine.visualSettings.opacity)
                    .scaleEffect(kenBurnsScale)
                    .offset(kenBurnsOffset)
            } else {
                placeholder()
            }

            // Scoped to a Group of its own so the crossfade's `.animation`
            // below can never reach the current layer's scaleEffect/offset —
            // it used to sit on the whole ZStack, and applying it to the Ken
            // Burns transform too meant the transform's near-maximum zoom for
            // the outgoing image got revealed on the *new* current content at
            // the moment of commit, as the incoming layer faded away above it.
            Group {
                if let incoming = engine.incoming {
                    render(incoming, role: .incoming)
                        .opacity(engine.visualSettings.opacity)
                        .transition(.opacity)
                }
            }
            .animation(
                .easeInOut(duration: engine.displaySettings.reduceMotion ? 0 : engine.displaySettings.transitionDuration),
                value: engine.incoming?.item.id
            )
        }
        .background(
            GeometryReader { geo in
                Color.clear.onAppear { windowSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in windowSize = newSize }
            }
        )
        .onChange(of: engine.current?.item.id) { _, _ in
            startKenBurnsAnimation()
        }
    }

    private func startKenBurnsAnimation() {
        resetKenBurns()
        guard engine.displaySettings.enableKenBurns, !engine.displaySettings.reduceMotion,
              case .still? = engine.current?.media else { return }

        let focus = engine.current?.focusPoint ?? CGPoint(x: 0.5, y: 0.5)
        let targetScale: CGFloat = 1.3
        let offsetX = (focus.x - 0.5) * windowSize.width * 0.15
        let offsetY = (focus.y - 0.5) * windowSize.height * 0.15

        withAnimation(.easeInOut(duration: engine.displaySettings.delay)) {
            kenBurnsScale = targetScale
            kenBurnsOffset = CGSize(width: -offsetX, height: -offsetY)
        }
    }

    private func resetKenBurns() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            kenBurnsScale = 1.0
            kenBurnsOffset = .zero
        }
    }

    @ViewBuilder
    private func render(_ media: RAVESlideshowDisplayedMedia, role: RAVESlideshowRenderContext.Role) -> some View {
        let context = RAVESlideshowRenderContext(
            media: media,
            role: role,
            displaySettings: engine.displaySettings,
            visualSettings: engine.visualSettings
        )
        switch media.media {
        case .still:
            still(context)
        case .animatedImage:
            animated(context)
        case .video:
            video(context)
        }
    }
}

public struct RAVESlideshowPlaceholderView: View {
    private let title: String
    private let systemImage: String

    public init(title: String = "No slideshow content", systemImage: String = "photo.stack") {
        self.title = title
        self.systemImage = systemImage
    }

    public var body: some View {
        ContentUnavailableView(title, systemImage: systemImage)
    }
}
