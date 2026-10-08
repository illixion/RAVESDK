import Foundation
import Dispatch
import RAVEMediaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Android)
import Android
#elseif os(Linux)
import Glibc
#else
import Darwin
#endif

// A small, versioned UTF-8 JSON boundary keeps JNI independent of Swift's ABI.
// Calls run on the Android worker executor, never on its UI or OpenXR thread.
private struct Command: Decodable, Sendable {
    let operation: String
    var server: String?
    var authorization: String?
    var userID: String?
    var itemID: String?
    var username: String?
    var password: String?
    var text: String?
    var quality: LibraryStreamQuality?
    var position: Double?
    var paused: Bool?
    var playSessionID: String?
    var sourceID: String?
    var trackIndex: Int?
    var waiting: Bool?
    var hasFrame: Bool?
    var sourceBitrate: Int?
}
private struct Item: Codable, Sendable {
    let Id: String
    let Name: String?
    let RunTimeTicks: Int64?
    let Video3DFormat: String?
    let UserData: UserData?
    let MediaSources: [Source]?
    let itemType: String?
    let Overview: String?
    let ProductionYear: Int?
    let DateCreated: String?
    let SeriesName: String?
    let ParentIndexNumber: Int?
    let IndexNumber: Int?
    let ImageTags: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case Id, Name, RunTimeTicks, Video3DFormat, UserData, MediaSources
        case itemType = "Type"
        case Overview, ProductionYear, DateCreated, SeriesName, ParentIndexNumber, IndexNumber, ImageTags
    }
}
private struct UserData: Codable, Sendable { let PlaybackPositionTicks: Int64? }
private struct Source: Codable, Sendable {
    let Id: String
    let Container: String?
    let Bitrate: Int?
    let MediaStreams: [Stream]?
}
private struct Stream: Codable, Sendable {
    let Index: Int?
    let Width: Int?
    let Height: Int?
    let Codec: String?
    let `Type`: String?
    let Language: String?
    let DisplayTitle: String?
    let IsDefault: Bool?
    let IsForced: Bool?
}
private struct Page: Decodable { let Items: [Item] }
private enum CoreFailure: Error { case invalidCommand, noSource }

