import SwiftUI

// A mini player: what a window, popover or bar shows while audio plays and the app's real UI is elsewhere.
//
// Longwave drew one for a streamed Mac's audio (the cover edge to edge, the song under it, a transport row) and
// Hypnos drew a second for its music library (the same, plus a compact bar over the library). The two differed
// in what they were bound to, not in what they drew, so this is the drawing. It owns no playback state, no
// artwork loading and no transport: the host supplies the cover as a view, the labels as text and the controls as
// a view (usually `RAVEPlayerControls`, whose `.strip` layout is the transport both apps use).
//
//  - `RAVEMiniPlayerPanel`: the iTunes mini player. A window's content, or a popover's.
//  - `RAVEMiniPlayerBar`: the compact one-row-and-controls bar that hangs over a library or under a window.
//  - `RAVEMiniPlayerPlaceholder`: the panel's shape with nothing playing.
//  - `RAVEMiniPlayerLayout`: the cover geometry, for hosts that size their own window.

/// The cover geometry of a `RAVEMiniPlayerPanel`, for hosts that size a window around it.
public enum RAVEMiniPlayerLayout {
    /// How tall the cover is at `width`: its own shape, never taller than a square, so the pane is exactly the
    /// shape of the art with nothing cropped or letterboxed. `aspectRatio` is width over height; nil is square.
    ///
    /// Tall art is capped at square (it pillarboxes) rather than allowed to grow taller, which keeps `topSlack`
    /// from going negative and the window from growing. Now-playing art is nearly always square or wide; a
    /// browser publishes 16:9.
    public static func artworkHeight(aspectRatio: CGFloat?, width: CGFloat) -> CGFloat {
        guard let aspectRatio, aspectRatio.isFinite, aspectRatio > 0 else { return width }
        return min(width, (width / aspectRatio).rounded())
    }

    /// Transparent space a *window* host should reserve above a glass panel so the window keeps one total height
    /// while the cover changes shape: the slack takes up the difference and shows nothing, so the panel appears to
    /// grow and shrink at its top edge only, and nothing below the art ever moves.
    ///
    /// Letting a visionOS window resize to its content instead is wrong: it anchors a window's *centre* when the
    /// content size changes (measured), so both edges move by half the delta and the controls drift from track
    /// to track. Other platforms size to the content normally, and a popover is transient, so both get 0.
    public static func topSlack(aspectRatio: CGFloat?, width: CGFloat) -> CGFloat {
        #if os(visionOS)
        return width - artworkHeight(aspectRatio: aspectRatio, width: width)
        #else
        return 0
        #endif
    }
}

/// The iTunes mini player: the cover across the full width, the song's labels, an optional row of actions
/// (favorite, queue, more) and the transport.
public struct RAVEMiniPlayerPanel<Artwork: View, Actions: View, Transport: View>: View {
    private let width: CGFloat
    private let artworkAspectRatio: CGFloat?
    private let title: String
    private let subtitle: String?
    private let detail: String?
    private let artwork: Artwork
    private let actions: Actions
    private let transport: Transport

    /// - Parameters:
    ///   - width: the panel's width; the cover spans it.
    ///   - artworkAspectRatio: the cover's width over height, nil for square (see `RAVEMiniPlayerLayout`).
    ///   - title: the song (or the status when nothing plays).
    ///   - subtitle: the artist, or an error message.
    ///   - detail: a quieter third line, such as the album.
    ///   - artwork: the cover (or a placeholder glyph). It is sized and clipped by the panel; give it no frame of its own.
    ///   - actions: a row of small buttons under the labels.
    ///   - transport: the controls, framed by the panel to its width less a gutter.
    public init(width: CGFloat = 340, artworkAspectRatio: CGFloat? = nil, title: String, subtitle: String? = nil,
                detail: String? = nil, @ViewBuilder artwork: () -> Artwork, @ViewBuilder actions: () -> Actions,
                @ViewBuilder transport: () -> Transport) {
        self.width = width
        self.artworkAspectRatio = artworkAspectRatio
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.artwork = artwork()
        self.actions = actions()
        self.transport = transport()
    }

    public var body: some View {
        VStack(spacing: 0) {
            artwork
                .frame(width: width, height: RAVEMiniPlayerLayout.artworkHeight(aspectRatio: artworkAspectRatio, width: width))
                .clipped()
            VStack(spacing: 2) {
                Text(title).font(.title3.weight(.semibold)).lineLimit(1)
                // A line is kept even when empty, so the panel doesn't change height from song to song.
                Text(subtitle ?? " ").font(.body).foregroundStyle(.secondary).lineLimit(1)
                if let detail { Text(detail).font(.subheadline).foregroundStyle(.tertiary).lineLimit(1) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            actions
                .padding(.top, 10)
            transport
                .frame(width: width - 24)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 12)
        }
        .frame(width: width)
    }
}

extension RAVEMiniPlayerPanel where Actions == EmptyView {
    public init(width: CGFloat = 340, artworkAspectRatio: CGFloat? = nil, title: String, subtitle: String? = nil,
                detail: String? = nil, @ViewBuilder artwork: () -> Artwork, @ViewBuilder transport: () -> Transport) {
        self.init(width: width, artworkAspectRatio: artworkAspectRatio, title: title, subtitle: subtitle, detail: detail,
                  artwork: artwork, actions: { EmptyView() }, transport: transport)
    }
}

/// The panel's shape with nothing playing, so a window that stays open doesn't collapse.
public struct RAVEMiniPlayerPlaceholder: View {
    private let width: CGFloat
    private let title: LocalizedStringKey
    private let systemImage: String
    private let message: LocalizedStringKey

    public init(width: CGFloat = 340, title: LocalizedStringKey = "Nothing Playing", systemImage: String = "music.note",
                message: LocalizedStringKey) {
        self.width = width
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }

    public var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
            .frame(width: width, height: width)
    }
}

/// The compact mini player: the cover and labels in one tappable row (it opens the full player), the controls
/// under it, on a surface of its own: glass on visionOS, material elsewhere. Hang it over a library (a bottom
/// safe-area inset, a visionOS ornament's stack) and animate its insertion from the host.
public struct RAVEMiniPlayerBar<Artwork: View, Controls: View>: View {
    private let title: String
    private let subtitle: String?
    private let artworkSize: CGFloat
    private let open: () -> Void
    private let artwork: Artwork
    private let controls: Controls

    public init(title: String, subtitle: String? = nil, artworkSize: CGFloat = 38, open: @escaping () -> Void,
                @ViewBuilder artwork: () -> Artwork, @ViewBuilder controls: () -> Controls) {
        self.title = title
        self.subtitle = subtitle
        self.artworkSize = artworkSize
        self.open = open
        self.artwork = artwork()
        self.controls = controls()
    }

    public var body: some View {
        VStack(spacing: 2) {
            Button(action: open) {
                HStack(spacing: 10) {
                    artwork
                        .frame(width: artworkSize, height: artworkSize)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            controls
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .transition(.opacity)
        #if os(visionOS)
        .glassBackgroundEffect(in: .rect(cornerRadius: 28))
        #else
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        #endif
    }
}
