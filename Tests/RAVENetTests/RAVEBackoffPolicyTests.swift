/*
 Tests for the reconnect backoff arithmetic.

 This logic shipped in two apps for months with no test coverage, and both of
 its floors exist because of a specific production failure — so each floor gets
 an explicit case here rather than being inferred from a happy-path assertion.
 */

import Foundation
import Testing
@testable import RAVENet

@Suite("RAVEBackoffPolicy")
struct RAVEBackoffPolicyTests {

    private let policy = RAVEBackoffPolicy(minDelay: 2, maxDelay: 30)

    @Test("Exponential growth applies between the two floors")
    func exponentialGrowth() {
        // 2^2 = 4 and 2^3 = 8, both clear of the min floor and the max ceiling.
        #expect(policy.delay(forAttempt: 2, secondsSinceLastAttempt: 0) == 4)
        #expect(policy.delay(forAttempt: 3, secondsSinceLastAttempt: 0) == 8)
        #expect(policy.delay(forAttempt: 4, secondsSinceLastAttempt: 0) == 16)
    }

    @Test("First attempt is raised to the minimum delay")
    func firstAttemptHitsMinimum() {
        // 2^0 = 1, below the 2 s floor. An unfloored retry loop on an instant
        // ENOTCONN is what hammered the server during interface flaps.
        #expect(policy.delay(forAttempt: 0, secondsSinceLastAttempt: 0) == 2)
        // 2^1 = 2, exactly at the floor.
        #expect(policy.delay(forAttempt: 1, secondsSinceLastAttempt: 0) == 2)
    }

    @Test("Exponential term is capped at maxDelay")
    func cappedAtMaximum() {
        #expect(policy.delay(forAttempt: 10, secondsSinceLastAttempt: 0) == 30)
        #expect(policy.delay(forAttempt: 60, secondsSinceLastAttempt: 0) == 30)
    }

    @Test("Elapsed time since the last attempt is subtracted")
    func elapsedTimeIsCredited() {
        // A connect that stalled 20 s before failing has already served most of
        // the 30 s backoff; only the remainder should be slept.
        #expect(policy.delay(forAttempt: 5, secondsSinceLastAttempt: 20) == 10)
        #expect(policy.delay(forAttempt: 4, secondsSinceLastAttempt: 6) == 10)
    }

    @Test("A long stalled connect still respects the minimum floor")
    func creditCannotDriveDelayBelowMinimum() {
        // waitsForConnectivity can stall well past the exponential delay. The
        // credit must not turn into a zero-delay retry firehose.
        #expect(policy.delay(forAttempt: 5, secondsSinceLastAttempt: 40) == 2)
        #expect(policy.delay(forAttempt: 5, secondsSinceLastAttempt: 10_000) == 2)
    }

    @Test("Negative inputs are clamped rather than inverting the curve")
    func negativeInputsAreClamped() {
        // Clock adjustments can make an elapsed interval negative; a negative
        // credit would *add* to the delay.
        #expect(policy.delay(forAttempt: 3, secondsSinceLastAttempt: -50) == 8)
        #expect(policy.delay(forAttempt: -1, secondsSinceLastAttempt: 0) == 2)
    }

    @Test("Custom floors are honoured")
    func customPolicy() {
        let tight = RAVEBackoffPolicy(minDelay: 0.5, maxDelay: 4)
        #expect(tight.delay(forAttempt: 0, secondsSinceLastAttempt: 0) == 1)
        #expect(tight.delay(forAttempt: 1, secondsSinceLastAttempt: 0) == 2)
        #expect(tight.delay(forAttempt: 9, secondsSinceLastAttempt: 0) == 4)
        #expect(tight.delay(forAttempt: 9, secondsSinceLastAttempt: 99) == 0.5)
    }
}
