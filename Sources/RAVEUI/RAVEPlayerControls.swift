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
public struct RAVEPlayerControls<Accessories: View>: View {
    private let state: RAVEPlayerControlState
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
                @ViewBuilder accessories: () -> Accessories) {
        self.state = state
        self.togglePlayback = togglePlayback
        self.seek = seek
        self.toggleMute = toggleMute
        self.onInteraction = onInteraction
        self.onScrubbingChanged = onScrubbingChanged
        self.accessories = accessories()
    }

    public var body: some View {
        VStack(spacing: 8) {
            timeline
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                control("Back 10 seconds", "gobackward.10") { skip(-10) }
                    .disabled(!state.isSeekable)
                control(state.isPlaying ? "Pause" : "Play", state.isPlaying ? "pause.fill" : "play.fill", action: togglePlayback)
                control("Forward 10 seconds", "goforward.10") { skip(10) }
                    .disabled(!state.isSeekable)
                Spacer(minLength: 0)
                control(state.isMuted ? "Unmute" : "Mute", state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", action: toggleMute)
            }
            if Accessories.self != EmptyView.self {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) { accessories }
                        .ravePlayerButtonStyle()
                }
                .scrollIndicators(.hidden)
                .modifier(PlayerAccessoryScrollInteraction { active in
                    isAccessoryScrolling = active
                    onInteraction()
                    onScrubbingChanged(isScrubbing || active)
                })
                // No drag gesture here: it would claim touches before the
                // accessory scroller and make its off-screen buttons unreachable.
            }
        }
        .padding(12)
        .frame(maxWidth: 820)
        .background {
            #if os(visionOS)
            RoundedRectangle(cornerRadius: 24).fill(.clear).glassBackgroundEffect()
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

    @ViewBuilder private var timeline: some View {
        if state.isSeekable {
            HStack(spacing: 10) {
                Text(RAVEPlayerControlState.timecode(scrubSeconds ?? state.currentTime))
                #if !os(tvOS)
                Slider(value: Binding(
                    get: { state.clampedTime(scrubSeconds ?? state.currentTime) },
                    set: { scrubSeconds = $0; onInteraction() }
                ), in: 0...state.duration, onEditingChanged: { editing in
                    isScrubbing = editing
                    onInteraction()
                    onScrubbingChanged(editing || isAccessoryScrolling)
                    if !editing, let target = scrubSeconds {
                        seek(state.clampedTime(target))
                        scrubSeconds = nil
                    }
                })
                .accessibilityLabel("Playback position")
                .background { timelineMarks }
                #else
                ProgressView(value: state.clampedTime(state.currentTime), total: state.duration)
                    .accessibilityLabel("Playback position")
                #endif
                Text(RAVEPlayerControlState.timecode(state.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        } else {
            Label("Live", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption)
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

public extension View {
    /// Apply to a Button's label so the entire padded area is hit-testable.
    func ravePlayerControlLabel() -> some View {
        #if os(visionOS) || os(tvOS)
        self.frame(minWidth: 60, minHeight: 60).contentShape(.rect)
        #else
        self.frame(minWidth: 44, minHeight: 44).contentShape(.rect)
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
