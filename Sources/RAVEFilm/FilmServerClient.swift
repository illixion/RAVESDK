/*
 Hypnos - the Atmos Objects plugin's endpoints

   GET /AtmosObjects/{itemId}/Video                 index (segment start times, range info)
   GET /AtmosObjects/{itemId}/Video/Init            init segment
   GET /AtmosObjects/{itemId}/Video/Segments/{n}    one keyframe interval, in film time
   GET /AtmosObjects/{itemId}/Scene?startSeconds=T  Atmos layout (422: no objects)
   GET /AtmosObjects/{itemId}/Segments/{n}/Events   positions and gains for audio segment n
   GET /AtmosObjects/{itemId}/Segments/{n}/{g}      FLAC channel group g of audio segment n

 See JellyfinPlugin/README.md. Segments carry the film's own timestamps, so
 segment n's first frame presents at `segmentStarts[n]` in the same time base
 as the audio scene's `startSeconds`.
 */

import AVFoundation
import Foundation

public struct FilmVideoIndex: Decodable, Sendable {
    public let segmentStarts: [Double]
    public let durationSeconds: Double
    public let codec: String
    public let videoRange: String
    public let dvProfile: Int?
    public let dolbyVision: Bool

    /// The segment whose interval contains `seconds`.
    public func segment(containing seconds: Double) -> Int {
        var low = 0, high = segmentStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if segmentStarts[mid] <= seconds { low = mid } else { high = mid - 1 }
        }
        return max(0, low)
    }
}

public enum FilmServerError: Error, LocalizedError {
    case http(path: String, status: Int)

    public var errorDescription: String? {
        switch self {
        case .http(let path, let status): "\(path): HTTP \(status)"
        }
    }
}

/// A film or episode from a Jellyfin library search.
public struct FilmLibraryItem: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let productionYear: Int?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", productionYear = "ProductionYear"
    }

    /// A struct's synthesized memberwise init is internal, not public, so a
    /// client module that already knows which item to load (e.g. Hypnos's
    /// Library tab, which has its own id from `MediaServerLibrary` rather
    /// than one of this type's own `search` results) needs this to construct
    /// one directly instead of only ever decoding one from `search`.
    public init(id: String, name: String, productionYear: Int?) {
        self.id = id
        self.name = name
        self.productionYear = productionYear
    }
}

/// An object-audio track the plugin can decode (`GET AtmosObjects/{id}/Tracks`).
public struct FilmAudioTrack: Decodable, Identifiable, Hashable, Sendable {
    /// The stream index, which names the track in every audio request.
    public let index: Int
    public let codec: String
    /// ISO 639-2, as the file or disc labels it.
    public let language: String?
    public let title: String
    /// The plugin's pick for the languages the request listed.
    public let isDefault: Bool
    public var id: Int { index }

    public init(index: Int, codec: String, language: String?, title: String, isDefault: Bool) {
        self.index = index
        self.codec = codec
        self.language = language
        self.title = title
        self.isDefault = isDefault
    }
}

public struct FilmServerClient: FilmAudioSource {
    public let baseURL: URL
    public let token: String
    public let itemID: String
    /// The audio track every audio request names; nil leaves the choice to
    /// the plugin (its default for `languages`).
    public var audioStream: Int?

    public init(baseURL: URL, token: String, itemID: String, audioStream: Int? = nil) {
        self.baseURL = baseURL
        self.token = token
        self.itemID = itemID
        self.audioStream = audioStream
    }

    public func with(audioStream: Int?) -> any FilmAudioSource {
        var copy = self
        copy.audioStream = audioStream
        return copy
    }

    /// The device's languages, most preferred first, as ISO 639-2 codes:
    /// what the plugin picks a film's default audio track by.
    public static var deviceLanguages: [String] {
        var seen: [String] = []
        for identifier in Locale.preferredLanguages {
            guard let code = Locale(identifier: identifier).language.languageCode?.identifier(.alpha3),
                  !seen.contains(code) else { continue }
            seen.append(code)
        }
        return seen
    }

    /// Films and episodes whose name matches `term`.
    public static func search(baseURL: URL, token: String, term: String) async throws -> [FilmLibraryItem] {
        struct Page: Decodable {
            let items: [FilmLibraryItem]
            enum CodingKeys: String, CodingKey { case items = "Items" }
        }
        var url = baseURL.appending(path: "Items")
        url.append(queryItems: [
            URLQueryItem(name: "searchTerm", value: term),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Limit", value: "25"),
        ])
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw FilmServerError.http(path: "Items", status: code) }
        return try JSONDecoder().decode(Page.self, from: data).items
    }

    public func videoIndex() async throws -> FilmVideoIndex {
        try JSONDecoder().decode(FilmVideoIndex.self, from: await get("Video"))
    }

    public func videoInit() async throws -> Data {
        try await get("Video/Init")
    }

    public func videoSegment(_ n: Int) async throws -> Data {
        try await get("Video/Segments/\(n)")
    }

    /// The item's object-audio tracks, the default for `languages` marked.
    /// Empty from a plugin that predates track choice (it answers 404).
    public func audioTracks(languages: [String]) async throws -> [FilmAudioTrack] {
        do {
            let data = try await get("Tracks", query: [URLQueryItem(name: "languages", value: languages.joined(separator: ","))])
            return try JSONDecoder().decode([FilmAudioTrack].self, from: data)
        } catch FilmServerError.http(_, 404) {
            return []
        }
    }

    /// The Atmos scene layout, starting a server decode at `startSeconds` if
    /// nothing is cached. Nil when the item has no Atmos objects (HTTP 422).
    public func audioScene(startSeconds: Double) async throws -> AtmosScene? {
        do {
            let data = try await get("Scene", query: audioQuery + [URLQueryItem(name: "startSeconds", value: String(format: "%.3f", startSeconds))])
            return try JSONDecoder().decode(AtmosScene.self, from: data)
        } catch FilmServerError.http(_, 422) {
            return nil
        }
    }

    public func audioSegment(_ segment: Int, of scene: AtmosScene) async throws -> FilmAudioSegment {
        let events = try await audioEvents(segment: segment)
        var buffers: [AVAudioPCMBuffer] = []
        for index in scene.groups.indices {
            buffers.append(try Self.decodeFLAC(try await audioSegment(segment, group: index)))
        }
        return FilmAudioSegment(events: events, buffers: buffers)
    }

    /// AVAudioFile only reads from a URL, so the segment takes a trip through tmp.
    private static func decodeFLAC(_ data: Data) throws -> AVAudioPCMBuffer {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("atmos-\(UUID().uuidString).flac")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: buffer)
        return buffer
    }

    func audioEvents(segment: Int) async throws -> [AtmosScene.Event] {
        try JSONDecoder().decode([AtmosScene.Event].self, from: await get("Segments/\(segment)/Events", query: audioQuery))
    }

    func audioSegment(_ segment: Int, group: Int) async throws -> Data {
        try await get("Segments/\(segment)/\(group)", query: audioQuery)
    }

    private var audioQuery: [URLQueryItem] {
        audioStream.map { [URLQueryItem(name: "audioStream", value: String($0))] } ?? []
    }

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        var url = baseURL.appending(path: "AtmosObjects/\(itemID)/\(path)")
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw FilmServerError.http(path: path, status: code)
        }
        return data
    }
}
