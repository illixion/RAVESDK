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

/// What a player's Quality menu lists for a source.
@Suite struct OfferedStreamQualityTests {
    @Test func aTenEightyPFilmIsNotOfferedFourK() {
        // 1080p at 30 Mbps: no 4K or 1440p (they'd send the same 1080p), and
        // the 20 Mbps 1080p cap is a real choice below the source's bitrate.
        let offered = LibraryStreamQuality.offered(sourceWidth: 1920, sourceHeight: 1080, sourceBitrate: 30_000_000)
        #expect(offered == [.auto, .original, .mbps20, .mbps10, .mbps4, .mbps1_5])
    }

    @Test func aScopeFilmCountsByItsWidth() {
        // 1920×800 is a 1080p film, not a 720p one.
        #expect(LibraryStreamQuality.pictureClass(width: 1920, height: 800) == 1080)
        #expect(LibraryStreamQuality.pictureClass(width: 3840, height: 1600) == 2160)
        #expect(LibraryStreamQuality.pictureClass(width: 1080, height: 1920) == 1080)
        #expect(LibraryStreamQuality.pictureClass(width: 1280, height: 720) == 720)
        #expect(LibraryStreamQuality.pictureClass(width: 640, height: 360) == 360)
    }

    @Test func aLowBitrateSourceOffersOnlyWhatCapsIt() {
        // 1080p at 8 Mbps: neither 1080p cap would change anything.
        let offered = LibraryStreamQuality.offered(sourceWidth: 1920, sourceHeight: 1080, sourceBitrate: 8_000_000)
        #expect(offered == [.auto, .original, .mbps4, .mbps1_5])
    }

    @Test func aFourKRemuxOffersEveryLevel() {
        let offered = LibraryStreamQuality.offered(sourceWidth: 3840, sourceHeight: 2160, sourceBitrate: 60_000_000)
        #expect(offered == [.auto, .original] + LibraryStreamQuality.capped)
    }

    @Test func anUnknownSourceOffersEveryLevel() {
        #expect(LibraryStreamQuality.offered(sourceWidth: nil, sourceHeight: nil, sourceBitrate: nil)
            == [.auto, .original] + LibraryStreamQuality.capped)
    }
}

/// The picture readout's frame rates.
@Suite struct VideoPictureFormatTests {
    @Test func measuredRatesReadAsTheStandardOnes() {
        #expect(VideoPictureFormat.rateLabel(23.9759) == "23.976")
        #expect(VideoPictureFormat.rateLabel(24.0004) == "24")
        #expect(VideoPictureFormat.rateLabel(29.97) == "29.97")
        #expect(VideoPictureFormat.rateLabel(59.95) == "59.94")
        #expect(VideoPictureFormat.rateLabel(60) == "60")
        #expect(VideoPictureFormat.rateLabel(15.5) == "15.5")
        #expect(VideoPictureFormat.rateLabel(0) == nil)
    }

    @Test func summaryNamesSizeAndRate() {
        #expect(VideoPictureFormat(width: 1920, height: 1080, framesPerSecond: 24000.0 / 1001).summary
            == "1920×1080 · 23.976 fps")
        #expect(VideoPictureFormat(width: 3840, height: 2160).summary == "3840×2160")
    }
}
