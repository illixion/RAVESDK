/*
 RAVE SDK — where a film's audio comes from

 `FilmPlayer` plays its sound as an `AtmosScene`: elements (positioned
 objects and beds) whose PCM arrives in fixed-length segments, with
 position and gain events. The Atmos Objects plugin is one source
 (`FilmServerClient`: FLAC channel groups decoded from a TrueHD track on
 the server). Anything that can describe its sound that way can be one: a
 5.1 track becomes five objects pinned at the speaker positions plus an LFE
 bed, and plays through the same stage, clock and head tracking.
 */

import AVFoundation
import Foundation

/// One segment's sound: the events of every element, and the PCM of each of
/// the scene's channel groups (planar Float32, `scene.groups[i]` channels
/// in `buffers[i]`, `segmentFrames` long or shorter at the end).
public struct FilmAudioSegment: @unchecked Sendable {
    public var events: [AtmosScene.Event]
    public var buffers: [AVAudioPCMBuffer]

    public init(events: [AtmosScene.Event], buffers: [AVAudioPCMBuffer]) {
        self.events = events
        self.buffers = buffers
    }
}

public protocol FilmAudioSource: Sendable {
    /// Names the film, so a late answer for a previous one can be told apart.
    var itemID: String { get }
    /// The track every request is for; nil leaves the choice to the source.
    var audioStream: Int? { get }
    func with(audioStream: Int?) -> any FilmAudioSource
    /// The tracks a listener can choose, the default for `languages` (ISO
    /// 639-2, most preferred first) marked. Empty when there is no choice.
    func audioTracks(languages: [String]) async throws -> [FilmAudioTrack]
    /// The scene layout, preparing to play from `startSeconds` (film time).
    /// Nil when this film has no sound this source can play.
    func audioScene(startSeconds: Double) async throws -> AtmosScene?
    func audioSegment(_ segment: Int, of scene: AtmosScene) async throws -> FilmAudioSegment
}
