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
    @State private var kenBurnsItemID: String?
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
            if engine.current == nil, engine.incoming == nil {
                placeholder()
            }

            // One layer per item, keyed by its id, so an item keeps the same
            // view from the moment it starts fading in until it is replaced.
            // Staging an incoming item inserts its layer (fading in) and fades
            // the outgoing one out at the same time; the engine's commit then
            // only removes a layer that is already invisible. Nothing swaps
            // content inside a visible layer, so the commit can't flash, pop
            // or reveal the outgoing image around a differently shaped
            // incoming one.
            ForEach(layers, id: \.media.item.id) { layer in
                let kenBurns = layer.media.item.id == kenBurnsItemID
                render(layer.media, role: layer.role)
                    .opacity(layer.isOutgoing ? 0 : engine.visualSettings.opacity)
                    // Ken Burns follows the item it was started for, not the
                    // `current` role: at the commit the new current item must
                    // not inherit the outgoing item's near-maximum zoom before
                    // `startKenBurnsAnimation` resets it.
                    .scaleEffect(kenBurns ? kenBurnsScale : 1)
                    .offset(kenBurns ? kenBurnsOffset : .zero)
                    .transition(.opacity)
            }
        }
        // On the ZStack itself, which inserts and removes the layers: an
        // animation applied inside a conditional layer (a Group around it
        // distributes the modifier onto its child) never reaches the
        // insertion, and the incoming image cuts in instead of fading.
        // Ken Burns state never changes in the same transaction as `incoming`
        // (it is reset with animations disabled, from `onChange` of
        // `current`), so this animation doesn't touch the zoom.
        .animation(
            .easeInOut(duration: engine.displaySettings.reduceMotion ? 0 : engine.displaySettings.transitionDuration),
            value: engine.incoming?.item.id
        )
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

    private struct Layer {
        var media: RAVESlideshowDisplayedMedia
        var role: RAVESlideshowRenderContext.Role
        var isOutgoing: Bool
    }

    /// Bottom to top: the current item, then the incoming one fading in over
    /// it. An incoming item with the current item's id (the same post shown
    /// again) is one layer, since the ids key the layers.
    private var layers: [Layer] {
        switch (engine.current, engine.incoming) {
        case let (current?, incoming?) where current.item.id == incoming.item.id:
            return [Layer(media: incoming, role: .current, isOutgoing: false)]
        case let (current?, incoming?):
            return [
                Layer(media: current, role: .current, isOutgoing: true),
                Layer(media: incoming, role: .incoming, isOutgoing: false),
            ]
        case let (current?, nil):
            return [Layer(media: current, role: .current, isOutgoing: false)]
        case let (nil, incoming?):
            return [Layer(media: incoming, role: .incoming, isOutgoing: false)]
        case (nil, nil):
            return []
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
            kenBurnsItemID = engine.current?.item.id
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
