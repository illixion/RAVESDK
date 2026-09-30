#if os(visionOS)
import RealityKit
import SwiftUI

/// Windowed stereo for a host-owned decoder/clock (browser or Atmos film).
/// Transport always stays with that host. Keep its controls in a bottom-front
/// ornament and reserve space below the picture so it cannot occlude them.
public struct RAVEExternalStereoVideoView: View {
    private let source: any PumpFrameSource
    private let settings: Pseudo3DSettings
    private let chromeOpen: Bool
    private let onUnavailable: () -> Void
    private let onToggleChrome: () -> Void
    @State private var engine = Pseudo3DStereoEngine()

    public init(source: any PumpFrameSource, settings: Pseudo3DSettings = .default,
                chromeOpen: Bool = false, onUnavailable: @escaping () -> Void,
                onToggleChrome: @escaping () -> Void = {}) {
        self.source = source
        self.settings = settings
        self.chromeOpen = chromeOpen
        self.onUnavailable = onUnavailable
        self.onToggleChrome = onToggleChrome
    }

    public var body: some View {
        GeometryReader3D { geometry in
            RealityView { content in
                engine.configure(adjustments: .neutral, settings: settings, isFlipped: false)
                engine.setChromeOpen(chromeOpen)
                engine.onPlaybackError = onUnavailable
                content.add(engine.makeVideoEntity())
                engine.observeVideoSize(content: content)
                engine.attach(frameSource: source)
            } update: { content in
                engine.updateViewBounds(content.convert(geometry.frame(in: .local), from: .local, to: .scene))
            }
            .frame(depth: 0, alignment: .front)
            .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { _ in onToggleChrome() })
        }
        // Device-measured in Hypnos and Raven: the front slab is ~9 cm proud
        // of the ornament plane. Preserve this until a replacement is measured.
        .offset(z: -90)
        .onChange(of: ObjectIdentifier(source)) { _, _ in engine.attach(frameSource: source) }
        .onChange(of: settings) { _, value in
            engine.configure(adjustments: .neutral, settings: value, isFlipped: false)
        }
        .onChange(of: chromeOpen) { _, value in engine.setChromeOpen(value) }
        .onDisappear { engine.cleanup() }
    }
}
#endif
