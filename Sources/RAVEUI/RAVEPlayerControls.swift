import SwiftUI

/// Playback values from the host's clock. The controls never own a decoder or
/// audio session: a browser, AVPlayer and Atmos transport supply the same UI.
public struct RAVEPlayerControlState: Equatable, Sendable {
    public var currentTime: Double
    public var duration: Double
    public var bufferedUntil: Double
    public var isPlaying: Bool
    public var isMuted: Bool
    public var markers: [Double]

    public init(currentTime: Double, duration: Double, bufferedUntil: Double = 0,
                isPlaying: Bool, isMuted: Bool, markers: [Double] = []) {
        self.currentTime = currentTime
        self.duration = duration
        self.bufferedUntil = bufferedUntil
        self.isPlaying = isPlaying
        self.isMuted = isMuted
        self.markers = markers
    }

    public var isSeekable: Bool { duration.isFinite && duration > 0 }
    /// An endless stream. A finite duration of 0 is a length not known yet,
    /// which every player reports for a moment while it loads.
    public var isLive: Bool { duration.isInfinite }

    public func clampedTime(_ time: Double) -> Double {
        guard time.isFinite else { return 0 }
        return min(max(time, 0), isSeekable ? duration : 0)
    }

    public static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Native SwiftUI timeline and transport, with host-supplied feature buttons.
/// On visionOS mount this in an ornament for a RealityKit picture: an overlay
/// inside that picture's depth region floats away from the window's glass.
/// Scrubbing holds a local preview and seeks once on release. Each interaction
/// and the scrub lifecycle reach the host so auto-hide cannot remove a control
/// from under a hand. App features belong on the accessory row, which scrolls
/// independently on compact windows instead of squeezing out the timeline.
///
/// The control sizes itself; hosts need no width. A visionOS ornament proposes
/// no size and takes the content's ideal, which a bare `Slider` and scroller
/// put at a couple of hundred points: the whole bar collapsed, mute landed on
/// the skip button and every accessory scrolled out of sight. See
/// `PlayerControlsWidth` for how the ideal is resolved per platform.
/// How the bar is laid out.
public enum RAVEPlayerControlsLayout: Sendable {
    /// Timeline, transport and the accessory row stacked in three rows.
    case stacked
    /// One row: transport, timeline, mute, then the accessories inline, or
    /// behind a "More" menu when they don't fit. For a bar hung under a
    /// window, where every row of height is window the picture doesn't get.
    case compact
}

public struct RAVEPlayerControls<Accessories: View>: View {
    private let state: RAVEPlayerControlState
    private let layout: RAVEPlayerControlsLayout
    private let onMenuChanged: (Bool) -> Void
    private let togglePlayback: () -> Void
    private let seek: (Double) -> Void
    private let toggleMute: () -> Void
    private let onInteraction: () -> Void
    private let onScrubbingChanged: (Bool) -> Void
    private let accessories: Accessories
    @State private var scrubSeconds: Double?
    @State private var isScrubbing = false
    @State private var isAccessoryScrolling = false

    public init(state: RAVEPlayerControlState, togglePlayback: @escaping () -> Void,
                seek: @escaping (Double) -> Void, toggleMute: @escaping () -> Void,
                onInteraction: @escaping () -> Void = {},
                onScrubbingChanged: @escaping (Bool) -> Void = { _ in },
                layout: RAVEPlayerControlsLayout = .stacked,
                onMenuChanged: @escaping (Bool) -> Void = { _ in },
                @ViewBuilder accessories: () -> Accessories) {
        self.state = state
        self.layout = layout
        self.onMenuChanged = onMenuChanged
        self.togglePlayback = togglePlayback
        self.seek = seek
        self.toggleMute = toggleMute
        self.onInteraction = onInteraction
        self.onScrubbingChanged = onScrubbingChanged
        self.accessories = accessories()
    }

    public var body: some View {
        Group {
            switch layout {
            case .stacked: stackedBar
            case .compact: compactBar
            }
        }
        .background {
            #if os(visionOS)
            RoundedRectangle(cornerRadius: layout == .compact ? 40 : 24).fill(.clear).glassBackgroundEffect()
            #else
            RoundedRectangle(cornerRadius: 20).fill(.regularMaterial)
            #endif
        }
        .onDisappear {
            if isScrubbing || isAccessoryScrolling { onScrubbingChanged(false) }
            isScrubbing = false
            isAccessoryScrolling = false
            scrubSeconds = nil
        }
    }

    // MARK: Compact

