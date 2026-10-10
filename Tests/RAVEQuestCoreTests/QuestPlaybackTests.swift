import Foundation
import Testing
import RAVEMediaCore
@testable import RAVEQuestCore

/// The `playback` operation as the Quest app sees it: a JSON command through
/// `rave_quest_call`, a JSON plan back. Jellyfin is a `URLProtocol` stub that
/// answers only for `StubJellyfin.host`, so no request ever leaves the process
/// and other suites' `URLSession.shared` traffic is untouched.
///
/// Serialized because the stub's routes and request log are process-wide.
@Suite("Quest core playback plans", .serialized)
struct QuestPlaybackTests {
    static let server = "http://\(StubJellyfin.host):8096"
    static let user = "user1"
    static let item = "abc123"
    static let mp4Containers = "mov,mp4,m4a,3gp,3g2,mj2"

    init() { StubJellyfin.install() }

    // MARK: - Spatial video through the plugin

    @Test(arguments: [mp4Containers, "MOV"])
    func spatialHEVCPlaysThePluginStream(container: String) async throws {
        StubJellyfin.reset(item: Self.itemJSON(codec: "hevc", container: container, positionTicks: 1_234_000_000),
                           spatial: .json(Self.spatialJSON(format: nil)))
        let plan = try await Self.playback()

        #expect(plan["spatialVideo"] as? Bool == true)
        #expect(plan["url"] as? String == "\(Self.server)/Spatial/\(Self.item)/main.m3u8")
        #expect(plan["stereo"] as? String == "FullSideBySide")
        #expect(plan["width"] as? Int == 3840)
        #expect(plan["height"] as? Int == 1080)
        #expect(plan["bitrate"] as? Int == 25_000_000)
        #expect(plan["codec"] as? String == "hevc")
        #expect(plan["sourceID"] as? String == "src1")
        #expect(plan["authorization"] as? String == "MediaBrowser Token=\"t\"")
        #expect(abs((plan["position"] as? Double ?? -1) - 123.4) < 1e-9)
        #expect(StubJellyfin.requestedPaths.contains("/Spatial/\(Self.item)"))
    }

    @Test func spatialFormatComesFromThePlugin() async throws {
        StubJellyfin.reset(item: Self.itemJSON(codec: "hevc", container: Self.mp4Containers),
                           spatial: .json(Self.spatialJSON(format: "HalfSideBySide")))
        let plan = try await Self.playback()
        #expect(plan["spatialVideo"] as? Bool == true)
        #expect(plan["stereo"] as? String == "HalfSideBySide")
    }

    @Test func spatialStreamWinsOverACappedQuality() async throws {
        StubJellyfin.reset(item: Self.itemJSON(codec: "hevc", container: Self.mp4Containers, bitrate: 60_000_000),
                           spatial: .json(Self.spatialJSON(format: nil)))
        let plan = try await Self.playback(extra: ["quality": "mbps10"])
        #expect(plan["spatialVideo"] as? Bool == true)
        #expect(plan["quality"] as? String == "mbps10")
        #expect((plan["url"] as? String)?.hasSuffix("/Spatial/\(Self.item)/main.m3u8") == true)
    }

    @Test func commandPositionOverridesTheResumePoint() async throws {
        StubJellyfin.reset(item: Self.itemJSON(codec: "hevc", container: "mp4", positionTicks: 1_234_000_000),
                           spatial: .json(Self.spatialJSON(format: nil)))
        let plan = try await Self.playback(extra: ["position": 5.5])
        #expect(plan["position"] as? Double == 5.5)
    }

    // MARK: - Fallbacks to the ordinary plan

    @Test func pluginMissingFallsBackToTheStaticStream() async throws {
        StubJellyfin.reset(item: Self.itemJSON(codec: "hevc", container: Self.mp4Containers, video3DFormat: "HalfOverUnder"),
                           spatial: .status(404))
        let plan = try await Self.playback()
        try Self.expectStaticPlan(plan)
        #expect(plan["stereo"] as? String == "HalfOverUnder")
        #expect(StubJellyfin.requestedPaths.contains("/Spatial/\(Self.item)"))
    }

