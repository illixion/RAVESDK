import Testing
@testable import RAVEMedia

@Suite("Head-locked sound policy")
struct HeadLockedSoundTests {
    @Test func offLocksNothing() {
        for layout in [nil, false, true] as [Bool?] {
            #expect(!RAVEHeadLockedSound.off.locks(multichannel: layout))
        }
    }

    @Test func alwaysLocksEverything() {
        for layout in [nil, false, true] as [Bool?] {
            #expect(RAVEHeadLockedSound.always.locks(multichannel: layout))
        }
    }

    /// Stereo and mono keep full quality (locked = unspatialized); surround
    /// keeps its spatial features. Unprobed audio reads as stereo.
    @Test func byLayoutLocksStereoAndLeavesSurroundSpatial() {
        #expect(RAVEHeadLockedSound.byLayout.locks(multichannel: false))
        #expect(RAVEHeadLockedSound.byLayout.locks(multichannel: nil))
        #expect(!RAVEHeadLockedSound.byLayout.locks(multichannel: true))
    }

    @Test func surroundShorthandFollowsTheMode() {
        let before = RAVEMediaPolicy.headLockedSound
        defer { RAVEMediaPolicy.headLockedSound = before }

        RAVEMediaPolicy.headLockedSurround = true
        #expect(RAVEMediaPolicy.headLockedSound == .always)
        RAVEMediaPolicy.headLockedSound = .byLayout
        #expect(!RAVEMediaPolicy.headLockedSurround)
        RAVEMediaPolicy.headLockedSurround = false
        #expect(RAVEMediaPolicy.headLockedSound == .off)
    }

    @Test func rawValuesAreStable() {
        // Persisted by the host app.
        #expect(RAVEHeadLockedSound.allCases.map(\.rawValue) == ["off", "always", "byLayout"])
    }
}
