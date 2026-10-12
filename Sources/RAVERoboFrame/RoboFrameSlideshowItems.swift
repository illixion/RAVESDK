/*
 RAVERoboFrame - slideshow items

 RoboFrame posts as `RAVESlideshowEngine` items, for clients that drive the
 shared engine in its server-driven mode (NativeClient, the Linux kiosk):
 each `playback.current` becomes the engine's authoritative item, and the
 engine's transition is what the client reports in `imageReady`.
 */

import Foundation
import RAVESlideshowCore

extension RoboFramePost {
    public var slideshowItem: RAVESlideshowItem {
        RAVESlideshowItem(
            id: String(id),
            mediaKind: isVideo ? .video : .image,
            fileExtension: ext,
            duration: durationMs.map { Double($0) / 1_000 },
            metadata: ["postID": String(id)]
        )
    }

    public init?(slideshowItem: RAVESlideshowItem) {
        guard let id = Int(slideshowItem.metadata["postID"] ?? slideshowItem.id) else { return nil }
        self.init(id: id, ext: slideshowItem.fileExtension, durationMs: slideshowItem.duration.map { Int(($0 * 1_000).rounded()) })
    }
}
