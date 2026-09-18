/*
 RAVESlideshow - shared model and provider contracts

 These types deliberately describe slideshow content without naming a source
 product. Hypnos, RoboFrame, local files, and future clients adapt into the
 same item/provider shape while retaining ownership of API payloads, filters,
 authentication, and persistence.
 */

import CoreGraphics
import Foundation

public struct RAVESlideshowColorAdjustments: Codable, Hashable, Sendable {
    public var brightness: Double
    public var contrast: Double
    public var saturation: Double

    public init(brightness: Double = 0, contrast: Double = 1, saturation: Double = 1) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
    }

    public static let neutral = RAVESlideshowColorAdjustments()
}

public enum RAVESlideshowMediaKind: String, Codable, Hashable, Sendable {
    case image
    case animatedImage
    case video
}

public struct RAVESlideshowItem: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String?
    public var mediaKind: RAVESlideshowMediaKind
    public var fileExtension: String
    public var duration: TimeInterval?
    public var tags: Set<String>
    public var metadata: [String: String]

    public init(
        id: String,
        title: String? = nil,
        mediaKind: RAVESlideshowMediaKind = .image,
        fileExtension: String = "",
        duration: TimeInterval? = nil,
        tags: Set<String> = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.mediaKind = mediaKind
        self.fileExtension = fileExtension
        self.duration = duration
        self.tags = tags
        self.metadata = metadata
    }
}

public struct RAVESlideshowFetchRequest: Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable {
        case initial
        case prefetch
        case navigation
        case refresh
    }

    public var reason: Reason
    public var preferredAspectRatio: Double?
    public var aspectRatioTolerance: Double
    public var excludedItemIDs: Set<String>
    public var excludedTags: Set<String>
    public var minimumBatchSize: Int

    public init(
        reason: Reason,
        preferredAspectRatio: Double? = nil,
        aspectRatioTolerance: Double = 0.15,
        excludedItemIDs: Set<String> = [],
        excludedTags: Set<String> = [],
        minimumBatchSize: Int = 5
    ) {
        self.reason = reason
        self.preferredAspectRatio = preferredAspectRatio
        self.aspectRatioTolerance = aspectRatioTolerance
        self.excludedItemIDs = excludedItemIDs
        self.excludedTags = excludedTags
        self.minimumBatchSize = minimumBatchSize
    }
}

public enum RAVESlideshowLoadedMedia: Equatable, Sendable {
    case still(data: Data, displayURL: URL?)
    case animatedImage(data: Data?, displayURL: URL)
    case video(url: URL, hlsURL: URL?)

    public var displayURL: URL? {
        switch self {
        case .still(_, let displayURL): displayURL
        case .animatedImage(_, let displayURL): displayURL
        case .video(let url, _): url
        }
    }

    public var durationOverride: TimeInterval? {
        switch self {
        case .still, .animatedImage: nil
        case .video: nil
        }
    }
}

public struct RAVESlideshowDisplayedMedia: Equatable, Sendable {
    public var item: RAVESlideshowItem
    public var media: RAVESlideshowLoadedMedia
    public var displayedAt: Date
    public var focusPoint: CGPoint
    public var automaticColorAdjustment: RAVESlideshowColorAdjustments

    public init(
        item: RAVESlideshowItem,
        media: RAVESlideshowLoadedMedia,
        displayedAt: Date = Date(),
        focusPoint: CGPoint = CGPoint(x: 0.5, y: 0.5),
        automaticColorAdjustment: RAVESlideshowColorAdjustments = .neutral
    ) {
        self.item = item
        self.media = media
        self.displayedAt = displayedAt
        self.focusPoint = focusPoint
        self.automaticColorAdjustment = automaticColorAdjustment
    }
}

public struct RAVESlideshowPrefetchedMedia: Equatable, Sendable {
    public var item: RAVESlideshowItem
    public var media: RAVESlideshowLoadedMedia

    public init(item: RAVESlideshowItem, media: RAVESlideshowLoadedMedia) {
        self.item = item
        self.media = media
    }
}

@MainActor
public protocol RAVESlideshowContentProvider: AnyObject {
    func fetchMoreContent(_ request: RAVESlideshowFetchRequest) async throws -> [RAVESlideshowItem]
    func loadMedia(for item: RAVESlideshowItem, maxResolution: Int) async throws -> RAVESlideshowLoadedMedia
    func displayURL(for item: RAVESlideshowItem) -> URL?
    func streamingFallbackURL(for item: RAVESlideshowItem) -> URL?
    func didDisplay(_ item: RAVESlideshowItem) async
    func resetPagination()
}

public extension RAVESlideshowContentProvider {
    func displayURL(for item: RAVESlideshowItem) -> URL? { item.metadata["url"].flatMap(URL.init(string:)) }
    func streamingFallbackURL(for item: RAVESlideshowItem) -> URL? { nil }
    func didDisplay(_ item: RAVESlideshowItem) async {}
    func resetPagination() {}
}

public enum RAVESlideshow3DMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case spatial3D
    case immersive3D

    public var id: String { rawValue }
}