    private var compactBar: some View {
        PlayerControlsWidth(maxWidth: PlayerControlsWidth.compactMaxWidth) {
            // The first row whose ideal width fits: everything inline, else
            // the accessories behind one menu.
            ViewThatFits(in: .horizontal) {
                compactRow(overflow: false)
                compactRow(overflow: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private func compactRow(overflow: Bool) -> some View {
        HStack(spacing: 6) {
            control("Back 10 seconds", "gobackward.10") { skip(-10) }
                .disabled(!state.isSeekable)
            control(state.isPlaying ? "Pause" : "Play", state.isPlaying ? "pause.fill" : "play.fill", action: togglePlayback)
            control("Forward 10 seconds", "goforward.10") { skip(10) }
                .disabled(!state.isSeekable)
            timelineRow
                .frame(minWidth: Self.compactTimelineMinWidth, maxWidth: .infinity)
            control(state.isMuted ? "Unmute" : "Mute", state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", action: toggleMute)
            if Accessories.self != EmptyView.self {
                if overflow {
                    Menu {
                        Group { accessories }
                            .environment(\.ravePlayerControlsInMenu, true)
                            .onAppear { onMenuChanged(true) }
                            .onDisappear { onMenuChanged(false) }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly).ravePlayerControlLabel()
                            .font(.title2)
                    }
                    .ravePlayerButtonStyle()
                    .help("More")
                } else {
                    Divider().frame(height: 28)
                    HStack(spacing: 6) { accessories }
                        .ravePlayerButtonStyle()
                        .fixedSize()
                }
            }
        }
    }

    #if os(visionOS) || os(tvOS)
    private static var compactTimelineMinWidth: CGFloat { 280 }
    #else
    private static var compactTimelineMinWidth: CGFloat { 160 }
    #endif

    // MARK: Stacked

    private var stackedBar: some View {
        PlayerControlsWidth {
            VStack(spacing: 8) {
                timeline
                // Mute has a slot of its own, balanced by an empty one, so the
                // transport stays centred and the two can never overlap however
                // narrow the bar gets.
                HStack(spacing: 12) {
                    Color.clear.frame(width: Self.controlSide, height: 1)
                    Spacer(minLength: 0)
                    HStack(spacing: 12) {
                        control("Back 10 seconds", "gobackward.10") { skip(-10) }
                            .disabled(!state.isSeekable)
                        control(state.isPlaying ? "Pause" : "Play", state.isPlaying ? "pause.fill" : "play.fill", action: togglePlayback)
                        control("Forward 10 seconds", "goforward.10") { skip(10) }
                            .disabled(!state.isSeekable)
                    }
                    Spacer(minLength: 0)
                    control(state.isMuted ? "Unmute" : "Mute", state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", action: toggleMute)
                }
                if Accessories.self != EmptyView.self {
                    // The row at its natural width when it fits, which is also what
                    // gives the bar a measurable ideal width; a scroller only when
                    // it does not, so a long row never squeezes out the timeline.
                    ViewThatFits(in: .horizontal) {
                        accessoryRow
                        ScrollView(.horizontal) { accessoryRow }
                            .scrollIndicators(.hidden)
                            .modifier(PlayerAccessoryScrollInteraction { active in
                                isAccessoryScrolling = active
                                onInteraction()
                                onScrubbingChanged(isScrubbing || active)
                            })
                    }
                    #if os(visionOS) || os(tvOS)
                    .frame(height: 60)
                    #else
                    .frame(height: 44)
                    #endif
                    // No drag gesture here: it would claim touches before the
                    // accessory scroller and make its off-screen buttons unreachable.
                }
            }
            .padding(12)
        }
    }

    private var accessoryRow: some View {
        HStack(spacing: 12) { accessories }
            .ravePlayerButtonStyle()
            .fixedSize(horizontal: true, vertical: false)
    }

    #if os(visionOS) || os(tvOS)
    private static var controlSide: CGFloat { 60 }
    #else
    private static var controlSide: CGFloat { 44 }
    #endif

    private var timeline: some View {
        timelineRow.padding(.horizontal, 12)
    }

    /// Position, scrubber, duration. Live only for an endless stream: while a
    /// player is still loading its duration reads 0, and that is shown as an
    /// inert scrubber rather than flashing "Live" until the length arrives.
    @ViewBuilder private var timelineRow: some View {
        if state.isLive {
            Label("Live", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 10) {
                Text(state.isSeekable ? RAVEPlayerControlState.timecode(scrubSeconds ?? state.currentTime) : "–:––")
                #if !os(tvOS)
                Slider(value: Binding(
                    get: { state.clampedTime(scrubSeconds ?? state.currentTime) },
                    set: { scrubSeconds = $0; onInteraction() }
                ), in: 0...(state.isSeekable ? state.duration : 1), onEditingChanged: { editing in
                    isScrubbing = editing
                    onInteraction()
                    onScrubbingChanged(editing || isAccessoryScrolling)
                    if !editing, let target = scrubSeconds {
                        seek(state.clampedTime(target))
                        scrubSeconds = nil
                    }
                })
                .disabled(!state.isSeekable)
                .accessibilityLabel("Playback position")
                .background { if state.isSeekable { timelineMarks } }
                #else
                ProgressView(value: state.clampedTime(state.currentTime), total: state.isSeekable ? state.duration : 1)
                    .accessibilityLabel("Playback position")
                #endif
                Text(state.isSeekable ? RAVEPlayerControlState.timecode(state.duration) : "–:––")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var timelineMarks: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.25))
                    .frame(width: geometry.size.width * state.clampedTime(state.bufferedUntil) / state.duration, height: 3)
                ForEach(Array(state.markers.enumerated()), id: \.offset) { index, time in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(index == 0 ? Color.green : Color.red)
                        .frame(width: 3, height: 14)
                        .position(x: geometry.size.width * state.clampedTime(time) / state.duration,
                                  y: geometry.size.height / 2)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func skip(_ seconds: Double) { seek(state.clampedTime(state.currentTime + seconds)) }

    private func control(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            onInteraction()
            action()
        } label: {
            Label(title, systemImage: symbol).labelStyle(.iconOnly).ravePlayerControlLabel()
                .font(.title2)
        }
        .ravePlayerButtonStyle()
        .help(title)
        .accessibilityLabel(title)
    }
}

public extension View {
    /// Explicit hit targets: gaze uses 60 points; touch and pointer use 44.
    /// tvOS keeps the system's focusable button style.
    func ravePlayerButtonStyle() -> some View {
        #if os(tvOS)
        self.buttonStyle(.bordered)
        #elseif os(visionOS)
        self.buttonStyle(.borderless)
        #else
        self.raveChromeButtonStyle()
        #endif
    }
}

extension EnvironmentValues {
    /// True inside the compact bar's "More" menu, where an accessory's label
    /// needs its title as well as its icon.
    @Entry public var ravePlayerControlsInMenu = false
}

/// An accessory's label: icon only with the padded hit target on the bar,
/// title and icon inside the compact bar's "More" menu.
private struct PlayerAccessoryLabel: ViewModifier {
    @Environment(\.ravePlayerControlsInMenu) private var inMenu

    func body(content: Content) -> some View {
        if inMenu {
            content.labelStyle(.titleAndIcon)
        } else {
            content.labelStyle(.iconOnly).ravePlayerControlLabel()
        }
    }
}

public extension View {
    /// For an accessory `Label`: replaces `.labelStyle(.iconOnly)
    /// .ravePlayerControlLabel()` so the label reads in the "More" menu too.
    func ravePlayerAccessoryLabel() -> some View {
        modifier(PlayerAccessoryLabel())
    }

    /// Apply to a Button's label so the entire padded area is hit-testable.
    func ravePlayerControlLabel() -> some View {
        #if os(visionOS) || os(tvOS)
        self.frame(minWidth: 60, minHeight: 60).contentShape(.rect)
        #else
        self.frame(minWidth: 44, minHeight: 44).contentShape(.rect)
        #endif
    }
}

/// Resolves the bar's width, capped at `maxWidth` (820 points; 1180 for the compact bar).
///
/// A real width proposal is honoured as is. A missing one is the host asking
/// for the ideal size, and the right answer differs by platform:
/// - visionOS: an ornament takes the ideal as its final size, so answer with
///   the content's natural width (every accessory on one row), but no
///   narrower than a comfortable scrubbing length.
/// - Elsewhere the bar sits in a real window. Hosts that ask for the ideal there
///   are measuring whether it fits before handing it the space they have
///   (`ViewThatFits`, Hypnos's iOS ornament shim). A natural width wider than a
///   phone would make them scroll the whole bar sideways, timeline included,
///   when the accessory row already scrolls itself. So answer compactly and
///   let the real proposal decide.
struct PlayerControlsWidth: Layout {
    static let maxWidth: CGFloat = 820
    /// The one-row bar holds what three rows did, so it may run wider.
    static let compactMaxWidth: CGFloat = 1180
    var maxWidth: CGFloat = Self.maxWidth
    #if os(visionOS)
    static let preferredWidth: CGFloat = 600
    #else
    static let compactWidth: CGFloat = 320
    #endif

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = resolvedWidth(proposal.width, content: content)
        let height = content.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)).height
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }

    private func resolvedWidth(_ proposed: CGFloat?, content: LayoutSubview) -> CGFloat {
        if let proposed, proposed.isFinite { return min(proposed, maxWidth) }
        #if os(visionOS)
        let natural = content.sizeThatFits(.unspecified).width
        return min(max(natural, Self.preferredWidth), maxWidth)
        #else
        return Self.compactWidth
        #endif
    }
}

private struct PlayerAccessoryScrollInteraction: ViewModifier {
    let onActiveChanged: (Bool) -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15, iOS 18, tvOS 18, visionOS 2, *) {
            content.onScrollPhaseChange { _, phase in onActiveChanged(phase != .idle) }
        } else {
            content
        }
    }
}
