@_exported import RAVEMediaCore
import CoreGraphics
import Foundation

#if canImport(SwiftUI)
import SwiftUI

/// The cues of `track` showing on the host's clock, handed to `content`.
///
/// `time` is sampled about 20 times a second and should return the film time
/// of the frame being shown; `content` re-renders only when the set changes.
public struct RAVESubtitleCues<Content: View>: View {
    private let track: RAVESubtitleTrack?
    private let time: @MainActor () -> Double
    private let content: ([RAVESubtitleCue]) -> Content
    @State private var showing: [RAVESubtitleCue] = []

    public init(track: RAVESubtitleTrack?, time: @escaping @MainActor () -> Double,
                @ViewBuilder content: @escaping ([RAVESubtitleCue]) -> Content) {
        self.track = track
        self.time = time
        self.content = content
    }

    public var body: some View {
        content(showing)
            .task(id: track?.id) {
                guard let track else {
                    showing = []
                    return
                }
                while !Task.isCancelled {
                    let current = track.cues(at: time())
                    if current != showing { showing = current }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
    }
}

/// Draws a subtitle track over a picture, following the host's clock.
///
/// `pictureAspect` (width / height) places the text inside an aspect-fitted
/// picture rather than in a letterbox bar; leave it nil when the view is the
/// picture's own size. Never takes hits.
public struct RAVESubtitleOverlay: View {
    private let track: RAVESubtitleTrack?
    private let pictureAspect: CGFloat?
    private let time: @MainActor () -> Double

    public init(track: RAVESubtitleTrack?, pictureAspect: CGFloat? = nil, time: @escaping @MainActor () -> Double) {
        self.track = track
        self.pictureAspect = pictureAspect
        self.time = time
    }

    public var body: some View {
        GeometryReader { geometry in
            let picture = Self.fittedRect(in: geometry.size, aspect: pictureAspect)
            let fontSize = Self.fontSize(forPictureHeight: picture.height)
            RAVESubtitleCues(track: track, time: time) { showing in
                let text = showing.filter { $0.image == nil }
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        block(text.filter { $0.placement == .top }, fontSize: fontSize)
                        Spacer(minLength: 0)
                        block(text.filter { $0.placement == .bottom }, fontSize: fontSize)
                    }
                    .padding(.vertical, picture.height * 0.05)
                    .frame(width: picture.width, height: picture.height)
                    ForEach(showing.compactMap(\.image), id: \.id) { image in
                        RAVESubtitleBitmap(image: image)
                            .frame(width: image.frame.width * picture.width, height: image.frame.height * picture.height)
                            .offset(x: image.frame.minX * picture.width, y: image.frame.minY * picture.height)
                    }
                }
                .frame(width: picture.width, height: picture.height, alignment: .topLeading)
                .position(x: picture.midX, y: picture.midY)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func block(_ cues: [RAVESubtitleCue], fontSize: CGFloat) -> some View {
        if !cues.isEmpty {
            RAVESubtitleText(cues: cues, fontSize: fontSize)
        }
    }

    /// About a twentieth of the picture's height: 36 pt in a 720 pt visionOS
    /// window, 54 pt on a 1080 pt TV, 19 pt across a landscape phone.
    static func fontSize(forPictureHeight height: CGFloat) -> CGFloat {
        min(max(height * 0.05, 15), 64)
    }

    static func fittedRect(in size: CGSize, aspect: CGFloat?) -> CGRect {
        guard let aspect, aspect > 0, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        if size.width / size.height > aspect {
            let width = size.height * aspect
            return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        }
        let height = size.width / aspect
        return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
    }
}

/// A bitmap subtitle, decoded off the main thread when it first shows.
public struct RAVESubtitleBitmap: View {
    private let image: RAVESubtitleImage
    @State private var decoded: (id: Int, image: CGImage)?

    public init(image: RAVESubtitleImage) {
        self.image = image
    }

    public var body: some View {
        ZStack {
            if let decoded, decoded.id == image.id {
                Image(decorative: decoded.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
            }
        }
        .task(id: image.id) {
            let image = self.image
            if let cg = await Task.detached(priority: .userInitiated, operation: { image.makeImage() }).value {
                decoded = (image.id, cg)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Subtitles on a panel of their own rather than over the picture: for a
/// stereo picture, where text drawn over it would have to win a depth
/// contest with the scene. Every cue is shown in start order whatever its
/// placement, and the panel keeps room for `reservedLines` so it doesn't
/// jump in size as cues come and go.
public struct RAVESubtitlePanel: View {
    private let track: RAVESubtitleTrack?
    private let fontSize: CGFloat
    private let reservedLines: Int
    private let time: @MainActor () -> Double

    public init(track: RAVESubtitleTrack?, fontSize: CGFloat = 30, reservedLines: Int = 2,
                time: @escaping @MainActor () -> Double) {
        self.track = track
        self.fontSize = fontSize
        self.reservedLines = reservedLines
        self.time = time
    }

    public var body: some View {
        RAVESubtitleCues(track: track, time: time) { showing in
            ZStack(alignment: .top) {
                if showing.contains(where: { $0.image == nil }) {
                    RAVESubtitleText(cues: showing, fontSize: fontSize)
                }
                // Bitmaps keep their shape, fitted to the panel's height.
                VStack(spacing: fontSize * 0.15) {
                    ForEach(showing.compactMap(\.image), id: \.id) { image in
                        RAVESubtitleBitmap(image: image)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: fontSize * 1.45)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: CGFloat(reservedLines) * fontSize * 1.45, alignment: .top)
        }
        .allowsHitTesting(false)
    }
}

/// One group of simultaneous cues, styled the way subtitles are on Apple
/// players: white on a translucent black plate.
public struct RAVESubtitleText: View {
    private let cues: [RAVESubtitleCue]
    private let fontSize: CGFloat

    public init(cues: [RAVESubtitleCue], fontSize: CGFloat) {
        self.cues = cues
        self.fontSize = fontSize
    }

    public var body: some View {
        VStack(spacing: fontSize * 0.15) {
            ForEach(Array(cues.filter { $0.image == nil }.enumerated()), id: \.offset) { _, cue in
                Text(cue.text)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, fontSize * 0.4)
                    .padding(.vertical, fontSize * 0.12)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: fontSize * 0.2))
            }
        }
        .padding(.horizontal, fontSize)
        .accessibilityIdentifier("rave.subtitles")
    }
}
#endif
