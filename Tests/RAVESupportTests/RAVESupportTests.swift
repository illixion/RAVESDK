import Foundation
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
        #expect(c.nudgeTitle == "Enjoying this app?")
        #expect(c.nudgeMessage.contains("Longwave"))
        #expect(c.sponsorURL.absoluteString == "https://github.com/sponsors/illixion")
    }

    @Test func missingArtworkIsNil() {
        for pose in RAVESupportPose.allCases { #expect(pose.url == nil || pose.url!.isFileURL) }
    }
}
