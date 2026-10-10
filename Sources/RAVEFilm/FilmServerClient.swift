/*
 Hypnos - the Atmos Objects plugin's endpoints

   GET /AtmosObjects/{itemId}/Video                 index (segment start times, range info, picture tiers)
   GET /AtmosObjects/{itemId}/Video/Init            init segment (?height= for a lower tier)
   GET /AtmosObjects/{itemId}/Video/Segments/{n}    one keyframe interval, in film time (?height= likewise)
   GET /AtmosObjects/{itemId}/Scene?startSeconds=T  Atmos layout (422: no objects)
   GET /AtmosObjects/{itemId}/Segments/{n}/Events   positions and gains for audio segment n
   GET /AtmosObjects/{itemId}/Segments/{n}/{g}      FLAC channel group g of audio segment n
   GET /AtmosObjects/{itemId}/Segments/{n}/Bundle   every channel of segment n, lossy (FilmAudioBundle); bitrate = average per channel, budget = cap on the whole segment

 A `FilmOfflineStore` stands in for the server when a film was downloaded to
 play offline: every request above is answered from the copy on the device.

 The sound is fetched as lossless FLAC groups or a compressed bundle per
 segment. `governor` ("Auto") picks which, segment by segment, from what the
 link has carried; otherwise `encoding` is used as given. A segment is
 fetched whole before it is decoded, so the streamer can fetch ahead of its
 decoded slots (`prefetchAudio`): a compressed segment is a tenth of its
 decoded size, which is how a flaky link gets minutes of lookahead rather
 than seconds.

 See JellyfinPlugin/README.md. Segments carry the film's own timestamps, so
 segment n's first frame presents at `segmentStarts[n]` in the same time base
 as the audio scene's `startSeconds`.
 */

import AVFoundation
import Foundation
import os

public struct FilmVideoIndex: Decodable, Sendable {
    public let segmentStarts: [Double]
    public let durationSeconds: Double
    public let codec: String
    public let videoRange: String
    public let dvProfile: Int?
    public let dolbyVision: Bool
    /// The lower picture tiers the plugin offers, by height, largest first
    /// (a 2160p film: [1440, 1080]). Each is HEVC cut on this same index, so
    /// segment n of every tier covers the same film time. Empty from a plugin
    /// older than tiers, and for a download, which holds the original only.
    public var pictureHeights: [Int]

    /// Dolby Vision profile 5: no HDR10 base, so only the system's renderer
    /// shows the original right. A 3D picture comes from a lower tier, which
    /// the plugin converts to HDR10 (it applies the RPU; the app never does).
    public var needsSystemRenderer: Bool {
        dvProfile == 5 || videoRange.caseInsensitiveCompare("DOVI") == .orderedSame
    }

    private enum CodingKeys: String, CodingKey {
        case segmentStarts, durationSeconds, codec, videoRange, dvProfile, dolbyVision, pictureHeights
    }

    public init(segmentStarts: [Double], durationSeconds: Double, codec: String, videoRange: String, dvProfile: Int?,
                dolbyVision: Bool, pictureHeights: [Int] = []) {
        self.segmentStarts = segmentStarts
        self.durationSeconds = durationSeconds
        self.codec = codec
        self.videoRange = videoRange
        self.dvProfile = dvProfile
        self.dolbyVision = dolbyVision
        self.pictureHeights = pictureHeights
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        segmentStarts = try container.decode([Double].self, forKey: .segmentStarts)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        codec = try container.decode(String.self, forKey: .codec)
        videoRange = try container.decode(String.self, forKey: .videoRange)
        dvProfile = try container.decodeIfPresent(Int.self, forKey: .dvProfile)
        dolbyVision = try container.decode(Bool.self, forKey: .dolbyVision)
        pictureHeights = try container.decodeIfPresent([Int].self, forKey: .pictureHeights) ?? []
    }

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

/// Answers the plugin's requests from a copy of a film kept on the device.
public protocol FilmOfflineStore: Sendable {
    /// The body `GET AtmosObjects/{itemID}/{path}?{query}` would return.
    /// Throws `FilmServerError.http` with the status the server would have
    /// sent for something the copy doesn't hold (404, or 422 for no objects).
    func data(path: String, query: [URLQueryItem]) async throws -> Data
}

public struct FilmServerClient: FilmStreamingAudioSource {
    public let baseURL: URL
    public let token: String
    public let itemID: String
    /// The audio track every audio request names; nil leaves the choice to
    /// the plugin (its default for `languages`).
    public var audioStream: Int?
    /// Set for a downloaded film: requests never reach the network.
    public let offline: (any FilmOfflineStore)?
    /// Lossless FLAC groups, or a compressed bundle per segment. A download
    /// holds the FLAC, and a plugin without bundles serves only FLAC, so
    /// both play lossless whatever this says.
    public var encoding: FilmAudioEncoding = .lossless
    /// When set, chooses each segment's encoding from what the link has
    /// carried ("Auto"), and `encoding` is not used.
    public var governor: FilmAudioGovernor?
    /// Audio requests, with a ceiling on the whole transfer: a link that
    /// takes a minute and a half over a segment is a failure to step down
    /// from, not a wait to sit through (a request can otherwise trickle on
    /// for as long as bytes keep coming). The plugin gives a segment it has
    /// yet to decode 45 s, which the ceiling clears, so a slow decode there
    /// is the server's 404 and not this timeout.
    var session: URLSession = FilmServerClient.audioSession
    /// Segments fetched ahead of the streamer's decode.
    private var fetched = FilmFetchedSegments()

