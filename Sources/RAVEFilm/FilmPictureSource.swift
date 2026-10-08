/*
 Hypnos - film pictures that arrive decoded

 `FilmVideoPlayer` normally feeds the plugin's compressed video segments to
 its display layer. A source the platform has no decoder for (MVC, the
 frame-packed 3D of Blu-ray discs) decodes on its own and hands over
 finished pictures instead: sample buffers holding a CVPixelBuffer, stamped
 in film time, which the display layer shows as they come due on the same
 host-clock timebase as the Atmos audio.
 */

import CoreMedia
import Foundation

/// One decoded picture.
public struct FilmPictureFrame: @unchecked Sendable {
    /// What the player's own display layer shows (the left eye of a stereo source).
    public var picture: CMSampleBuffer
    /// Both eyes in one frame, for the stereo tap (`FilmVideoPlayer.onSampleBuffer`);
    /// nil when the tap wasn't asked for, or the source is mono.
    public var stereo: CMSampleBuffer?

    public init(picture: CMSampleBuffer, stereo: CMSampleBuffer? = nil) {
        self.picture = picture
        self.stereo = stereo
    }
}

public protocol FilmPictureSource: AnyObject, Sendable {
    /// Film time of the end of the picture.
    var durationSeconds: Double { get }
    var frameRate: Double { get }
    /// What the source is, for the player's status line.
    var summary: String { get }
    /// Pictures from `filmTime` on, in presentation order: the first is the
    /// one showing at `filmTime`, so nothing before it needs hiding.
    /// Cancelling the consuming task ends the stream and the decoding behind
    /// it; a new call replaces any stream still running.
    /// - Parameter stereo: also produce `FilmPictureFrame.stereo`.
    func frames(from filmTime: Double, stereo: Bool) -> AsyncThrowingStream<FilmPictureFrame, Error>
}
