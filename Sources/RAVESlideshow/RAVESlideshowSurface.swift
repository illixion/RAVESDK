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
                render(current, role: .current)
                    .opacity(engine.incoming == nil ? engine.visualSettings.opacity : 0)
            } else {
                placeholder()
            }

            if let incoming = engine.incoming {
                render(incoming, role: .incoming)
                    .opacity(engine.visualSettings.opacity)
            }
        }
        .animation(
            .easeInOut(duration: engine.displaySettings.reduceMotion ? 0 : engine.displaySettings.transitionDuration),
            value: engine.incoming?.item.id
        )
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
