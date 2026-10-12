/*
 RAVERoboFrame - frame encoding and decoding

 Every frame is `{ "sessionId"?, "action", "payload"? }` going out and
 `{ "action", "sessionIds"?, "payload"? }` coming in. Decoding is Codable
 rather than JSONSerialization so a number decodes the same way on every
 platform (Linux's JSONSerialization bridges numbers differently), and a
 payload field of the wrong type drops that one frame, not the connection.
 */

import Foundation

/// A decoded server frame: the message, and the sessions a `playback` frame
/// addressed (empty for connection-wide frames).
public struct RoboFrameInbound: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case message(RoboFrameMessage)
        /// The server's liveness probe; answer with `pong`.
        case ping
        /// The answer to our keepalive ping.
        case pong
    }

    public let action: String
    public let kind: Kind?
    public let sessionIds: [String]
}

public enum RoboFrameFrames {

    // MARK: - Decoding

    /// Decode one inbound frame. Nil when the text isn't a frame at all; a
    /// frame whose action is unknown, or whose payload doesn't parse, comes
    /// back with a nil `kind`.
    public static func decode(_ text: String) -> RoboFrameInbound? {
        let data = Data(text.utf8)
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else { return nil }
        let kind = try? decodeKind(envelope.action, data, decoder)
        return RoboFrameInbound(action: envelope.action, kind: kind, sessionIds: envelope.sessionIds ?? [])
    }

    private struct Envelope: Decodable {
        let action: String
        let sessionIds: [String]?
    }

    private struct Payload<Value: Decodable>: Decodable {
        let payload: Value
    }

    private static func payload<Value: Decodable>(_ type: Value.Type, _ data: Data, _ decoder: JSONDecoder) throws -> Value {
        try decoder.decode(Payload<Value>.self, from: data).payload
    }

