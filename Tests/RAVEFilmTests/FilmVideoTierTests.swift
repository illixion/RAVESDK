import Foundation
import Testing
@testable import RAVEFilm

/// The picture tiers as the client sees them: what the index offers, what
/// a request for a tier asks the plugin, and that a download offers and
/// asks for nothing but the original.
@Suite("Film picture tiers")
struct FilmVideoTierTests {
    static let indexWithTiers = Data(#"""
    {"version":1,"segmentStarts":[0,1.001,2.5],"durationSeconds":3.2,"codec":"hevc","videoRange":"DOVIWithHDR10",
     "dvProfile":8,"dolbyVision":true,"pictureHeights":[1440,1080]}
    """#.utf8)
    static let indexBeforeTiers = Data(#"""
    {"version":1,"segmentStarts":[0,10.417],"durationSeconds":20.001,"codec":"h264","videoRange":"SDR","dvProfile":null,"dolbyVision":false}
    """#.utf8)

    @Test func indexDecodesTheTiersOnOffer() throws {
        let index = try JSONDecoder().decode(FilmVideoIndex.self, from: Self.indexWithTiers)
        #expect(index.pictureHeights == [1440, 1080])
        #expect(index.segmentStarts == [0, 1.001, 2.5])
        #expect(index.dvProfile == 8 && index.dolbyVision)
        #expect(index.segment(containing: 2.0) == 1)
    }

    @Test func anOlderPluginOffersNoTiers() throws {
        let index = try JSONDecoder().decode(FilmVideoIndex.self, from: Self.indexBeforeTiers)
        #expect(index.pictureHeights.isEmpty)
        #expect(index.dvProfile == nil && !index.dolbyVision)
    }

    @Test func aTierIsAskedForByHeight() {
        let client = FilmServerClient(baseURL: URL(string: "http://jellyfin.invalid/base")!, token: "t", itemID: "film")
        #expect(client.requestURL("Video/Init", query: client.videoQuery(height: 1080)).absoluteString
                == "http://jellyfin.invalid/base/AtmosObjects/film/Video/Init?height=1080")
        #expect(client.requestURL("Video/Segments/12", query: client.videoQuery(height: 1440)).absoluteString
                == "http://jellyfin.invalid/base/AtmosObjects/film/Video/Segments/12?height=1440")
        #expect(client.requestURL("Video/Segments/12", query: client.videoQuery(height: nil)).absoluteString
                == "http://jellyfin.invalid/base/AtmosObjects/film/Video/Segments/12", "the original carries no query")
    }

    /// A downloaded film's store, recording what it is asked.
    final class Store: FilmOfflineStore, @unchecked Sendable {
        let lock = NSLock()
        var asked: [(path: String, query: [URLQueryItem])] = []

        func data(path: String, query: [URLQueryItem]) async throws -> Data {
            lock.withLock { asked.append((path, query)) }
            if path == "Video" { return FilmVideoTierTests.indexWithTiers }
            return Data([0])
        }
    }

    @Test func aDownloadOffersAndAsksForTheOriginalOnly() async throws {
        let store = Store()
        let client = FilmServerClient(itemID: "film", offline: store)
        let index = try await client.videoIndex()
        #expect(index.pictureHeights.isEmpty, "the download holds the original picture only")
        _ = try await client.videoInit(height: 1080)
        _ = try await client.videoSegment(3, height: 1080)
        let asked = store.lock.withLock { store.asked }
        #expect(asked.map(\.path) == ["Video", "Video/Init", "Video/Segments/3"])
        #expect(asked.allSatisfy { $0.query.isEmpty })
    }
}
