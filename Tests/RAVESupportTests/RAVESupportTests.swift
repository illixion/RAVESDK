import Foundation
import CoreGraphics
import Testing
@testable import RAVESupport

@Suite struct RAVESupportTests {
    private func store(_ id: String) -> (RAVESupportStore, UserDefaults) {
        let d = UserDefaults(suiteName: "rave.support.tests.\(UUID().uuidString)")!
        return (RAVESupportStore(appID: id, defaults: d), d)
    }

    @Test func welcomeShowsOnce() {
        let (s, _) = store("a")
        #expect(!s.welcomeShown)
        s.markWelcomeShown()
        #expect(s.welcomeShown)
        s.reset()
        #expect(!s.welcomeShown)
    }

    @Test func appsKeepSeparateState() {
        let d = UserDefaults(suiteName: "rave.support.tests.\(UUID().uuidString)")!
        let a = RAVESupportStore(appID: "a", defaults: d), b = RAVESupportStore(appID: "b", defaults: d)
        a.markWelcomeShown()
        #expect(a.welcomeShown && !b.welcomeShown)
    }

    @Test func nudgeComesOnceAfterADay() {
        let d = UserDefaults(suiteName: "rave.support.tests.\(UUID().uuidString)")!
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 1_000_000)
        let s = RAVESupportStore(appID: "a", defaults: d, now: { clock })
        #expect(!s.nudgeDue())                       // welcome not shown yet
        s.markWelcomeShown()
        #expect(!s.nudgeDue())                       // same moment
        clock += RAVESupportStore.nudgeDelay - 1
        #expect(!s.nudgeDue())                       // one second short
        clock += 1
        #expect(s.nudgeDue())                        // exactly a day
        s.markNudgeShown()
        clock += 365 * 24 * 3600
        #expect(!s.nudgeDue())                       // never again
        #expect(s.nudgeShown)
    }

    @Test func welcomeFlagWithoutDateStartsTheClockNow() {
        let d = UserDefaults(suiteName: "rave.support.tests.\(UUID().uuidString)")!
        d.set(true, forKey: "rave.support.welcomeShown.a")   // set by an older build or a UI test
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 1_000_000)
        let s = RAVESupportStore(appID: "a", defaults: d, now: { clock })
        #expect(!s.nudgeDue())
        clock += RAVESupportStore.nudgeDelay
        #expect(s.nudgeDue())
    }

    @Test func defaultCopyNamesTheApp() {
        let c = RAVESupportConfig(appName: "Longwave", appID: "x")
        #expect(c.message.contains("Longwave"))
        #expect(c.nudgeTitle == "Thank you for staying")
        #expect(c.nudgeMessage.contains("Longwave"))
        #expect(c.nudgeMessage.contains("last reminder"))
        #expect(c.sponsorURL.absoluteString == "https://github.com/sponsors/illixion")
    }

    @Test func missingArtworkIsNil() {
        for pose in RAVESupportPose.allCases { #expect(pose.url == nil || pose.url!.isFileURL) }
    }

    @Test func depthSamplesKeepOrientationAndIgnoreRowPadding() throws {
        let provider = try #require(CGDataProvider(data: Data([0, 64, 9, 9, 128, 255, 9, 9]) as CFData))
        let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        #expect(RAVESupportDepthRaster.samples(image, width: 2, height: 2) == [0, 64, 128, 255])
        #expect(RAVESupportDepthRaster.samples(image, width: 3, height: 2) == nil)
    }

    @Test func colourImageCannotMasqueradeAsDepth() throws {
        let provider = try #require(CGDataProvider(data: Data([255, 0, 0, 255]) as CFData))
        let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        #expect(RAVESupportDepthRaster.samples(image, width: 1, height: 1) == nil)
    }
}
