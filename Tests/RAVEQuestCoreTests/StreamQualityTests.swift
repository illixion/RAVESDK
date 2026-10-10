import Foundation
import Testing
@testable import RAVEMediaCore

/// The quality ladder shared by the Apple players and the Quest app.
@Suite struct StreamQualityTests {
    @Test func stepsDownThroughFourteenFortyP() {
        #expect(LibraryStreamQuality.capped == [.mbps40, .mbps30, .mbps20, .mbps10, .mbps4, .mbps1_5])
        #expect(LibraryStreamQuality.mbps30.maxWidth == 2560 && LibraryStreamQuality.mbps30.maxHeight == 1440)
        // An 86 Mbps original steps to 4K first, a 35 Mbps one to 1440p.
        #expect(LibraryStreamQuality.stepDown(from: nil, sourceBitrate: 86_000_000) == .mbps40)
        #expect(LibraryStreamQuality.stepDown(from: nil, sourceBitrate: 35_000_000) == .mbps30)
        #expect(LibraryStreamQuality.stepDown(from: .mbps40, sourceBitrate: nil) == .mbps30)
        #expect(LibraryStreamQuality.stepDown(from: .mbps30, sourceBitrate: nil) == .mbps20)
    }

    @Test func aSmallerPictureForThreeD() {
        // A 4K original or 4K stream: 1440p; 1440p: 1080p.
        #expect(LibraryStreamQuality.smallerPicture(than: 2160, from: nil) == .mbps30)
        #expect(LibraryStreamQuality.smallerPicture(than: 2160, from: .mbps40) == .mbps30)
        #expect(LibraryStreamQuality.smallerPicture(than: 1440, from: .mbps30) == .mbps20)
        // Never above what is playing: a 4K picture at a 10 Mbps cap goes to 720p, not up to 1440p.
        #expect(LibraryStreamQuality.smallerPicture(than: 2160, from: .mbps10) == .mbps4)
        #expect(LibraryStreamQuality.smallerPicture(than: 480, from: nil) == nil)
    }

    @Test func readsTheLevelBackOffTheURL() throws {
        let url = try #require(URL(string: "http://h/Videos/1/master.m3u8?MaxStreamingBitrate=30000000"))
        #expect(LibraryStreamQuality.level(ofStream: url) == .mbps30)
    }
}
