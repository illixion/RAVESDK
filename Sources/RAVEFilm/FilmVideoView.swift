/*
 Hypnos - hosts a FilmVideoPlayer's picture in SwiftUI.

 macOS makes the display layer the view's backing layer, so AppKit sizes it.
 UIKit has no per-instance backing layer, so on iOS and tvOS it is a
 sublayer kept at the view's bounds.

 visionOS shows the player's RealityKit video plane (`videoEntity`, placed
 by RAVEMedia's `RAVEVideoPlaneView`) and states the picture's display
 criteria to the window from an empty UIKit view behind it. With
 `showsPicture` off the plane is left to another scene (an immersive
 space's screen adds `videoEntity` to its own content) and only the
 criteria stay, since the window is still the one the display mode follows.
 */

import AVFoundation
import SwiftUI
#if os(tvOS) || os(visionOS)
import AVKit
#endif
#if os(visionOS)
import RAVEMedia
#endif

#if os(macOS)
public struct FilmVideoView: NSViewRepresentable {
    let player: FilmVideoPlayer

    public init(player: FilmVideoPlayer) {
        self.player = player
    }

    public func makeNSView(context: Context) -> LayerHostView {
        LayerHostView(videoLayer: player.displayLayer)
    }

    public func updateNSView(_ view: LayerHostView, context: Context) {}

    public final class LayerHostView: NSView {
        private let videoLayer: AVSampleBufferDisplayLayer

        init(videoLayer: AVSampleBufferDisplayLayer) {
            self.videoLayer = videoLayer
            super.init(frame: .zero)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override public func makeBackingLayer() -> CALayer {
            videoLayer.backgroundColor = NSColor.black.cgColor
            return videoLayer
        }
    }
}
#elseif os(visionOS)
public struct FilmVideoView: View {
    let player: FilmVideoPlayer
    var squareCorners: Bool
    var opacity: Float
    var takesInput: Bool
    var showsPicture: Bool
    var onTap: () -> Void

    /// - Parameters:
    ///   - opacity: SwiftUI's `.opacity` doesn't reach the plane; 0 hides it
    ///     (the renderer keeps being fed, so the picture is ready when it
    ///     comes back), a little dims it under an open menu.
    ///   - takesInput: the plane catches taps (`onTap`); off while a menu
    ///     should keep the gaze.
    ///   - showsPicture: off, the plane is shown elsewhere and this view
    ///     only states the display criteria.
    public init(player: FilmVideoPlayer, squareCorners: Bool = false, opacity: Float = 1,
                takesInput: Bool = true, showsPicture: Bool = true, onTap: @escaping () -> Void = {}) {
        self.player = player
        self.squareCorners = squareCorners
        self.opacity = opacity
        self.takesInput = takesInput
        self.showsPicture = showsPicture
        self.onTap = onTap
    }

    public var body: some View {
        if showsPicture {
            RAVEVideoPlaneView(entity: player.videoEntity, aspect: player.pictureAspect, squareCorners: squareCorners,
                               opacity: opacity, takesInput: takesInput, onTap: onTap,
                               onAttach: { player.pictureAttached = true })
                .background { CriteriaHost(player: player) }
        } else {
            CriteriaHost(player: player)
        }
    }

    private struct CriteriaHost: UIViewRepresentable {
        let player: FilmVideoPlayer

        func makeUIView(context: Context) -> CriteriaView { CriteriaView() }

        func updateUIView(_ view: CriteriaView, context: Context) {
            view.displayCriteria = player.displayCriteria
        }
    }

    final class CriteriaView: UIView {
        /// Stated to the window's display manager while the view is in it.
        var displayCriteria: AVDisplayCriteria? {
            didSet { applyDisplayCriteria() }
        }
        private weak var criteriaWindow: UIWindow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyDisplayCriteria()
        }

        private func applyDisplayCriteria() {
            if let criteriaWindow, criteriaWindow !== window {
                criteriaWindow.avDisplayManager.preferredDisplayCriteria = nil
            }
            criteriaWindow = window
            window?.avDisplayManager.preferredDisplayCriteria = displayCriteria
        }
    }
}
#else
public struct FilmVideoView: UIViewRepresentable {
    let player: FilmVideoPlayer

    public init(player: FilmVideoPlayer) {
        self.player = player
    }

    public func makeUIView(context: Context) -> LayerHostView {
        LayerHostView(videoLayer: player.displayLayer)
    }

    public func updateUIView(_ view: LayerHostView, context: Context) {
        #if os(tvOS)
        view.displayCriteria = player.displayCriteria
        #endif
    }

    public final class LayerHostView: UIView {
        private let videoLayer: AVSampleBufferDisplayLayer
        #if os(tvOS)
        /// Stated to the window's display manager while the view is in it.
        var displayCriteria: AVDisplayCriteria? {
            didSet { applyDisplayCriteria() }
        }
        private weak var criteriaWindow: UIWindow?

        override public func didMoveToWindow() {
            super.didMoveToWindow()
            applyDisplayCriteria()
        }

        private func applyDisplayCriteria() {
            if let criteriaWindow, criteriaWindow !== window {
                criteriaWindow.avDisplayManager.preferredDisplayCriteria = nil
            }
            criteriaWindow = window
            guard let window else { return }
            window.avDisplayManager.preferredDisplayCriteria = displayCriteria
            print("FilmVideoView: display criteria \(displayCriteria == nil ? "cleared" : "set"), "
                + "matching enabled=\(window.avDisplayManager.isDisplayCriteriaMatchingEnabled)")
        }
        #endif

        init(videoLayer: AVSampleBufferDisplayLayer) {
            self.videoLayer = videoLayer
            super.init(frame: .zero)
            backgroundColor = .black
            layer.addSublayer(videoLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override public func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
#endif
