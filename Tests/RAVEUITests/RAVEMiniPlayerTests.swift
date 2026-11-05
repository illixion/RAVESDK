import Foundation
import Testing
@testable import RAVEUI

struct RAVEMiniPlayerLayoutTests {
    @Test func squareAndUnknownArtFillASquare() {
        #expect(RAVEMiniPlayerLayout.artworkHeight(aspectRatio: nil, width: 340) == 340)
        #expect(RAVEMiniPlayerLayout.artworkHeight(aspectRatio: 1, width: 340) == 340)
    }

    @Test func wideArtKeepsItsShape() {
        #expect(RAVEMiniPlayerLayout.artworkHeight(aspectRatio: 16.0 / 9.0, width: 320) == 180)
    }

    @Test func tallArtIsCappedAtASquare() {
        #expect(RAVEMiniPlayerLayout.artworkHeight(aspectRatio: 0.5, width: 340) == 340)
    }

    @Test func nonsenseRatiosFallBackToSquare() {
        for ratio in [0, -1, .infinity, .nan] as [CGFloat] {
            #expect(RAVEMiniPlayerLayout.artworkHeight(aspectRatio: ratio, width: 300) == 300)
        }
    }

    @Test func slackKeepsAVisionOSWindowAtOneHeight() {
        let slack = RAVEMiniPlayerLayout.topSlack(aspectRatio: 16.0 / 9.0, width: 320)
        #if os(visionOS)
        // Art and slack always add up to the square the window was sized for.
        #expect(slack == 140)
        #expect(slack + RAVEMiniPlayerLayout.artworkHeight(aspectRatio: 16.0 / 9.0, width: 320) == 320)
        #else
        #expect(slack == 0)
        #endif
    }
}
