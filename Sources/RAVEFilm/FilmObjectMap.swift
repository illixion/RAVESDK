/*
 Hypnos - where the film's Atmos objects are, drawn live

 A debugging view of `FilmPlayer`'s objects in the listener's room, as the
 stage places them. Moved here from the Hypnos app so the Apple TV bench
 (TVLab) draws the same thing.

 - `.top`: seen from above, the screen along the top edge, the listener the
   dot in the middle.
 - `.front`: seen from the listener's seat looking at the screen, left to
   right across and ear level to ceiling up, so overhead objects stand out
   from ones that only move around the floor plane.

 Each dot's colour follows its height (blue at ear level, red at the
 ceiling) and its size and opacity its level. `FilmObjectMapPanel` puts both
 views side by side with a count of what is overhead right now.
 */

import SwiftUI

// FilmPlayer's Synchronization.Atomic; the package floor stays at macOS 14.
@available(macOS 15.0, *)
public struct FilmObjectMap: View {
    public enum Projection: Sendable { case top, front }

    let player: FilmPlayer
    var projection: Projection

    public init(player: FilmPlayer, projection: Projection = .top) {
        self.player = player
        self.projection = projection
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            Canvas { context, size in draw(in: &context, size: size) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let halfWidth = CGFloat(player.roomHalfWidth)
        // Top: depth runs down the view. Front: height runs up it, from the
        // floor of the view (ear level) to the ceiling.
        let extent = projection == .top ? 2 * CGFloat(player.roomHalfDepth) : CGFloat(max(player.roomHeight, 0.5))
        let scale = min(size.width / (2 * halfWidth), size.height / extent) * 0.9
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let room = CGRect(x: centre.x - halfWidth * scale, y: centre.y - extent * scale / 2,
                          width: 2 * halfWidth * scale, height: extent * scale)
        context.fill(Path(roundedRect: room, cornerRadius: 8), with: .color(.black.opacity(0.45)))
        context.stroke(Path(roundedRect: room, cornerRadius: 8), with: .color(.gray.opacity(0.6)), lineWidth: 1)

        switch projection {
        case .top:
            var screen = Path()
            screen.move(to: CGPoint(x: room.minX + room.width * 0.2, y: room.minY))
            screen.addLine(to: CGPoint(x: room.maxX - room.width * 0.2, y: room.minY))
            context.stroke(screen, with: .color(.white), lineWidth: 4)
            context.fill(Path(ellipseIn: CGRect(x: centre.x - 5, y: centre.y - 5, width: 10, height: 10)), with: .color(.white))
        case .front:
            // The screen seen head-on, and the listener's head at the bottom.
            let screen = CGRect(x: room.minX + room.width * 0.2, y: room.maxY - room.height * 0.55,
                                width: room.width * 0.6, height: room.height * 0.5)
            context.stroke(Path(screen), with: .color(.white.opacity(0.5)), lineWidth: 2)
            context.fill(Path(ellipseIn: CGRect(x: centre.x - 6, y: room.maxY - 12, width: 12, height: 12)), with: .color(.white))
        }

        let frame = player.currentFrame
        for element in player.elements where !element.isBed {
            let p = player.state(of: element, frame: frame).pos
            let height = player.flattenHeights ? 0 : CGFloat(max(0, min(p.z, 1)))
            let point = switch projection {
            case .top: CGPoint(x: centre.x + CGFloat(p.x) * halfWidth * scale, y: centre.y - CGFloat(p.y) * extent / 2 * scale)
            case .front: CGPoint(x: centre.x + CGFloat(p.x) * halfWidth * scale, y: room.maxY - height * room.height)
            }
            let level = player.levels.indices.contains(element.channel) ? CGFloat(player.levels[element.channel]) : 0
            let radius = 4 + min(level * 60, 18)
            context.fill(
                Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius)),
                with: .color(Color(hue: 0.62 * (1 - height), saturation: 0.8, brightness: 1).opacity(0.35 + min(level * 8, 0.65)))
            )
        }
    }
}

/// Both projections side by side, with how many objects are overhead and
/// audible right now.
@available(macOS 15.0, *)
public struct FilmObjectMapPanel: View {
    let player: FilmPlayer

    public init(player: FilmPlayer) {
        self.player = player
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                FilmObjectMap(player: player, projection: .top)
                    .aspectRatio(CGFloat(player.roomHalfWidth / player.roomHalfDepth), contentMode: .fit)
                FilmObjectMap(player: player, projection: .front)
                    .aspectRatio(CGFloat(2 * player.roomHalfWidth / max(player.roomHeight, 0.5)), contentMode: .fit)
            }
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                Text(summary)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(12)
        .background(.black.opacity(0.35), in: .rect(cornerRadius: 12))
    }

    private var summary: String {
        let frame = player.currentFrame
        let objects = player.elements.filter { !$0.isBed }
        var overhead = 0, audible = 0
        for element in objects {
            let state = player.state(of: element, frame: frame)
            let level = player.levels.indices.contains(element.channel) ? player.levels[element.channel] : 0
            guard state.gainDB > -60, level > 0.001 else { continue }
            audible += 1
            if state.pos.z > 0.25 { overhead += 1 }
        }
        return "\(objects.count) objects · \(audible) sounding · \(overhead) overhead"
    }
}