private func json(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}
private actor StallDecisions {
    static let shared = StallDecisions()
    private struct State { var monitor = StreamStallMonitor(); let started = Date(); var lastStep = Date.distantPast }
    private var sessions: [String: State] = [:]
    func update(_ c: Command) -> LibraryStreamQuality? {
        let key = c.playSessionID ?? ""
        if c.operation == "stopped" { sessions.removeValue(forKey: key); return nil }
        if c.operation == "started" { sessions[key] = State(); return nil }
        var state = sessions[key] ?? State()
        let now = Date()
        if c.operation == "seekGrace" { state.monitor.restartGrace(at: now); sessions[key] = state; return nil }
        let stalled = state.monitor.update(waiting: c.waiting ?? false, at: now)
        let startup = !(c.hasFrame ?? false) && now.timeIntervalSince(state.started) >= StreamStallMonitor.startupTimeout
        if !(c.paused ?? false), now.timeIntervalSince(state.lastStep) >= StreamStallMonitor.settleTime, stalled || startup {
            state.lastStep = now
            state.monitor.noteStepped(at: now)
            sessions[key] = state
            return LibraryStreamQuality.stepDown(from: c.quality, sourceBitrate: c.sourceBitrate)
        }
        sessions[key] = state
        return nil
    }
}
private func execute(_ c: Command) async throws -> String {
    if c.operation == "health" {
        return try json(["version": 1, "core": "Swift", "subtitleFormats": ["srt", "vtt"]])
    }
    if c.operation == "parseSubtitles" {
        return try subtitleJSON(c.text ?? "")
    }
    if ["stall", "seekGrace"].contains(c.operation) {
        let next = await StallDecisions.shared.update(c)
        return try json(["next": next?.rawValue ?? ""])
    }
    guard let server = c.server, let url = URL(string: server),
          ["http", "https"].contains(url.scheme), url.host != nil else { throw CoreFailure.invalidCommand }
    let client = JellyfinHTTP(baseURL: url, authorization: c.authorization ?? "")
    func id(_ value: String?) throws -> String {
        guard let value, !value.isEmpty, value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            throw CoreFailure.invalidCommand
        }
        return value
    }
    switch c.operation {
    case "login":
        let body = try JSONSerialization.data(withJSONObject: ["Username": c.username ?? "", "Pw": c.password ?? ""])
        return String(decoding: try await client.data("Users/AuthenticateByName", method: "POST", body: body), as: UTF8.self)
    case "catalog":
        let user = try id(c.userID)
        let query = [URLQueryItem(name: "Recursive", value: "true"),
                     URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode"),
                     URLQueryItem(name: "Fields", value: "MediaSources,MediaStreams,Overview,ImageTags,DateCreated,ProductionYear,SeriesName,ParentIndexNumber,IndexNumber"),
                     URLQueryItem(name: "SortBy", value: "SortName"), URLQueryItem(name: "Limit", value: "100")]
        let page = try JSONDecoder().decode(Page.self, from: await client.data("Users/\(user)/Items", query: query))
        return try json(["items": page.Items.map { item in
            ["id": item.Id, "name": item.Name ?? "Untitled", "position": Double(item.UserData?.PlaybackPositionTicks ?? 0) / 10_000_000,
             "duration": Double(item.RunTimeTicks ?? 0) / 10_000_000, "stereo": item.Video3DFormat ?? "Mono",
             "type": item.itemType ?? "Movie", "overview": item.Overview ?? "", "year": item.ProductionYear ?? 0,
             "dateCreated": item.DateCreated ?? "", "series": item.SeriesName ?? "",
             "season": item.ParentIndexNumber ?? 0, "episode": item.IndexNumber ?? 0,
             "hasPoster": item.ImageTags?["Primary"] != nil] as [String: Any]
        }])
    case "playback":
        let user = try id(c.userID), itemID = try id(c.itemID)
        let item = try JSONDecoder().decode(Item.self, from: await client.data("Users/\(user)/Items/\(itemID)"))
        guard let source = item.MediaSources?.first else { throw CoreFailure.noSource }
        let video = source.MediaStreams?.first { $0.Type == "Video" }
        let quality = c.quality ?? .auto
        let session = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var query = [URLQueryItem(name: "MediaSourceId", value: source.Id),
                     URLQueryItem(name: "DeviceId", value: "convolution-quest"),
                     URLQueryItem(name: "PlaySessionId", value: session)]
        let path: String
        if quality.caps(sourceBitrate: source.Bitrate) {
            path = "Videos/\(itemID)/master.m3u8"
            query += [URLQueryItem(name: "VideoCodec", value: "h264"), URLQueryItem(name: "AudioCodec", value: "aac"),
                      URLQueryItem(name: "MaxStreamingBitrate", value: String(quality.maxBitrate!)),
                      URLQueryItem(name: "MaxWidth", value: String(quality.maxWidth!)),
                      URLQueryItem(name: "MaxHeight", value: String(quality.maxHeight!))]
        } else {
            path = "Videos/\(itemID)/stream"
            query.append(URLQueryItem(name: "static", value: "true"))
        }
        let stream = client.request(path, query: query).url!
        let subtitles = (source.MediaStreams ?? []).filter { $0.Type == "Subtitle" }.map { track -> [String: Any] in
            let playable = ["srt", "subrip", "vtt", "webvtt", "ass", "ssa", "mov_text", "tx3g"].contains(track.Codec ?? "")
            return ["index": track.Index ?? -1, "name": track.DisplayTitle ?? track.Language ?? "Subtitle", "playable": playable,
                    "forced": track.IsForced ?? false, "language": track.Language ?? ""]
        }
        return try json(["url": stream.absoluteString, "authorization": c.authorization ?? "", "name": item.Name ?? "Untitled",
                         "sourceID": source.Id, "playSessionID": session, "width": video?.Width ?? 1920, "height": video?.Height ?? 1080,
                         "codec": video?.Codec ?? "unknown", "bitrate": source.Bitrate ?? 0,
                         "stereo": item.Video3DFormat ?? "Mono", "subtitles": subtitles,
                         "quality": quality.rawValue,
                         "position": c.position ?? Double(item.UserData?.PlaybackPositionTicks ?? 0) / 10_000_000])
    case "subtitles":
        let item = try id(c.itemID), source = try id(c.sourceID)
        guard let index = c.trackIndex, index >= 0 else { throw CoreFailure.invalidCommand }
        let data = try await client.data("Videos/\(item)/\(source)/Subtitles/\(index)/Stream.vtt")
        return try subtitleJSON(String(decoding: data, as: UTF8.self))
    case "started", "progress", "stopped":
        _ = await StallDecisions.shared.update(c)
        let item = try id(c.itemID)
        let position = c.position ?? 0
        guard position.isFinite, position >= 0, position < 1e9 else { throw CoreFailure.invalidCommand }
        let body: [String: Any] = ["ItemId": item, "MediaSourceId": c.sourceID ?? item,
                                 "PlaySessionId": c.playSessionID ?? "", "PositionTicks": Int64(position * 10_000_000),
                                 "IsPaused": c.paused ?? false, "CanSeek": true, "PlayMethod": "DirectStream"]
        let path = c.operation == "started" ? "Sessions/Playing" : c.operation == "stopped" ? "Sessions/Playing/Stopped" : "Sessions/Playing/Progress"
        _ = try await client.data(path, method: "POST", body: JSONSerialization.data(withJSONObject: body))
        return "{\"ok\":true}"
    default: throw CoreFailure.invalidCommand
    }
}
private func subtitleJSON(_ text: String) throws -> String {
    let track = try RAVESubtitleTrack(text: text)
    return try json(["cues": track.cues.map { cue in
        ["start": cue.start, "end": cue.end, "text": cue.plainText, "top": cue.placement == .top] as [String: Any]
    }])
}

private final class Reply: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    // Written once before signal, read once after wait; the semaphore publishes it.
    var text = "{\"error\":\"Core request failed.\"}"
}

/// Caller owns the returned buffer and releases it with rave_quest_free.
@_cdecl("rave_quest_call")
public func questCall(_ input: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let input else { return nil }
    let reply = Reply()
    do {
        let command = try JSONDecoder().decode(Command.self, from: Data(String(cString: input).utf8))
        Task.detached {
            do { reply.text = try await execute(command) }
            catch JellyfinHTTP.Failure.http(let status) { reply.text = "{\"error\":\"Jellyfin HTTP \(status).\"}" }
            catch { reply.text = "{\"error\":\"Request failed. Check the server, sign-in and media format.\"}" }
            reply.ready.signal()
        }
        reply.ready.wait()
    } catch { reply.text = "{\"error\":\"Invalid core command.\"}" }
    return strdup(reply.text)
}
@_cdecl("rave_quest_free")
public func questFree(_ pointer: UnsafeMutablePointer<CChar>?) { free(pointer) }
