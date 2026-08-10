/*
 RAVE SDK — the two custom hover effects, and the small shared value types
 that travel with the UI shell.

 Spatial Stash and Spatial Home carry these 2–4 diff lines apart. They are
 small enough that duplicating them looks harmless and large enough that the
 copies drifted anyway.
 */

// `CustomHoverEffect` is visionOS-only, so this whole file is.
#if os(visionOS)

import SwiftUI

/// Lifts a thumbnail toward the viewer on gaze focus: a subtle scale plus an
/// upward offset. The offset is what sells it as *lift* rather than zoom —
/// scale alone reads as the cell growing in place.
public struct RAVELiftHoverEffect: CustomHoverEffect {
    public let scale: CGFloat
    public let lift: CGFloat
    public let duration: TimeInterval

    public init(scale: CGFloat = 1.05, lift: CGFloat = 4, duration: TimeInterval = 0.2) {
        self.scale = scale
        self.lift = lift
        self.duration = duration
    }

    public func body(content: Content) -> some CustomHoverEffect {
        content.hoverEffect { effect, isActive, _ in
            effect.animation(.easeOut(duration: duration)) {
                $0.scaleEffect(
                    isActive ? CGSize(width: scale, height: scale) : CGSize(width: 1, height: 1),
                    anchor: .center
                )
                .offset(y: isActive ? -lift : 0)
            }
        }
    }
}

/// Scales a thumbnail on gaze focus, without the lift.
public struct RAVEScaleHoverEffect: CustomHoverEffect {
    public let scale: CGFloat
    public let duration: TimeInterval

    public init(scale: CGFloat = 1.08, duration: TimeInterval = 0.2) {
        self.scale = scale
        self.duration = duration
    }

    public func body(content: Content) -> some CustomHoverEffect {
        content.hoverEffect { effect, isActive, _ in
            effect.animation(.easeOut(duration: duration)) {
                $0.scaleEffect(
                    isActive ? CGSize(width: scale, height: scale) : CGSize(width: 1, height: 1),
                    anchor: .center
                )
            }
        }
    }
}

#endif
