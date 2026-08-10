/*
 RAVENet - Reconnect backoff policy

 Pure value type, deliberately free of Foundation networking and of any actor
 isolation, so the retry arithmetic is unit-testable without a socket or an
 SDK. Both source implementations (Spatial Stash's RemoteWebSocketClient and
 Spatial Home's HAConnection) computed this identically, inline and untested.
 */

import Foundation

/// Exponential backoff with two independent floors.
///
/// The subtraction of elapsed-since-last-attempt is not an optimisation — it
/// is what keeps a slow *failing* connect from stacking another full delay on
/// top of the time already burned. `URLSession`'s `waitsForConnectivity` can
/// stall a connect for 20 s before it throws; without this the client then
/// slept the whole exponential delay again on top of that.
///
/// The minimum delay exists for the opposite failure: `ENOTCONN` during a
/// sleep/wake interface flap throws inside a millisecond, and an unfloored
/// loop hammers the server continuously for the entire outage.
public struct RAVEBackoffPolicy: Sendable, Equatable {
    /// Never retry faster than this, however quickly the attempt failed.
    public var minDelay: TimeInterval
    /// Ceiling for the exponential term.
    public var maxDelay: TimeInterval

    public init(minDelay: TimeInterval = 2, maxDelay: TimeInterval = 30) {
        self.minDelay = minDelay
        self.maxDelay = maxDelay
    }

    /// Delay before retry number `attempt` (0-based).
    ///
    /// - Parameters:
    ///   - attempt: How many attempts have already been made on this failure
    ///     streak. Reset to 0 only once a connection has genuinely carried
    ///     traffic — never on a wake or path-up edge, neither of which proves
    ///     the next attempt will succeed.
    ///   - secondsSinceLastAttempt: Wall-clock time since the last connect was
    ///     started, subtracted from the exponential term.
    public func delay(forAttempt attempt: Int, secondsSinceLastAttempt: TimeInterval) -> TimeInterval {
        let exponential = min(pow(2.0, Double(max(0, attempt))), maxDelay)
        return max(minDelay, exponential - max(0, secondsSinceLastAttempt))
    }
}