    static let audioSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: configuration)
    }()

    /// How many bytes of segments may wait ahead of the streamer.
    static let prefetchBytes = 48 << 20

    /// Jellyfin's `Authorization` header with only the token. Jellyfin 12
    /// stopped reading the legacy `X-Emby-Token` header (401), and this form
    /// works on 10.11 too.
    static func authorization(_ token: String) -> String { "MediaBrowser Token=\"\(token)\"" }

    public init(baseURL: URL, token: String, itemID: String, audioStream: Int? = nil) {
        self.baseURL = baseURL
        self.token = token
        self.itemID = itemID
        self.audioStream = audioStream
        self.offline = nil
    }

    /// A client for a film downloaded to the device.
    public init(itemID: String, offline: any FilmOfflineStore, audioStream: Int? = nil) {
        self.baseURL = URL(fileURLWithPath: "/")
        self.token = ""
        self.itemID = itemID
        self.audioStream = audioStream
        self.offline = offline
    }

    public func with(audioStream: Int?) -> any FilmAudioSource {
        var copy = self
        copy.audioStream = audioStream
        // Another track's segments are not this one's.
        copy.fetched = FilmFetchedSegments()
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
        request.setValue(Self.authorization(token), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw FilmServerError.http(path: "Items", status: code) }
        return try JSONDecoder().decode(Page.self, from: data).items
    }

    /// The video index. A download's offers no lower tiers: it holds the
    /// original picture only.
    public func videoIndex() async throws -> FilmVideoIndex {
        var index = try JSONDecoder().decode(FilmVideoIndex.self, from: await get("Video"))
        if offline != nil { index.pictureHeights = [] }
        return index
    }

    /// The init segment of the original picture, or with `height` of that
    /// lower tier (one of the index's `pictureHeights`).
    public func videoInit(height: Int? = nil) async throws -> Data {
        try await get("Video/Init", query: videoQuery(height: height))
    }

    /// Segment `n` of the original picture, or with `height` of that tier.
    public func videoSegment(_ n: Int, height: Int? = nil) async throws -> Data {
        try await get("Video/Segments/\(n)", query: videoQuery(height: height))
    }

    /// The tier's query. Never sent offline: a download answers for the
    /// original only, which is what plays.
    func videoQuery(height: Int?) -> [URLQueryItem] {
        guard offline == nil, let height else { return [] }
        return [URLQueryItem(name: "height", value: String(height))]
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
        try await audioSegment(segment, of: scene, deadline: nil)
    }

    /// The encoding segments are fetched in for `scene`: the fixed choice, or
    /// with a governor the tier it has in use.
    public func effectiveEncoding(for scene: AtmosScene) -> FilmAudioEncoding {
        guard offline == nil else { return .lossless }
        let wanted = governor?.currentEncoding ?? encoding
        return supports(wanted, in: scene) ? wanted : .lossless
    }

    /// Whether the plugin can serve `encoding` for `scene` (an older one serves FLAC only).
    private func supports(_ encoding: FilmAudioEncoding, in scene: AtmosScene) -> Bool {
        guard let codec = encoding.bundleCodec else { return true }
        return scene.bundleCodecs?.contains(codec) == true
    }

    /// What the next segment is fetched as, and whom to tell how it went.
    private struct Delivery {
        var encoding: FilmAudioEncoding = .lossless
        var budget: Int?
        var plan: FilmAudioGovernor.Plan?
    }

    private func delivery(for scene: AtmosScene) -> Delivery {
        guard offline == nil else { return Delivery() }
        if let governor {
            let plan = governor.plan(for: scene)
            guard supports(plan.encoding, in: scene) else { return Delivery() }
            return Delivery(encoding: plan.encoding, budget: plan.budget, plan: plan)
        }
        return Delivery(encoding: supports(encoding, in: scene) ? encoding : .lossless)
    }

    /// A segment as it came off the network, before decoding.
    struct FetchedSegment: Sendable {
        let segment: Int
        let audioStream: Int?
        let encoding: FilmAudioEncoding
        let events: Data
        /// The FLAC of each group, or the one bundle.
        let parts: [Data]

        var bytes: Int { events.count + parts.reduce(0) { $0 + $1.count } }
    }

    public func audioSegment(_ segment: Int, of scene: AtmosScene, deadline: ContinuousClock.Instant?) async throws -> FilmAudioSegment {
        let held = fetched.take(segment) { held in
            // Whatever the governor chose at the time is fine to play; a
            // fixed choice is only met by what was fetched as it.
            held.audioStream == audioStream && (governor != nil || held.encoding == effectiveEncoding(for: scene))
        }
        let payload: FetchedSegment
        if let held {
            payload = held
        } else {
            payload = try await fetch(segment, of: scene)
        }
        return try await decode(payload, of: scene, deadline: deadline)
    }

    func fetch(_ segment: Int, of scene: AtmosScene) async throws -> FetchedSegment {
        let delivery = delivery(for: scene)
        let started = ContinuousClock.now
        do {
            let events: Data
            let parts: [Data]
            if let codec = delivery.encoding.bundleCodec, let bitrate = delivery.encoding.bitrate {
                var query = audioQuery + [
                    URLQueryItem(name: "codec", value: codec),
                    URLQueryItem(name: "bitrate", value: String(bitrate)),
                ]
                if let budget = delivery.budget { query.append(URLQueryItem(name: "budget", value: String(budget))) }
                async let eventsRequest = get("Segments/\(segment)/Events", query: audioQuery, audio: true)
                let bundle = try await get("Segments/\(segment)/Bundle", query: query, audio: true)
                events = try await eventsRequest
                parts = [bundle]
            } else {
                // Every group at once: one round trip's latency, not one per group.
                async let eventsRequest = get("Segments/\(segment)/Events", query: audioQuery, audio: true)
                parts = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                    for index in scene.groups.indices {
                        group.addTask { (index, try await self.get("Segments/\(segment)/\(index)", query: self.audioQuery, audio: true)) }
                    }
                    var byGroup: [Int: Data] = [:]
                    for try await (index, data) in group { byGroup[index] = data }
                    return scene.groups.indices.map { byGroup[$0] ?? Data() }
                }
                events = try await eventsRequest
            }
            let result = FetchedSegment(segment: segment, audioStream: audioStream, encoding: delivery.encoding, events: events, parts: parts)
            if let governor {
                let took = ContinuousClock.now - started
                let seconds = Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
                let plan = delivery.plan ?? FilmAudioGovernor.Plan(tier: .lossless, encoding: .lossless, budget: nil)
                governor.recordSegment(plan: plan, bytes: parts.reduce(0) { $0 + $1.count }, fetchSeconds: seconds, scene: scene)
            }
            return result
        } catch {
            // The link's fault (a timeout, a dropped connection), not the server's no.
            if error is URLError, !Task.isCancelled { governor?.recordFailure() }
            throw error
        }
    }

    /// Half the cores: the picture decodes, and the render threads run, on
    /// the rest.
    static var decodeWorkers: Int { max(1, ProcessInfo.processInfo.activeProcessorCount / 2) }

    private func decode(_ payload: FetchedSegment, of scene: AtmosScene, deadline: ContinuousClock.Instant?) async throws -> FilmAudioSegment {
        let events = try JSONDecoder().decode([AtmosScene.Event].self, from: payload.events)
        guard payload.encoding.bundleCodec != nil, let data = payload.parts.first else {
            return FilmAudioSegment(events: events, buffers: try payload.parts.map(Self.decodeFLAC))
        }
        let bundle = try FilmAudioBundle(data: data)
        guard bundle.channels.count == scene.elements.count else {
            throw FilmAudioBundle.ParseError.malformed("\(bundle.channels.count) channels for a \(scene.elements.count)-channel scene")
        }
        let decoded = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: bundle.decode(groups: scene.groups, deadline: deadline,
                                                             workers: Self.decodeWorkers))
            }
        }
        if decoded.failed > 0 { throw FilmAudioBundle.ParseError.malformed("\(decoded.failed) channel(s) failed to decode") }
        return FilmAudioSegment(events: events, buffers: decoded.buffers, droppedChannels: decoded.dropped,
                                omittedChannels: bundle.omittedChannels)
    }

    // MARK: Fetching ahead

    public func prefetchAudio(_ segments: [Int], of scene: AtmosScene) async -> Bool {
        guard offline == nil, fetched.bytes < Self.prefetchBytes,
              let next = segments.first(where: { !fetched.holds($0) }),
              let payload = try? await fetch(next, of: scene) else { return false }
        return fetched.put(payload, limit: Self.prefetchBytes)
    }

    public func discardPrefetchedAudio(outside range: ClosedRange<Int>) {
        fetched.discard(outside: range)
    }

    public func audioPlaybackStalled(of scene: AtmosScene) {
        governor?.recordStall(of: scene)
    }

    /// The tier now in use, for display: "Auto · AAC 64 kbps", "Lossless".
    public func qualitySummary(for scene: AtmosScene?) -> String {
        if let governor { return governor.summary }
        return (scene.map(effectiveEncoding(for:)) ?? encoding).summary
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

    private var audioQuery: [URLQueryItem] {
        audioStream.map { [URLQueryItem(name: "audioStream", value: String($0))] } ?? []
    }

    /// `audio` requests use the tight-timeout session; either kind feeds the
    /// governor what the link carried.
    private func get(_ path: String, query: [URLQueryItem] = [], audio: Bool = false) async throws -> Data {
        if let offline {
            return try await offline.data(path: path, query: query)
        }
        var request = URLRequest(url: requestURL(path, query: query))
        request.setValue(Self.authorization(token), forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        let timing = TransferTiming()
        let (data, response) = try await (audio ? session : URLSession.shared).data(for: request, delegate: timing)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw FilmServerError.http(path: path, status: code)
        }
        if let seconds = timing.seconds { governor?.recordTransfer(bytes: data.count, seconds: seconds) }
        return data
    }
}

