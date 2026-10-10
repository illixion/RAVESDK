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
    var protocolVersion: Int?
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
    var startIndex: Int?
    var limit: Int?
    var parentID: String?
    var itemType: String?
    var favorite: Bool?
    var played: Bool?
    var segments: [LibraryMediaSegment]?
    var currentTime: Double?
    var duration: Double?
    var controlsVisible: Bool?
}
private struct Item: Decodable, Sendable {
    let Id: String
    let Name: String?
    let RunTimeTicks: Int64?
    let Video3DFormat: String?
    let UserData: UserData?
    let MediaSources: [Source]?
    let itemType: String?
    let ParentId: String?
    let Overview: String?
    let ProductionYear: Int?
    let DateCreated: String?
    let SeriesName: String?
    let SeriesId: String?
    let ParentIndexNumber: Int?
    let IndexNumber: Int?
    let ImageTags: [String: String]?
    let CanDownload: Bool?
    let Chapters: [Chapter]?

    private enum CodingKeys: String, CodingKey {
        case Id, Name, RunTimeTicks, Video3DFormat, UserData, MediaSources
        case itemType = "Type"
        case ParentId, Overview, ProductionYear, DateCreated, SeriesName, SeriesId, ParentIndexNumber, IndexNumber, ImageTags, CanDownload, Chapters
    }
}
private struct UserData: Codable, Sendable {
    let PlaybackPositionTicks: Int64?
    let Played: Bool?
    let IsFavorite: Bool?
    let LastPlayedDate: String?
}
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
private struct Page: Decodable { let Items: [Item]; let TotalRecordCount: Int? }
private struct SegmentPage: Decodable { let Items: [Segment]? }
private struct Segment: Decodable {
    let `Type`: String
    let StartTicks: Int64?
    let EndTicks: Int64?
}
private struct Chapter: Decodable { let Name: String?; let StartPositionTicks: Int64? }
/// The Convolution plugin's answer for spatial video (GET Spatial/{id}).
private struct SpatialStream: Decodable {
    let spatial: Bool
    let playlist: String?
    let video3DFormat: String?
    let width: Int?
    let height: Int?
    let bitsPerSecond: Int?
}
private enum CoreFailure: Error { case invalidCommand, noSource, downloadsForbidden }

