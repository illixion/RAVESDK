import AVFoundation
import Foundation
import os
import Testing
@testable import RAVEFilm

/// The plugin client's audio path against a stand-in server: what it asks
/// for under "Auto", what it keeps ahead of the decode, and what a failed
/// fetch does to the next one.
@Suite("Film server client", .serialized)
struct FilmServerClientTests {
    /// Answers every request from `handler` and logs it.
    final class StubServer: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> Data)?
        static let log = OSAllocatedUnfairLock(initialState: [URL]())

        static func reset(_ handler: @escaping @Sendable (URLRequest) throws -> Data) {
            self.handler = handler
            log.withLock { $0 = [] }
        }

        static var requests: [URL] { log.withLock { $0 } }
        static func count(containing part: String) -> Int { requests.filter { $0.absoluteString.contains(part) }.count }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.log.withLock { $0.append(request.url!) }
            do {
                let data = try Self.handler!(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        override func stopLoading() {}
    }

    static let rate = 48000, segmentFrames = 2 * 48000

    static let scene = AtmosScene(
        sampleRate: rate,
        elements: (0 ..< 4).map { AtmosScene.Element(id: $0, channel: $0, kind: "object", bedChannel: nil) },
        frameCount: 6 * segmentFrames, segmentFrames: segmentFrames, segmentCount: 6,
        groups: [[0, 1], [2, 3]], startSeconds: 0, bundleCodecs: ["aac"])

    static let events = Data(#"[{"id":0,"t":0,"ramp":0,"gain":0,"pos":[0,1,0]}]"#.utf8)

    /// One bundle, as the plugin would answer: a stream per channel, `silent` ones left out.
    static func bundleData(silent: Set<Int> = []) throws -> Data {
        let stream = try FilmAudioBundleTests.encodeAAC(FilmAudioBundleTests.signal(count: 4800 + segmentFrames, channel: 1))
        return FilmAudioBundleTests.bundle(frames: segmentFrames, preroll: 4800,
                                           streams: (0 ..< 4).map { silent.contains($0) ? nil : stream })
    }

    static func client(governor: FilmAudioGovernor? = nil) -> FilmServerClient {
        var client = FilmServerClient(baseURL: URL(string: "http://stub.invalid")!, token: "t", itemID: "film")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        client.session = URLSession(configuration: configuration)
        client.governor = governor
        return client
    }

    static func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    /// Answers events and bundles; anything else is a 404.
    static func serve(bundle: Data) -> @Sendable (URLRequest) throws -> Data {
        { request in
            let path = request.url!.path
            if path.hasSuffix("/Events") { return events }
            if path.hasSuffix("/Bundle") { return bundle }
            throw FilmServerError.http(path: path, status: 404)
        }
    }

    @Test func autoAsksForTheTierItChoseAndDecodesIt() async throws {
        StubServer.reset(Self.serve(bundle: try Self.bundleData()))
        let governor = FilmAudioGovernor(link: { .init(isExpensive: true) })
        let segment = try await Self.client(governor: governor).audioSegment(2, of: Self.scene)
        let bundleRequest = try #require(StubServer.requests.first { $0.path.hasSuffix("/Segments/2/Bundle") })
        #expect(Self.query(bundleRequest, "codec") == "aac")
        #expect(Self.query(bundleRequest, "bitrate") == "64000")
        #expect(Self.query(bundleRequest, "budget") == nil)
        #expect(segment.buffers.count == 2 && segment.omittedChannels == 0)
        #expect(segment.events.count == 1)
    }

    @Test func aLinkTooSlowForTheLowestTierSendsABudget() async throws {
        StubServer.reset(Self.serve(bundle: try Self.bundleData()))
        let governor = FilmAudioGovernor()
        // 4 channels need ~57 kbps even at 16 kbps each; 0.1 Mbps allows 40.
        governor.recordTransfer(bytes: 200_000, seconds: 16)
        _ = try await Self.client(governor: governor).audioSegment(0, of: Self.scene)
        let request = try #require(StubServer.requests.first { $0.path.hasSuffix("/Bundle") })
        #expect(Self.query(request, "bitrate") == "16000")
        #expect(Self.query(request, "budget") == "40000")
    }

    @Test func audibleChannelsTheServerLeftOutAreCounted() async throws {
        StubServer.reset(Self.serve(bundle: try Self.bundleData(silent: [1, 3])))
        let segment = try await Self.client(governor: FilmAudioGovernor()).audioSegment(0, of: Self.scene)
        #expect(segment.omittedChannels == 2)
        #expect(segment.droppedChannels == 0)
    }

    @Test func segmentsFetchedAheadAreDecodedWithoutAnotherRequest() async throws {
        StubServer.reset(Self.serve(bundle: try Self.bundleData()))
        let client = Self.client(governor: FilmAudioGovernor())
        #expect(await client.prefetchAudio([3, 4], of: Self.scene))
        #expect(await client.prefetchAudio([3, 4], of: Self.scene))
        #expect(StubServer.count(containing: "/Segments/3/Bundle") == 1 && StubServer.count(containing: "/Segments/4/Bundle") == 1)
        // Both held: nothing left to fetch of them.
        #expect(await client.prefetchAudio([3, 4], of: Self.scene) == false)
        let segment = try await client.audioSegment(3, of: Self.scene)
        #expect(segment.buffers.count == 2)
        #expect(StubServer.count(containing: "/Segments/3/Bundle") == 1, "decoded from the held bytes")
        // What the streamer has moved past is let go.
        client.discardPrefetchedAudio(outside: 5 ... 5)
        _ = try await client.audioSegment(4, of: Self.scene)
        #expect(StubServer.count(containing: "/Segments/4/Bundle") == 2, "fetched again: it was discarded")
    }

    @Test func aFixedChoiceIgnoresSegmentsFetchedAsSomethingElse() async throws {
        StubServer.reset(Self.serve(bundle: try Self.bundleData()))
        var client = Self.client()
        client.encoding = .aac(bitrate: 96000)
        #expect(await client.prefetchAudio([1], of: Self.scene))
        client.encoding = .aac(bitrate: 32000)
        _ = try await client.audioSegment(1, of: Self.scene)
        #expect(StubServer.count(containing: "/Segments/1/Bundle") == 2)
        #expect(StubServer.count(containing: "bitrate=32000") == 1)
    }

    @Test func aTimedOutFetchStepsTheNextOneDown() async throws {
        StubServer.reset { _ in throw URLError(.timedOut) }
        let governor = FilmAudioGovernor()
        let client = Self.client(governor: governor)
        #expect(governor.plan(for: Self.scene).tier == .kbps96)
        await #expect(throws: (any Error).self) { _ = try await client.audioSegment(0, of: Self.scene) }
        #expect(governor.plan(for: Self.scene).tier == .kbps64)
    }

    @Test func aServerRefusalIsNotTheLinksFault() async throws {
        StubServer.reset { request in throw FilmServerError.http(path: request.url!.path, status: 404) }
        let governor = FilmAudioGovernor()
        let client = Self.client(governor: governor)
        _ = governor.plan(for: Self.scene)
        await #expect(throws: (any Error).self) { _ = try await client.audioSegment(0, of: Self.scene) }
        #expect(governor.plan(for: Self.scene).tier == .kbps96)
    }

    @Test func aPluginWithoutBundlesStaysLossless() async throws {
        var scene = Self.scene
        scene = AtmosScene(sampleRate: scene.sampleRate, elements: scene.elements, frameCount: scene.frameCount,
                           segmentFrames: scene.segmentFrames, segmentCount: scene.segmentCount, groups: scene.groups,
                           startSeconds: 0, bundleCodecs: nil)
        let flac = try Self.flac(channels: 2)
        StubServer.reset { request in
            request.url!.path.hasSuffix("/Events") ? Self.events : flac
        }
        let client = Self.client(governor: FilmAudioGovernor())
        let segment = try await client.audioSegment(0, of: scene)
        #expect(segment.buffers.count == 2)
        #expect(StubServer.count(containing: "/Segments/0/0") == 1 && StubServer.count(containing: "/Segments/0/1") == 1)
        #expect(StubServer.count(containing: "/Bundle") == 0)
        #expect(client.effectiveEncoding(for: scene) == .lossless)
    }

    /// A short FLAC of `channels` channels of noise-free tone.
    static func flac(channels: Int) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("client-test-\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(rate), channels: AVAudioChannelCount(channels), interleaved: false)!
        let frames = 4800
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
            ], commonFormat: .pcmFormatInt16, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for ch in 0 ..< channels {
                for i in 0 ..< frames { buffer.int16ChannelData![ch][i] = Int16(1000 * sin(Double(i) * 0.05 * Double(ch + 1))) }
            }
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }
}
