/*
 RAVEUI - an invisible surface for the system pointer.

 visionOS draws the pointer (a mouse or trackpad) on what it hit-tests, and it
 hit-tests what reaches the render server. A RealityKit picture (a
 `VideoPlayerComponent`, an `ImagePresentationComponent`) can take a click
 through its entity's input target, but the cursor isn't drawn on it: the
 pointer moved and clicked over Convolution's AI 3D video and RealityKit 3D
 photos with no cursor at all (device, 2026-10-27). SwiftUI's clear views
 don't reach the render server either, and a near-clear fill only catches
 from about 0.003 opacity, which can show.

 What does count, drawn and invisible, is a Metal layer that has presented a
 frame cleared to zero: LambdaVision's mouse-catcher sweep
 (`InputCatcherTechniques.swift`, `metalClear`) and Convolution's flat video
 player under the system video layer both rely on it. This is that surface,
 to lay just in front of such a picture with the picture's own gestures on
 it, so the cursor shows and the click lands on the same thing.

 Verified over a `VideoPlayerComponent` on the zero-depth slab the stereo
 player uses (`.frame(depth: 0, alignment: .front)`, the surface a few points
 in front). Not working yet over an `ImagePresentationComponent` filling a
 deep `GeometryReader3D`: overlaid there (as deep as the view, pinned to its
 back, 20 or 80 pt forward) it was laid out and drew, yet took neither the
 cursor nor clicks (device, 2026-10-27). Placement in a deep RealityKit view
 is the open question.
 */

#if os(visionOS)

import MetalKit
import SwiftUI

/// An invisible view the system pointer lands on and draws its cursor on.
/// Attach the gestures of whatever it covers to it, and place it just in
/// front of that content (`.offset(z:)`): it takes the input there.
public struct RAVEPointerSurface: UIViewRepresentable {
    public init() {}

    public func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.isOpaque = false
        view.layer.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator
        return view
    }

    public func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.presentIfNeeded(view)
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    /// Presents one cleared frame per drawable size: a resized layer drops
    /// what it presented, and would stop counting until it presents again.
    public final class Coordinator: NSObject, MTKViewDelegate {
        private var queue: MTLCommandQueue?
        private var presentedSize: CGSize = .zero

        @MainActor
        func presentIfNeeded(_ view: MTKView) {
            if view.drawableSize != presentedSize { view.setNeedsDisplay() }
        }

        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.setNeedsDisplay()
        }

        public func draw(in view: MTKView) {
            guard view.drawableSize.width > 0, view.drawableSize.height > 0,
                  view.drawableSize != presentedSize, let device = view.device,
                  let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return }
            if queue == nil { queue = device.makeCommandQueue() }
            guard let buffer = queue?.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.endEncoding() // loadAction .clear with a zero clear colour
            buffer.present(drawable)
            buffer.commit()
            presentedSize = view.drawableSize
        }
    }
}

#endif