private func json(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}
private func itemJSON(_ item: Item) -> [String: Any] {
    ["id": item.Id, "name": item.Name ?? "Untitled",
     "position": Double(item.UserData?.PlaybackPositionTicks ?? 0) / 10_000_000,
     "duration": Double(item.RunTimeTicks ?? 0) / 10_000_000,
     "stereo": item.Video3DFormat ?? "Mono", "type": item.itemType ?? "Movie",
     "overview": item.Overview ?? "", "year": item.ProductionYear ?? 0,
     "dateCreated": item.DateCreated ?? "", "series": item.SeriesName ?? "",
     "seriesID": item.SeriesId ?? "", "season": item.ParentIndexNumber ?? 0, "episode": item.IndexNumber ?? 0,
     "played": item.UserData?.Played ?? false, "favorite": item.UserData?.IsFavorite ?? false,
     "lastPlayed": item.UserData?.LastPlayedDate ?? "",
     "canDownload": item.CanDownload ?? false,
     "parentID": item.ParentId ?? "",
     "hasPoster": item.ImageTags?["Primary"] != nil] as [String: Any]
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
        return try json(["protocolVersion": 1, "core": "Swift", "subtitleFormats": ["srt", "vtt"]])
    }
    guard c.protocolVersion == nil || c.protocolVersion == 1 else { throw CoreFailure.invalidCommand }
    if c.operation == "parseSubtitles" {
        return try subtitleJSON(c.text ?? "")
    }
    if c.operation == "skip" {
        let candidates = c.segments ?? []
        guard let segment = LibrarySegmentSkipPolicy.offered(at: c.currentTime ?? 0,
                                                             controlsVisible: c.controlsVisible ?? true,
                                                             in: candidates) else { return "{\"segment\":null}" }
        return try json(["segment": ["kind": segment.kind.rawValue,
                                      "title": segment.skipTitle,
                                      "target": LibrarySegmentSkipPolicy.target(for: segment, duration: c.duration ?? 0)]])
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
                     URLQueryItem(name: "Fields", value: "MediaSources,MediaStreams,Overview,ImageTags,DateCreated,ProductionYear,SeriesName,ParentId,ParentIndexNumber,IndexNumber,DatePlayed,CanDownload"),
                     URLQueryItem(name: "SortBy", value: "SortName"),
                     URLQueryItem(name: "StartIndex", value: String(max(0, c.startIndex ?? 0))),
                     URLQueryItem(name: "Limit", value: String(min(100, max(1, c.limit ?? 40))))]
        let page = try JSONDecoder().decode(Page.self, from: await client.data("Users/\(user)/Items", query: query))
        let start = max(0, c.startIndex ?? 0), count = page.Items.count
        let next: Any = count == 0 || start + count >= (page.TotalRecordCount ?? start + count) ? NSNull() : start + count
        return try json(["items": page.Items.map(itemJSON), "startIndex": start,
                         "totalCount": page.TotalRecordCount ?? (start + count),
                         "nextStartIndex": next] as [String: Any])
    case "home":
        let user = try id(c.userID)
        async let resumePage = client.data("Users/\(user)/Items/Resume", query: [URLQueryItem(name: "MediaTypes", value: "Video"), URLQueryItem(name: "Recursive", value: "true"), URLQueryItem(name: "Limit", value: "16")])
        async let nextPage = client.data("Shows/NextUp", query: [URLQueryItem(name: "userId", value: user), URLQueryItem(name: "Limit", value: "20")])
        async let watchedPage = client.data("Users/\(user)/Items", query: [URLQueryItem(name: "IncludeItemTypes", value: "Episode"), URLQueryItem(name: "Recursive", value: "true"), URLQueryItem(name: "Filters", value: "IsPlayed"), URLQueryItem(name: "SortBy", value: "DatePlayed"), URLQueryItem(name: "SortOrder", value: "Descending"), URLQueryItem(name: "Limit", value: "60")])
        async let recentMoviesPage = client.data("Users/\(user)/Items", query: [URLQueryItem(name: "IncludeItemTypes", value: "Movie"), URLQueryItem(name: "Recursive", value: "true"), URLQueryItem(name: "SortBy", value: "DateCreated"), URLQueryItem(name: "SortOrder", value: "Descending"), URLQueryItem(name: "Limit", value: "16")])
        async let recentShowsPage = client.data("Users/\(user)/Items", query: [URLQueryItem(name: "IncludeItemTypes", value: "Series"), URLQueryItem(name: "Recursive", value: "true"), URLQueryItem(name: "SortBy", value: "DateCreated"), URLQueryItem(name: "SortOrder", value: "Descending"), URLQueryItem(name: "Limit", value: "16")])
        let decoder = JSONDecoder()
        let resume = try decoder.decode(Page.self, from: await resumePage).Items
        let next = try decoder.decode(Page.self, from: await nextPage).Items
        let watched = (try? decoder.decode(Page.self, from: await watchedPage).Items) ?? []
        let movies = try decoder.decode(Page.self, from: await recentMoviesPage).Items
        let shows = try decoder.decode(Page.self, from: await recentShowsPage).Items
        func shelf(_ id: String, _ title: String, _ items: [Item]) -> [String: Any] {
            ["id": id, "title": title, "items": items.map(itemJSON)]
        }
        var shelves = [[String: Any]]()
        if !resume.isEmpty { shelves.append(shelf("continue", "Continue Watching", resume)) }
        let dateParser = ISO8601DateFormatter()
        func orderingEntry(_ item: Item, resume: Bool) -> LibraryUpNextEntry {
            LibraryUpNextEntry(id: item.Id, seriesID: item.SeriesId,
                               lastPlayedAt: item.UserData?.LastPlayedDate.flatMap(dateParser.date(from:)),
                               isResume: resume)
        }
        let orderedIDs = LibraryUpNextOrdering.orderedIDs(
            resume: resume.map { orderingEntry($0, resume: true) },
            nextUp: next.map { orderingEntry($0, resume: false) },
            watchedEpisodes: watched.map { orderingEntry($0, resume: false) })
        let nextByID = Dictionary((resume + next).map { ($0.Id, $0) }, uniquingKeysWith: { first, _ in first })
        let orderedNext = orderedIDs.compactMap { nextByID[$0] }
        if !orderedNext.isEmpty { shelves.append(shelf("up-next", "Up Next", orderedNext)) }
        if !movies.isEmpty { shelves.append(shelf("recent-movies", "Recently Added Movies", movies)) }
        if !shows.isEmpty { shelves.append(shelf("recent-shows", "Recently Added Shows", shows)) }
        return try json(["featured": (movies + shows).filter { $0.ImageTags?["Primary"] != nil }.prefix(6).map(itemJSON), "shelves": shelves])
    case "browse":
        let user = try id(c.userID)
        var query = [URLQueryItem(name: "Recursive", value: "true"),
                     URLQueryItem(name: "Fields", value: "MediaSources,MediaStreams,Overview,ImageTags,DateCreated,ProductionYear,SeriesName,ParentId,ParentIndexNumber,IndexNumber,DatePlayed,CanDownload"),
                     URLQueryItem(name: "SortBy", value: "SortName"),
                     URLQueryItem(name: "StartIndex", value: String(max(0, c.startIndex ?? 0))),
                     URLQueryItem(name: "Limit", value: String(min(100, max(1, c.limit ?? 40))))]
        if let type = c.itemType, ["Movie", "Series", "Season", "Episode", "BoxSet"].contains(type) { query.append(URLQueryItem(name: "IncludeItemTypes", value: type)) }
        if let parent = c.parentID { query.append(URLQueryItem(name: "ParentId", value: try id(parent))) }
        if let term = c.text?.trimmingCharacters(in: .whitespacesAndNewlines), !term.isEmpty { query.append(URLQueryItem(name: "searchTerm", value: term)) }
        let page = try JSONDecoder().decode(Page.self, from: await client.data("Users/\(user)/Items", query: query))
        let start = max(0, c.startIndex ?? 0), count = page.Items.count
        let next: Any = count == 0 || start + count >= (page.TotalRecordCount ?? start + count) ? NSNull() : start + count
        return try json(["items": page.Items.map(itemJSON), "startIndex": start,
                         "totalCount": page.TotalRecordCount ?? (start + count),
                         "nextStartIndex": next] as [String: Any])
    case "state":
        let user = try id(c.userID), item = try id(c.itemID)
        if let favorite = c.favorite {
            _ = try await client.data("Users/\(user)/FavoriteItems/\(item)", method: favorite ? "POST" : "DELETE")
        }
        if let played = c.played {
            _ = try await client.data("Users/\(user)/PlayedItems/\(item)", method: played ? "POST" : "DELETE")
        }
        return "{\"ok\":true}"
    case "offlineProgress":
        let user = try id(c.userID), item = try id(c.itemID)
        let seconds = c.position ?? 0
        guard seconds.isFinite, seconds >= 0, seconds < 1e9 else { throw CoreFailure.invalidCommand }
        let played = c.played ?? false
        var body: [String: Any] = ["PlaybackPositionTicks": Int64(seconds * 10_000_000), "Played": played]
        if played { body["LastPlayedDate"] = ISO8601DateFormatter().string(from: Date()) }
        do {
            _ = try await client.data("UserItems/\(item)/UserData", query: [URLQueryItem(name: "userId", value: user)],
                                      method: "POST", body: JSONSerialization.data(withJSONObject: body))
        } catch JellyfinHTTP.Failure.http(404) {
            _ = try await client.data("Users/\(user)/Items/\(item)/UserData", query: [URLQueryItem(name: "userId", value: user)],
                                      method: "POST", body: JSONSerialization.data(withJSONObject: body))
        }
        return "{\"ok\":true}"
    case "download":
        let user = try id(c.userID), itemID = try id(c.itemID)
        let item = try JSONDecoder().decode(Item.self, from: await client.data("Users/\(user)/Items/\(itemID)"))
        guard item.CanDownload == true else { throw CoreFailure.downloadsForbidden }
        let container = item.MediaSources?.first?.Container?.lowercased().filter { $0.isLetter || $0.isNumber } ?? "mkv"
        return try json(["url": client.request("Items/\(itemID)/Download").url!.absoluteString,
                         "fileName": "\(itemID).\(container)", "itemID": itemID])
    case "segments":
        let user = try id(c.userID), itemID = try id(c.itemID)
        let page = try? JSONDecoder().decode(SegmentPage.self, from: await client.data("MediaSegments/\(itemID)"))
        let served = page?.Items ?? []
        var segments = served.compactMap { segment -> LibraryMediaSegment? in
            guard let kind = LibraryMediaSegment.Kind.serverType(segment.Type),
                  let start = segment.StartTicks, let end = segment.EndTicks, end > start else { return nil }
            return LibraryMediaSegment(kind: kind, startSeconds: Double(start) / 10_000_000,
                                       endSeconds: Double(end) / 10_000_000)
        }
        if segments.isEmpty {
            let item = try JSONDecoder().decode(Item.self, from: await client.data("Users/\(user)/Items/\(itemID)"))
            let chapters = (item.Chapters ?? []).compactMap { chapter -> (LibraryMediaSegment.Kind, Int64)? in
                guard let name = chapter.Name, let start = chapter.StartPositionTicks,
                      let kind = LibraryMediaSegment.Kind.chapterName(name) else { return nil }
                return (kind, start)
            }.sorted { $0.1 < $1.1 }
            for (index, chapter) in chapters.enumerated() {
                let end = index + 1 < chapters.count ? chapters[index + 1].1 : (item.RunTimeTicks ?? 0)
                if end > chapter.1 {
                    segments.append(LibraryMediaSegment(kind: chapter.0,
                        startSeconds: Double(chapter.1) / 10_000_000, endSeconds: Double(end) / 10_000_000))
                }
            }
        }
        segments.sort { $0.startSeconds < $1.startSeconds }
        return try json(["segments": segments.map { segment in
            ["kind": segment.kind.rawValue, "startSeconds": segment.startSeconds,
             "endSeconds": segment.endSeconds] as [String: Any]
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
        // A spatial video (MV-HEVC, from a Vision Pro or iPhone) decodes here
        // as its left eye only. The plugin streams it side by side instead,
        // converting as it plays; whatever quality was asked for, that
        // stream is the only 3D one.
        if let spatial = await spatialStream(client, itemID: itemID, source: source, video: video) {
            return try json(["url": client.request(spatial.playlist!).url!.absoluteString, "authorization": c.authorization ?? "",
                             "name": item.Name ?? "Untitled", "sourceID": source.Id, "playSessionID": session,
                             "width": spatial.width ?? 3840, "height": spatial.height ?? 1920, "codec": "hevc",
                             "bitrate": spatial.bitsPerSecond ?? source.Bitrate ?? 0,
                             "stereo": spatial.video3DFormat ?? "FullSideBySide", "subtitles": [[String: Any]](),
                             "quality": quality.rawValue, "spatialVideo": true,
                             "position": c.position ?? Double(item.UserData?.PlaybackPositionTicks ?? 0) / 10_000_000])
        }
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
/// The plugin's side-by-side stream of a spatial video, when this is one and
/// the server has the plugin. Only HEVC in MOV/MP4 is asked about, and any
/// failure (no plugin, not spatial, a server that can't decode MV-HEVC) means
/// the item plays as it is.
private func spatialStream(_ client: JellyfinHTTP, itemID: String, source: Source, video: Stream?) async -> SpatialStream? {
    let containers = Set((source.Container ?? "").lowercased().split(separator: ",").map(String.init))
    guard video?.Codec?.lowercased() == "hevc", !containers.isDisjoint(with: ["mov", "mp4", "m4v"]),
          let data = try? await client.data("Spatial/\(itemID)", timeout: 40),
          let spatial = try? JSONDecoder().decode(SpatialStream.self, from: data),
          spatial.spatial, spatial.playlist != nil else { return nil }
    return spatial
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
            catch JellyfinHTTP.Failure.http(let status) {
                reply.text = (try? json(["protocolVersion": 1, "errorCode": "http_\(status)", "error": "Jellyfin HTTP \(status). Check the server or account permissions."])) ?? "{\"error\":\"Jellyfin request failed.\"}"
            }
            catch CoreFailure.invalidCommand { reply.text = "{\"protocolVersion\":1,\"errorCode\":\"invalid_command\",\"error\":\"The request is invalid.\"}" }
            catch CoreFailure.noSource { reply.text = "{\"protocolVersion\":1,\"errorCode\":\"no_media_source\",\"error\":\"Jellyfin did not provide a playable media source.\"}" }
            catch CoreFailure.downloadsForbidden { reply.text = "{\"protocolVersion\":1,\"errorCode\":\"download_not_allowed\",\"error\":\"This Jellyfin account or item does not allow downloading.\"}" }
            catch { reply.text = "{\"protocolVersion\":1,\"errorCode\":\"request_failed\",\"error\":\"Request failed. Check the server, sign-in and media format.\"}" }
            reply.ready.signal()
        }
        reply.ready.wait()
    } catch { reply.text = "{\"error\":\"Invalid core command.\"}" }
    return strdup(reply.text)
}
@_cdecl("rave_quest_free")
public func questFree(_ pointer: UnsafeMutablePointer<CChar>?) { free(pointer) }
