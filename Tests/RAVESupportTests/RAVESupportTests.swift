import Foundation
import CoreGraphics
import ImageIO
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

    @Test func depthStretchUsesTheSubjectsOwnRange() {
        // A Mirror-style row: the subject spans levels 80…104 of 255, the background is 0.
        let subject = (0..<100).map { UInt8(80 + $0 * 24 / 99) }
        let values = subject + [UInt8](repeating: 0, count: 50)
        let alpha = [UInt8](repeating: 255, count: 100) + [UInt8](repeating: 0, count: 50)
        let out = RAVESupportDepthRaster.stretched(values, alpha: alpha, width: 150, height: 1, grow: 4)
        let shown = out.prefix(100)
        #expect(shown.min()! <= 2 && shown.max()! >= 253)      // p2…p98 now spans the bytes
        #expect(zip(shown, shown.dropFirst()).allSatisfy { $0 <= $1 })   // order kept
        #expect(out[100..<104].allSatisfy { $0 == out[99] })    // the edge's depth grows past it
        #expect(out.suffix(46).allSatisfy { $0 == 0 })          // and beyond that it is far
    }

    @Test func outlineTakesTheSurfaceDepthNotItsOwn() {
        // An old capture's outline: faint pixels whose depth sank towards the far background.
        let values: [UInt8] = [100, 100, 120, 40, 10, 0]
        let alpha: [UInt8] = [255, 255, 255, 140, 30, 0]
        let out = RAVESupportDepthRaster.stretched(values, alpha: alpha, width: 6, height: 1, grow: 2)
        #expect(out[3] == out[2] && out[4] == out[2])            // outline holds the surface's depth
        #expect(out[5] == 0)                                     // past the grow distance: far
    }

    @Test func flatSubjectKeepsItsDepth() {
        let out = RAVESupportDepthRaster.stretched([90, 90, 90, 7], alpha: [255, 255, 255, 0], width: 4, height: 1, grow: 0)
        #expect(out == [90, 90, 90, 0])
    }

    @Test func alphaKeepsOrientation() throws {
        // 1×2 RGBA: top pixel opaque, bottom transparent.
        let provider = try #require(CGDataProvider(data: Data([255, 0, 0, 255, 0, 0, 0, 0]) as CFData))
        let image = try #require(CGImage(width: 1, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        #expect(RAVESupportDepthRaster.alpha(image) == [255, 0])
    }

    @Test func bundledArtworkStretchesToTheFullRange() throws {
        for pose in [RAVESupportPose.welcome, .nudge] {
            guard let colourURL = pose.url, let depthURL = pose.depthURL else { continue }
            let colour = try #require(CGImageSourceCreateWithURL(colourURL as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            let depth = try #require(CGImageSourceCreateWithURL(depthURL as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            let values = try #require(RAVESupportDepthRaster.samples(depth, width: colour.width, height: colour.height))
            let alpha = try #require(RAVESupportDepthRaster.alpha(colour))
            let shown = zip(RAVESupportDepthRaster.stretched(values, alpha: alpha, width: colour.width, height: colour.height), alpha).filter { $0.1 >= 250 }.map(\.0)
            #expect(Int(shown.max()!) - Int(shown.min()!) >= 240, "\(pose) relief still flat: \(shown.min()!)…\(shown.max()!) of \(shown.count), raw \(values.min()!)…\(values.max()!)")
        }
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
