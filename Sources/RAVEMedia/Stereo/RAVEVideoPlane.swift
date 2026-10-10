/*
 RAVEMedia - a RealityKit video plane in a window

 Where a `VideoPlayerComponent`'s screen goes in a visionOS window, shared by
 the stereo engine and the film player's flat picture. On visionOS video
 drawn through RealityKit's video component looks as AVKit's own player
 does; the same frames through an `AVSampleBufferDisplayLayer` or
 `AVPlayerLayer` came out visibly darker and flatter in HDR (side by side
 on the device, 2026-10-10).

 The recipe is the stereo player's, device-measured:
 - the RealityView is a zero-depth slab aligned to the front of the
   window's depth, pulled back by `viewRecess` (the front slab sits ~9 cm
   proud of the ornament plane), and the plane `planeDepthTrim` behind the
   slab's centre;
 - the plane is placed with `setPosition(_, relativeTo: nil)`: a scene-space
   centre set as a local position doubled any offset of the view in its
   window;
 - its size comes from the video's aspect, never the measured mesh: the
   component's screen reads 1×1 until frames present, then settles at
   (aspect × 1) m with no event;
 - with square corners the plane overscans its view a little so the
   window's edge cuts the mesh's rounded corners off.

 SwiftUI's `.opacity` doesn't reach RealityKit content: fades are an
 `OpacityComponent`. A 2D overlay doesn't catch gaze over a RealityView:
 taps land on a collision shape on the plane.
 */

#if os(visionOS)
import RealityKit
import SwiftUI

public enum RAVEVideoPlane {
    /// Extra plane on each side, as a fraction of the plane's height, when
    /// the corners should read square. A corner of radius r reads square
    /// once the clip lies 0.29 r inside each edge; the mesh's radius is
    /// ~2.7 % of its height (device, 2026-10-07), so this crops ~1 % per edge.
    public static let squareCornerOverscan: Float = 0.012
    /// Metres the plane sits behind the centre of its view's depth. At the
    /// centre it read ~5 cm in front of the window, and 5 cm back it still
    /// covered the window's resize handles (device, 2026-10-07).
    public static let planeDepthTrim: Float = 0.12
    /// The view's z offset in points. Device-measured in Hypnos and Raven:
    /// the front slab is ~9 cm proud of the ornament plane.
    public static let viewRecess: CGFloat = -90

    /// Centres `entity` on `bounds` (scene space), `planeDepthTrim` back.
    public static func place(_ entity: Entity, in bounds: BoundingBox) {
        var center = bounds.center
        center.z -= planeDepthTrim
        entity.setPosition(center, relativeTo: nil)
    }

    /// The plane's height in metres (its scale: the mesh is aspect × 1 m)
    /// for a video of `aspect` fitted inside `bounds`.
    public static func fittedHeight(in bounds: BoundingBox, aspect: Float, squareCorners: Bool) -> Float? {
        guard aspect > 0, bounds.extents.x > 1e-4, bounds.extents.y > 1e-4 else { return nil }
        var height = min(bounds.extents.x / aspect, bounds.extents.y)
        if squareCorners { height *= 1 + 2 * squareCornerOverscan }
        return height.isFinite && height > 1e-4 ? height : nil
    }
}

/// A flat video plane filling its view, for an entity carrying a
/// `VideoPlayerComponent` the caller owns (and keeps feeding while the view
/// comes and goes).
public struct RAVEVideoPlaneView: View {
    let entity: Entity
    /// Width over height of the picture; nil until known (the plane then
    /// fills the view's height as a square).
    var aspect: Float?
    var squareCorners: Bool
    var opacity: Float
    var takesInput: Bool
    var onTap: () -> Void
    var onAttach: () -> Void

    /// - Parameter onAttach: the entity is in the view's content, so a
    ///   renderer its component holds can take samples.
    public init(entity: Entity, aspect: Float?, squareCorners: Bool = false, opacity: Float = 1,
                takesInput: Bool = true, onTap: @escaping () -> Void = {}, onAttach: @escaping () -> Void = {}) {
        self.entity = entity
        self.aspect = aspect
        self.squareCorners = squareCorners
        self.opacity = opacity
        self.takesInput = takesInput
        self.onTap = onTap
        self.onAttach = onAttach
    }

    public var body: some View {
        GeometryReader3D { geometry in
            RealityView { content in
                content.add(entity)
                onAttach()
            } update: { content in
                let bounds = content.convert(geometry.frame(in: .local), from: .local, to: .scene)
                RAVEVideoPlane.place(entity, in: bounds)
                // Hidden, the plane also shrinks to nothing: another plane (a
                // stereo picture) may sit exactly where it is, and a
                // transparent plane could still fight it for depth. It stays in
                // the scene, so its renderer can keep taking samples.
                let shown = opacity > 0
                if let height = RAVEVideoPlane.fittedHeight(in: bounds, aspect: aspect ?? 1, squareCorners: squareCorners) {
                    let scale = shown ? height : 1e-5
                    if abs(entity.scale.x - scale) > 0.0005 || (!shown && entity.scale.x > 1e-4) {
                        entity.scale = SIMD3(repeating: scale)
                    }
                }
                entity.components.set(OpacityComponent(opacity: opacity))
                // On the plane, in mesh-local metres: aspect × 1, flat.
                let box = ShapeResource.generateBox(width: aspect ?? 1, height: 1, depth: 0.001)
                entity.components.set(CollisionComponent(shapes: [box], isStatic: true))
                var target = InputTargetComponent()
                target.isEnabled = takesInput && opacity > 0
                entity.components.set(target)
            }
            .frame(depth: 0, alignment: .front)
            .gesture(SpatialTapGesture().targetedToEntity(entity).onEnded { _ in onTap() })
        }
        .offset(z: RAVEVideoPlane.viewRecess)
    }
}
#endif