    private static func decodeKind(_ action: String, _ data: Data, _ decoder: JSONDecoder) throws -> RoboFrameInbound.Kind? {
        func message(_ message: RoboFrameMessage) -> RoboFrameInbound.Kind { .message(message) }
        switch action {
        case "ping": return .ping
        case "pong": return .pong
        case "playback":
            return message(.playback(try payload(PlaybackPayload.self, data, decoder).playback))
        case "tagLists":
            // Canonical [[String]]; a flat [String] of space-separated lists is still accepted.
            if let nested = try? payload([[String]].self, data, decoder) { return message(.tagLists(nested)) }
            let flat = try payload([String].self, data, decoder)
            return message(.tagLists(flat.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }))
        case "currentTagList":
            return message(.currentTagList(try payload(ListNumberPayload.self, data, decoder).listNumber))
        case "update":
            let update = try payload(UpdatePayload.self, data, decoder)
            return message(.sensor(RoboFrameSensorReading(
                entityId: update.entity,
                state: update.state,
                friendlyName: update.attributes?.friendlyName ?? update.entity,
                unit: update.attributes?.unit ?? "",
                isUnavailable: update.state == "unavailable"
            )))
        case "showText":
            let alert = try payload(ShowTextPayload.self, data, decoder)
            return message(.alert(RoboFrameAlert(
                text: alert.text,
                backgroundHex: alert.bgColorHex ?? "#000000",
                imageURL: alert.imageUrl.flatMap(URL.init(string:))
            )))
        case "dismissText": return message(.dismissAlert)
        case "playVideo":
            guard let url = URL(string: try payload(URLPayload.self, data, decoder).url) else { return nil }
            return message(.playVideo(url))
        case "stopVideo": return message(.stopVideo)
        case "playScene":
            let scene = try payload(ScenePayload.self, data, decoder)
            return message(.playScene(RoboFrameScene(
                streamId: scene.streamId,
                rtsp: scene.rtsp.flatMap(URL.init(string:)),
                whep: scene.whep.flatMap(URL.init(string:))
            )))
        case "stopScene": return message(.stopScene)
        case "playAudio":
            guard let url = URL(string: try payload(URLPayload.self, data, decoder).url) else { return nil }
            return message(.playAudio(url))
        case "stopAudio": return message(.stopAudio)
        case "refresh": return message(.refresh)
        case "searchEmpty":
            let query = (try? payload(QueryPayload.self, data, decoder).query) ?? ""
            return message(.searchEmpty(query: query))
        case "displayState":
            // A frame without a state must not toggle anything (it would
            // re-enable a panel PIR had turned off).
            let frame = try payload(SwitchPayload.self, data, decoder)
            guard let on = frame.state?.isOn else { return nil }
            return message(.displayState(target: frame.target, on: on))
        case "setSuppress":
            let frame = try payload(SwitchPayload.self, data, decoder)
            guard let on = frame.state?.isOn else { return nil }
            return message(.suppress(target: frame.target, on: on))
        case "setBrightness":
            let frame = try payload(BrightnessPayload.self, data, decoder)
            return message(.brightness(target: frame.target, value: frame.brightness.int))
        case "displayDisconnect":
            return message(.displayDisconnect(target: try payload(TargetPayload.self, data, decoder).target))
        default:
            return nil
        }
    }

    private struct PlaybackPayload: Decodable {
        let deviceId: String?
        let mergeDriver: String?
        let interval: RoboFrameNumber?
        let currentList: RoboFrameNumber?
        let modTags: [String]?
        let current: RoboFramePost?
        let next: RoboFramePost?
        let upcoming: [Lenient<RoboFramePost>]?

        var playback: RoboFramePlayback {
            RoboFramePlayback(
                deviceId: deviceId,
                mergeDriver: mergeDriver,
                interval: interval.flatMap { $0.int > 0 ? TimeInterval($0.int) / 1_000 : nil },
                currentList: currentList?.int,
                modTags: modTags,
                current: current,
                next: next,
                upcoming: upcoming?.compactMap(\.value) ?? []
            )
        }
    }

    /// One array element that is dropped, rather than failing the array,
    /// when it doesn't decode.
    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: any Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    private struct ListNumberPayload: Decodable { let listNumber: Int }
    private struct URLPayload: Decodable { let url: String }
    private struct QueryPayload: Decodable { let query: String }
    private struct TargetPayload: Decodable { let target: String }

    private struct UpdatePayload: Decodable {
        struct Attributes: Decodable {
            let friendlyName: String?
            let unit: String?
            enum CodingKeys: String, CodingKey {
                case friendlyName = "friendly_name"
                case unit = "unit_of_measurement"
            }
        }
        let entity: String
        let state: String
        let attributes: Attributes?
    }

    private struct ShowTextPayload: Decodable {
        let text: String
        let bgColorHex: String?
        let imageUrl: String?
    }

    private struct ScenePayload: Decodable {
        let streamId: String?
        let rtsp: String?
        let whep: String?
    }

    /// `"on"`/`"off"` (HA's spelling) or a boolean.
    private enum SwitchState: Decodable {
        case string(String)
        case bool(Bool)

        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let bool = try? value.decode(Bool.self) {
                self = .bool(bool)
            } else {
                self = .string(try value.decode(String.self))
            }
        }

        var isOn: Bool {
            switch self {
            case .bool(let on): on
            case .string(let state): state != "off"
            }
        }
    }

    private struct SwitchPayload: Decodable {
        let target: String
        let state: SwitchState?
    }

    private struct BrightnessPayload: Decodable {
        let target: String
        let brightness: RoboFrameNumber
    }

    // MARK: - Encoding

    /// Actions the server resolves through the sender's session, so their
    /// frames carry `sessionId`.
    static let sessionScopedActions: Set<String> = [
        "slideshowConfig", "imageReady", "present", "requestNext", "reshuffle",
        "setModTags", "setTagList", "displaySync", "sessionEnd",
    ]

    /// One outbound frame as JSON text. `sessionId` is attached only to
    /// session-scoped actions.
    public static func encode(action: String, sessionId: String? = nil, payload: [String: Any]? = nil) -> String? {
        var frame: [String: Any] = ["action": action]
        if let sessionId, sessionScopedActions.contains(action) { frame["sessionId"] = sessionId }
        if let payload { frame["payload"] = payload }
        guard JSONSerialization.isValidJSONObject(frame),
              let data = try? JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `slideshowConfig`'s payload. Unset fields are omitted, which the
    /// server reads as false / source resolution.
    public static func slideshowConfigPayload(_ config: RoboFrameSlideshowConfig) -> [String: Any] {
        var payload: [String: Any] = [
            "deviceId": config.deviceId,
            "interval": config.intervalMs,
            "modTags": config.modTags,
            "bright": config.bright,
        ]
        if let ratio = config.ratio, ratio.isFinite, ratio > 0 { payload["ratio"] = ratio }
        if let width = config.width, width > 0 { payload["width"] = width }
        if let height = config.height, height > 0 { payload["height"] = height }
        if config.convert { payload["convert"] = true }
        if config.lowmem { payload["lowmem"] = true }
        if config.gif { payload["gif"] = true }
        return payload
    }
}