public struct RAVESlideshowPlatformCapabilities: Equatable, Sendable {
    public var supportsSpatialImages: Bool
    public var supportsImmersiveSpaces: Bool
    public var supportsStereoVideo: Bool
    public var supportsDiorama: Bool

    public init(
        supportsSpatialImages: Bool,
        supportsImmersiveSpaces: Bool,
        supportsStereoVideo: Bool,
        supportsDiorama: Bool
    ) {
        self.supportsSpatialImages = supportsSpatialImages
        self.supportsImmersiveSpaces = supportsImmersiveSpaces
        self.supportsStereoVideo = supportsStereoVideo
        self.supportsDiorama = supportsDiorama
    }

    public static let iOSFallback = RAVESlideshowPlatformCapabilities(
        supportsSpatialImages: false,
        supportsImmersiveSpaces: false,
        supportsStereoVideo: false,
        supportsDiorama: false
    )

    public static let visionOSDefault = RAVESlideshowPlatformCapabilities(
        supportsSpatialImages: true,
        supportsImmersiveSpaces: true,
        supportsStereoVideo: true,
        supportsDiorama: true
    )

    public static var current: RAVESlideshowPlatformCapabilities {
        #if os(visionOS)
        .visionOSDefault
        #else
        .iOSFallback
        #endif
    }
}

public struct RAVESlideshowVisualSettings: Codable, Hashable, Sendable {
    public var brightness: Double
    public var contrast: Double
    public var saturation: Double
    public var opacity: Double

    public init(brightness: Double = 0, contrast: Double = 1, saturation: Double = 1, opacity: Double = 1) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.opacity = opacity
    }

    public static let neutral = RAVESlideshowVisualSettings()

    public var colorAdjustments: RAVESlideshowColorAdjustments {
        RAVESlideshowColorAdjustments(brightness: brightness, contrast: contrast, saturation: saturation)
    }
}

public struct RAVESlideshowDisplaySettings: Codable, Hashable, Sendable {
    public var delay: TimeInterval
    public var transitionDuration: TimeInterval
    public var showClock: Bool
    public var showSensors: Bool
    public var useAspectRatio: Bool
    public var enableKenBurns: Bool
    public var enableDynamicBrightness: Bool
    public var enableDiorama: Bool
    public var transparentBackground: Bool
    public var textScale: Double
    public var reduceMotion: Bool
    public var mode3D: RAVESlideshow3DMode
    public var maxImageResolution2D: Int
    public var maxImageResolution3D: Int

    public init(
        delay: TimeInterval = 15,
        transitionDuration: TimeInterval = 1,
        showClock: Bool = true,
        showSensors: Bool = true,
        useAspectRatio: Bool = true,
        enableKenBurns: Bool = true,
        enableDynamicBrightness: Bool = true,
        enableDiorama: Bool = false,
        transparentBackground: Bool = false,
        textScale: Double = 1,
        reduceMotion: Bool = false,
        mode3D: RAVESlideshow3DMode = .off,
        maxImageResolution2D: Int = 0,
        maxImageResolution3D: Int = 0
    ) {
        self.delay = delay
        self.transitionDuration = transitionDuration
        self.showClock = showClock
        self.showSensors = showSensors
        self.useAspectRatio = useAspectRatio
        self.enableKenBurns = enableKenBurns
        self.enableDynamicBrightness = enableDynamicBrightness
        self.enableDiorama = enableDiorama
        self.transparentBackground = transparentBackground
        self.textScale = textScale
        self.reduceMotion = reduceMotion
        self.mode3D = mode3D
        self.maxImageResolution2D = maxImageResolution2D
        self.maxImageResolution3D = maxImageResolution3D
    }

    public func resolved(for capabilities: RAVESlideshowPlatformCapabilities) -> RAVESlideshowDisplaySettings {
        var copy = self
        if !capabilities.supportsSpatialImages {
            copy.mode3D = .off
        } else if copy.mode3D == .immersive3D && !capabilities.supportsImmersiveSpaces {
            copy.mode3D = .spatial3D
        }
        if !capabilities.supportsDiorama {
            copy.enableDiorama = false
        }
        if copy.mode3D != .off {
            copy.enableKenBurns = false
            copy.enableDiorama = false
        }
        return copy
    }
}

public struct RAVESlideshowConfiguration: Equatable, Sendable {
    public var prefetchLimit: Int
    public var retryLimit: Int
    public var steadyStateRetryDelay: TimeInterval
    public var serverDriven: Bool
    public var automaticAdvancement: Bool
    public var platformCapabilities: RAVESlideshowPlatformCapabilities

    public init(
        prefetchLimit: Int = 3,
        retryLimit: Int = 2,
        steadyStateRetryDelay: TimeInterval = 3,
        serverDriven: Bool = false,
        automaticAdvancement: Bool = true,
        platformCapabilities: RAVESlideshowPlatformCapabilities = .current
    ) {
        self.prefetchLimit = max(1, prefetchLimit)
        self.retryLimit = max(0, retryLimit)
        self.steadyStateRetryDelay = max(0.05, steadyStateRetryDelay)
        self.serverDriven = serverDriven
        self.automaticAdvancement = automaticAdvancement
        self.platformCapabilities = platformCapabilities
    }
}
