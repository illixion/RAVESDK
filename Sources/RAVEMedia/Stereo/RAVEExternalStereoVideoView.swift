#if os(visionOS)
import RealityKit
import SwiftUI

/// Windowed stereo for a host-owned decoder/clock (browser or Atmos film).
/// Transport always stays with that host. Keep its controls in a bottom-front
/// ornament and reserve space below the picture so it cannot occlude them.
///
/// `packedStereo` plays a source that already holds both eyes as real 3D (no
/// depth model); nil is the fake-3D warp of a mono source. It is read when a
/// source attaches, so changing it needs a new source: re-attaching invalidates
/// the old one (a `SampleBufferFrameSource` drops its decoder).
///
/// `subtitles` are drawn into the picture itself (see `RAVEStereoSubtitleFrame`).
public struct RAVEExternalStereoVideoView: View {
    private let source: any PumpFrameSource
    private let settings: Pseudo3DSettings
    private let chromeOpen: Bool
    private let chromeTakesInput: Bool
    private let onUnavailable: () -> Void
    private let onToggleChrome: () -> Void
    private let packedStereo: RAVEPackedStereoLayout?
    private let squareCorners: Bool
    private let subtitles: RAVEStereoSubtitleFrame?
    private let onPerformance: ((RAVEStereoPerformance) -> Void)?
    @State private var engine = Pseudo3DStereoEngine()

    public init(source: any PumpFrameSource, settings: Pseudo3DSettings = .default,
                chromeOpen: Bool = false, chromeTakesInput: Bool = false,
                packedStereo: RAVEPackedStereoLayout? = nil,
                squareCorners: Bool = false,
                subtitles: RAVEStereoSubtitleFrame? = nil,
                onUnavailable: @escaping () -> Void,
                onToggleChrome: @escaping () -> Void = {},
                onPerformance: ((RAVEStereoPerformance) -> Void)? = nil) {
        self.onPerformance = onPerformance
        self.packedStereo = packedStereo
        self.squareCorners = squareCorners
        self.subtitles = subtitles
        self.source = source
        self.settings = settings
        self.chromeOpen = chromeOpen
        self.chromeTakesInput = chromeTakesInput
        self.onUnavailable = onUnavailable
        self.onToggleChrome = onToggleChrome
    }

    public var body: some View {
        GeometryReader3D { geometry in
            RealityView { content in
                engine.configure(adjustments: .neutral, settings: settings, isFlipped: false)
                engine.setChromeOpen(chromeOpen, takesInput: chromeTakesInput)
                engine.setSquareCorners(squareCorners)
                engine.onPlaybackError = onUnavailable
                engine.onPerformance = onPerformance
                engine.setSubtitles(subtitles)
                content.add(engine.makeVideoEntity())
                engine.observeVideoSize(content: content)
                engine.attach(frameSource: source, packedStereo: packedStereo)
            } update: { content in
                engine.updateViewBounds(content.convert(geometry.frame(in: .local), from: .local, to: .scene))
            }
            .frame(depth: 0, alignment: .front)
            .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { _ in onToggleChrome() })
        }
        // Device-measured in Hypnos and Raven: the front slab is ~9 cm proud
        // of the ornament plane. Preserve this until a replacement is measured.
        .offset(z: -90)
        .onChange(of: ObjectIdentifier(source)) { _, _ in engine.attach(frameSource: source, packedStereo: packedStereo) }
        .onChange(of: settings) { _, value in
            engine.configure(adjustments: .neutral, settings: value, isFlipped: false)
        }
        .onChange(of: chromeOpen) { _, value in engine.setChromeOpen(value, takesInput: chromeTakesInput) }
        .onChange(of: chromeTakesInput) { _, value in engine.setChromeOpen(chromeOpen, takesInput: value) }
        .onChange(of: squareCorners) { _, value in engine.setSquareCorners(value) }
        .onChange(of: subtitles) { _, value in engine.setSubtitles(value) }
        .onDisappear { engine.cleanup() }
    }
}
#endif
