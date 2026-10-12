/*
 RAVERoboFrame - wire models

 The values RoboFrame's server sends and the slideshow config a session joins
 with, typed. The protocol itself is documented in RoboFrame's
 `docs/protocol.md`; field names here follow it exactly, and a change there is
 a change here.
 */

import Foundation

/// A post as `playback` frames and `/history.json` announce it: id and file
/// extension, plus the indexed clip length for a video.
public struct RoboFramePost: Identifiable, Hashable, Sendable, Codable {
    public let id: Int
    public let ext: String
    /// The library's indexed clip length, absent for images and for a video
    /// the library indexed as 0.
    public let durationMs: Int?

    public init(id: Int, ext: String, durationMs: Int? = nil) {
        self.id = id
        self.ext = ext
        self.durationMs = durationMs
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        ext = try values.decodeIfPresent(String.self, forKey: .ext) ?? ""
        let duration = try values.decodeIfPresent(RoboFrameNumber.self, forKey: .durationMs)?.int
        durationMs = duration.flatMap { $0 > 0 ? $0 : nil }
    }

    /// The server's video containers (`packages/shared/src/mediaTypes.js`).
    public static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "3gp"]
    /// ISO BMFF containers, which AVPlayer opens directly. The rest play
    /// through one of the server's transcodes (`vcodec=hls` or `h264`).
    public static let isoMediaExtensions: Set<String> = ["mp4", "m4v", "mov", "3gp"]

    public var isVideo: Bool { Self.videoExtensions.contains(ext.lowercased()) }
    public var isISOMedia: Bool { Self.isoMediaExtensions.contains(ext.lowercased()) }
}

/// A channel's playback state, from a `playback` frame. Optional fields are
/// the ones a frame may leave out; a client keeps its previous value then.
public struct RoboFramePlayback: Equatable, Sendable {
    public var deviceId: String?
    /// The deviceId holding the displaySync claim, or nil when no merge is active.
    public var mergeDriver: String?
    /// Dwell time in seconds. Nil when the frame carried none (or a non-positive one).
    public var interval: TimeInterval?
    /// Index of the channel's active tag list.
    public var currentList: Int?
    public var modTags: [String]?
    public var current: RoboFramePost?
    public var next: RoboFramePost?
    /// The server's whole look-ahead, `next` usually first.
    public var upcoming: [RoboFramePost]

    public init(
        deviceId: String? = nil,
        mergeDriver: String? = nil,
        interval: TimeInterval? = nil,
        currentList: Int? = nil,
        modTags: [String]? = nil,
        current: RoboFramePost? = nil,
        next: RoboFramePost? = nil,
        upcoming: [RoboFramePost] = []
    ) {
        self.deviceId = deviceId
        self.mergeDriver = mergeDriver
        self.interval = interval
        self.currentList = currentList
        self.modTags = modTags
        self.current = current
        self.next = next
        self.upcoming = upcoming
    }
}

/// A Home Assistant sensor reading forwarded by the server (`update`).
public struct RoboFrameSensorReading: Identifiable, Equatable, Sendable {
    public let entityId: String
    public var state: String
    public var friendlyName: String
    public var unit: String
    /// HA reported `unavailable`; `state` keeps the last real value.
    public var isUnavailable: Bool

    public var id: String { entityId }

    public init(entityId: String, state: String, friendlyName: String, unit: String, isUnavailable: Bool = false) {
        self.entityId = entityId
        self.state = state
        self.friendlyName = friendlyName
        self.unit = unit
        self.isUnavailable = isUnavailable
    }
}

/// A `showText` effect: a full-screen message, optionally with an image.
public struct RoboFrameAlert: Equatable, Sendable {
    public let text: String
    public let backgroundHex: String
    public let imageURL: URL?

    public init(text: String, backgroundHex: String = "#000000", imageURL: URL? = nil) {
        self.text = text
        self.backgroundHex = backgroundHex
        self.imageURL = imageURL
    }
}

/// A `playScene` effect: one live stream, offered per transport. A client
/// plays whichever it can and drops the frame when it can play neither.
public struct RoboFrameScene: Equatable, Sendable {
    public let streamId: String?
    public let rtsp: URL?
    public let whep: URL?

    public init(streamId: String?, rtsp: URL?, whep: URL?) {
        self.streamId = streamId
        self.rtsp = rtsp
        self.whep = whep
    }
}

/// Everything a session hears from the server. `playback` reaches only the
/// sessions it addresses; the rest go to every session on the connection.
public enum RoboFrameMessage: Equatable, Sendable {
    case playback(RoboFramePlayback)
    case tagLists([[String]])
    case currentTagList(Int)
    case sensor(RoboFrameSensorReading)
    case alert(RoboFrameAlert)
    case dismissAlert
    case playVideo(URL)
    case stopVideo
    case playScene(RoboFrameScene)
    case stopScene
    case playAudio(URL)
    case stopAudio
    /// Reload: drop warm caches and follow the server's next frame. Not "advance".
    case refresh
    /// A refill found no posts for this non-empty query; the slideshow stays put.
    case searchEmpty(query: String)
    /// Panel power for `target`. Frames without a `state` never arrive here.
    case displayState(target: String, on: Bool)
    case brightness(target: String, value: Int)
    /// The wake suppressor for `target`: while on, ambient wake (PIR) is ignored.
    case suppress(target: String, on: Bool)
    /// The last client reporting `target` went away.
    case displayDisconnect(target: String)
    /// The connection stopped for good (the server rejected the token);
    /// reconnects stay halted until a new connection is made.
    case halted(reason: String)
}

/// What a session joins its channel with. Send it on every (re)connect.
public struct RoboFrameSlideshowConfig: Equatable, Sendable {
    public var deviceId: String
    /// Dwell time in milliseconds; the server clamps it to 2 s – 1 h.
    public var intervalMs: Int
    public var modTags: [String]
    /// The display's aspect ratio (width/height); the server picks posts within ±15 %.
    public var ratio: Double?
    /// The variant fingerprint. These must match the `/get` parameters this
    /// session fetches with, or the server's pre-conversion makes the wrong
    /// variant. Leave width/height nil to fetch at source resolution.
    public var width: Int?
    public var height: Int?
    public var bright: Bool
    public var convert: Bool
    public var lowmem: Bool
    public var gif: Bool

    public init(
        deviceId: String,
        intervalMs: Int,
        modTags: [String] = [],
        ratio: Double? = nil,
        width: Int? = nil,
        height: Int? = nil,
        bright: Bool = false,
        convert: Bool = false,
        lowmem: Bool = false,
        gif: Bool = false
    ) {
        self.deviceId = deviceId
        self.intervalMs = intervalMs
        self.modTags = modTags
        self.ratio = ratio
        self.width = width
        self.height = height
        self.bright = bright
        self.convert = convert
        self.lowmem = lowmem
        self.gif = gif
    }
}

/// A JSON number the server may write as an integer or a float.
struct RoboFrameNumber: Decodable {
    let int: Int

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let int = try? value.decode(Int.self) {
            self.int = int
        } else {
            let double = try value.decode(Double.self)
            guard double.isFinite else {
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "non-finite number")
            }
            self.int = Int(double.rounded())
        }
    }
}