extension FilmServerClient {
    /// The plugin URL for `path` under the item, with `query`.
    func requestURL(_ path: String, query: [URLQueryItem] = []) -> URL {
        var url = baseURL.appending(path: "AtmosObjects/\(itemID)/\(path)")
        if !query.isEmpty { url.append(queryItems: query) }
        return url
    }
}

/// How long a response took from its first byte to its last (not the wait
/// before it, which on a bundle is the server building it).
private final class TransferTiming: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let measured = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)

    var seconds: TimeInterval? { measured.withLock { $0 } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last,
              let start = transaction.responseStartDate, let end = transaction.responseEndDate else { return }
        measured.withLock { $0 = end.timeIntervalSince(start) }
    }
}

/// Segments fetched but not yet decoded, by index.
final class FilmFetchedSegments: @unchecked Sendable {
    private let held = OSAllocatedUnfairLock(initialState: [Int: FilmServerClient.FetchedSegment]())

    var bytes: Int { held.withLock { $0.values.reduce(0) { $0 + $1.bytes } } }

    func holds(_ segment: Int) -> Bool { held.withLock { $0[segment] != nil } }

    /// The held segment if `accepting` it; either way it leaves the store.
    func take(_ segment: Int, accepting: (FilmServerClient.FetchedSegment) -> Bool) -> FilmServerClient.FetchedSegment? {
        let taken = held.withLock { $0.removeValue(forKey: segment) }
        return taken.flatMap { accepting($0) ? $0 : nil }
    }

    func put(_ payload: FilmServerClient.FetchedSegment, limit: Int) -> Bool {
        held.withLock { held in
            guard held.values.reduce(0, { $0 + $1.bytes }) + payload.bytes <= limit else { return false }
            held[payload.segment] = payload
            return true
        }
    }

    func discard(outside range: ClosedRange<Int>) {
        held.withLock { held in held = held.filter { range.contains($0.key) } }
    }
}