    @Test func notSpatialFallsBackToTheStaticStream() async throws {
        StubJellyfin.reset(item: Self.itemJSON(codec: "hevc", container: Self.mp4Containers),
                           spatial: .json(#"{"spatial":false,"playlist":null}"#))
        let plan = try await Self.playback()
        try Self.expectStaticPlan(plan)
        #expect(plan["stereo"] as? String == "Mono")
        #expect(plan["width"] as? Int == 1920)
        #expect(plan["height"] as? Int == 1080)
    }

    @Test func spatialWithoutAPlaylistFallsBack() async throws {
        StubJellyfin.reset(item: Self.itemJSON(codec: "hevc", container: Self.mp4Containers),
                           spatial: .json(#"{"spatial":true}"#))
        try Self.expectStaticPlan(try await Self.playback())
    }

    @Test func malformedPluginReplyFallsBack() async throws {
        StubJellyfin.reset(item: Self.itemJSON(codec: "hevc", container: Self.mp4Containers),
                           spatial: .json("<html>not json</html>"))
        try Self.expectStaticPlan(try await Self.playback())
    }

    @Test(arguments: [("h264", "MOV"), ("hevc", "mkv"), ("hevc", "matroska,webm"), ("hevc", "")])
    func onlyHEVCInAnMP4FamilyAsksThePlugin(codec: String, container: String) async throws {
        StubJellyfin.reset(item: Self.itemJSON(codec: codec, container: container),
                           spatial: .json(Self.spatialJSON(format: nil)))
        let plan = try await Self.playback()
        try Self.expectStaticPlan(plan)
        #expect(plan["codec"] as? String == codec)
        #expect(!StubJellyfin.requestedPaths.contains { $0.hasPrefix("/Spatial/") })
    }

    @Test func cappedQualityOnANonSpatialItemTranscodes() async throws {
        // mbps10 caps a 60 Mbps source (LibraryStreamQuality.caps).
        #expect(LibraryStreamQuality.mbps10.caps(sourceBitrate: 60_000_000))
        StubJellyfin.reset(item: Self.itemJSON(codec: "hevc", container: Self.mp4Containers, bitrate: 60_000_000),
                           spatial: .status(404))
        let plan = try await Self.playback(extra: ["quality": "mbps10"])

        #expect(plan["spatialVideo"] == nil)
        #expect(plan["quality"] as? String == "mbps10")
        let urlText = try #require(plan["url"] as? String)
        let url = try #require(URLComponents(string: urlText))
        #expect(url.path == "/Videos/\(Self.item)/master.m3u8")
        let query = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["MaxStreamingBitrate"] == "10000000")
        #expect(query["MaxWidth"] == "1920")
        #expect(query["MaxHeight"] == "1080")
        #expect(query["VideoCodec"] == "h264")
        #expect(query["MediaSourceId"] == "src1")
        #expect(query["static"] == nil)
    }

    @Test func uncappingQualityKeepsTheStaticStream() async throws {
        // mbps40 is above a 25 Mbps source, so the original plays.
        StubJellyfin.reset(item: Self.itemJSON(codec: "h264", container: "mkv", bitrate: 25_000_000), spatial: .status(404))
        let plan = try await Self.playback(extra: ["quality": "mbps40"])
        try Self.expectStaticPlan(plan)
    }

    @Test func subtitleTracksAreListedOnTheOrdinaryPlan() async throws {
        let subtitles = #"""
        {"Type":"Subtitle","Index":2,"Codec":"subrip","Language":"eng","DisplayTitle":"English","IsForced":false},
        {"Type":"Subtitle","Index":3,"Codec":"PGSSUB","Language":"fre","IsForced":true}
        """#
        StubJellyfin.reset(item: Self.itemJSON(codec: "h264", container: "mkv", extraStreams: subtitles), spatial: .status(404))
        let plan = try await Self.playback()
        let tracks = try #require(plan["subtitles"] as? [[String: Any]])
        #expect(tracks.count == 2)
        #expect(tracks[0]["index"] as? Int == 2)
        #expect(tracks[0]["name"] as? String == "English")
        #expect(tracks[0]["playable"] as? Bool == true)
        #expect(tracks[1]["name"] as? String == "fre")
        #expect(tracks[1]["playable"] as? Bool == false)
        #expect(tracks[1]["forced"] as? Bool == true)
    }

    // MARK: - Errors

    @Test func itemWithoutMediaSourcesIsAnError() async throws {
        StubJellyfin.reset(item: #"{"Id":"abc123","Name":"Empty","MediaSources":[]}"#, spatial: .status(404))
        let reply = try await Self.playback()
        #expect(reply["errorCode"] as? String == "no_media_source")
    }

    @Test func serverErrorIsReportedWithItsStatus() async throws {
        StubJellyfin.reset(item: nil, spatial: .status(404))
        let reply = try await Self.playback()
        #expect(reply["errorCode"] as? String == "http_404")
    }

    @Test func invalidItemIDIsRejectedWithoutARequest() async throws {
        StubJellyfin.reset(item: nil, spatial: .status(404))
        let reply = try await Self.call(["operation": "playback", "server": Self.server,
                                         "userID": Self.user, "itemID": "../etc"])
        #expect(reply["errorCode"] as? String == "invalid_command")
        #expect(StubJellyfin.requestedPaths.isEmpty)
    }

    @Test func nonHTTPServerIsRejected() async throws {
        let reply = try await Self.call(["operation": "playback", "server": "file:///etc",
                                         "userID": Self.user, "itemID": Self.item])
        #expect(reply["errorCode"] as? String == "invalid_command")
    }

    @Test func unknownProtocolVersionIsRejected() async throws {
        let reply = try await Self.call(["operation": "playback", "protocolVersion": 2, "server": Self.server])
        #expect(reply["errorCode"] as? String == "invalid_command")
    }

    @Test func malformedCommandIsRejected() async throws {
        let text = await Self.rawCall("{not json")
        #expect(text == #"{"error":"Invalid core command."}"#)
    }

    @Test func healthNeedsNoServer() async throws {
        let reply = try await Self.call(["operation": "health"])
        #expect(reply["protocolVersion"] as? Int == 1)
        #expect(reply["core"] as? String == "Swift")
    }

    // MARK: - Helpers

    static func expectStaticPlan(_ plan: [String: Any], sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(plan["spatialVideo"] == nil, sourceLocation: sourceLocation)
        let urlText = try #require(plan["url"] as? String, sourceLocation: sourceLocation)
        let url = try #require(URLComponents(string: urlText), sourceLocation: sourceLocation)
        #expect(url.host == StubJellyfin.host, sourceLocation: sourceLocation)
        #expect(url.path == "/Videos/\(item)/stream", sourceLocation: sourceLocation)
        let query = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["static"] == "true", sourceLocation: sourceLocation)
        #expect(query["MediaSourceId"] == "src1", sourceLocation: sourceLocation)
        #expect(query["PlaySessionId"] == plan["playSessionID"] as? String, sourceLocation: sourceLocation)
        #expect(query["MaxStreamingBitrate"] == nil, sourceLocation: sourceLocation)
    }

    static func playback(extra: [String: Any] = [:]) async throws -> [String: Any] {
        var command: [String: Any] = ["operation": "playback", "server": server, "authorization": "MediaBrowser Token=\"t\"",
                                      "userID": user, "itemID": item]
        command.merge(extra) { _, new in new }
        let reply = try await call(command)
        #expect(StubJellyfin.requestedPaths.first == "/Users/\(user)/Items/\(item)" || reply["errorCode"] != nil)
        return reply
    }

    static func call(_ command: [String: Any]) async throws -> [String: Any] {
        let input = String(decoding: try JSONSerialization.data(withJSONObject: command), as: UTF8.self)
        let text = await rawCall(input)
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// `questCall` blocks its thread until the reply is ready, as JNI's worker
    /// thread does; run it off the cooperative pool so it can't starve the
    /// task that answers it.
    static func rawCall(_ input: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let reply = input.withCString { questCall($0) }
                let text = reply.map { String(cString: $0) } ?? ""
                questFree(reply)
                continuation.resume(returning: text)
            }
        }
    }

    static func itemJSON(codec: String, container: String, bitrate: Int = 25_000_000, video3DFormat: String? = nil,
                         positionTicks: Int64 = 0, extraStreams: String? = nil) -> String {
        let format = video3DFormat.map { #""Video3DFormat":"\#($0)","# } ?? ""
        let extra = extraStreams.map { ",\($0)" } ?? ""
        return #"""
        {"Id":"\#(item)","Name":"Spatial Test","RunTimeTicks":600000000,\#(format)
         "UserData":{"PlaybackPositionTicks":\#(positionTicks),"Played":false,"IsFavorite":false},
         "MediaSources":[{"Id":"src1","Container":"\#(container)","Bitrate":\#(bitrate),
           "MediaStreams":[{"Type":"Video","Index":0,"Codec":"\#(codec)","Width":1920,"Height":1080},
                           {"Type":"Audio","Index":1,"Codec":"aac"}\#(extra)]}]}
        """#
    }

    static func spatialJSON(format: String?) -> String {
        let formatField = format.map { #""video3DFormat":"\#($0)","# } ?? ""
        return #"{"spatial":true,"playlist":"Spatial/\#(item)/main.m3u8",\#(formatField)"width":3840,"height":1080,"bitsPerSecond":25000000}"#
    }
}

/// A Jellyfin server in a URLProtocol: answers `Users/{u}/Items/{id}` with the
/// configured item and `Spatial/{id}` with the configured plugin reply, 404s
/// everything else, and records every path it is asked for.
final class StubJellyfin: URLProtocol, @unchecked Sendable {
    static let host = "jellyfin.quest-tests.invalid"

    enum Reply: Sendable {
        case json(String)
        case status(Int)
    }

    private struct State {
        var item: String?
        var spatial: Reply = .status(404)
        var paths: [String] = []
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()
    nonisolated(unsafe) private static var installed = false

    static func install() {
        lock.withLock {
            guard !installed else { return }
            installed = true
            URLProtocol.registerClass(StubJellyfin.self)
        }
    }

    static func reset(item: String?, spatial: Reply) {
        lock.withLock { state = State(item: item, spatial: spatial) }
    }

    static var requestedPaths: [String] { lock.withLock { state.paths } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let path = url.path
        let reply: Reply = Self.lock.withLock {
            Self.state.paths.append(path)
            let parts = path.split(separator: "/").map(String.init)
            if parts.count == 4, parts[0] == "Users", parts[2] == "Items" {
                return Self.state.item.map(Reply.json) ?? .status(404)
            }
            if parts.count == 2, parts[0] == "Spatial" { return Self.state.spatial }
            return .status(404)
        }
        let status: Int, body: Data
        switch reply {
        case .json(let text): status = 200; body = Data(text.utf8)
        case .status(let code): status = code; body = Data()
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
