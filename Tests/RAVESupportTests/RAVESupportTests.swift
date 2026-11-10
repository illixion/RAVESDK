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

    @Test func defaultCopyNamesTheApp() {
        let c = RAVESupportConfig(appName: "Longwave", appID: "x")
        #expect(c.message.contains("Longwave"))
        #expect(c.sponsorURL.absoluteString == "https://github.com/sponsors/illixion")
    }

    @Test func missingArtworkIsNil() {
        for pose in RAVESupportPose.allCases { #expect(pose.url == nil || pose.url!.isFileURL) }
    }
}
