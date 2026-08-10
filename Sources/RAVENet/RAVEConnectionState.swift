/*
 RAVENet - Connection state

 Merged from the two source implementations: Spatial Home's `HAConnectionState`
 contributed the explicit enum and the distinct handshake step; Spatial Stash
 contributed `suspended` (socket deliberately released while the endpoint and
 session registry are retained) which its `Bool isConnected` could not express.
 */

import Foundation

/// Lifecycle of a `RAVEWebSocketTransport`.
///
/// Note the deliberate gap between `connecting` and `ready`: an in-progress
/// upgrade can look healthy for a long time before failing, so the transport
/// never reports readiness on its own. The app declares it — see
/// `RAVEWebSocketTransport.markReady()`.
public enum RAVEConnectionState: Sendable, Equatable {
    /// No socket, and none wanted (not started, or explicitly stopped).
    case idle
    /// Socket resumed, upgrade in flight. No traffic proven yet.
    case connecting
    /// Transport is up and the app is running a protocol handshake over it
    /// (e.g. Home Assistant's `auth_required` → `auth` → `auth_ok`). Apps with
    /// no handshake go straight from `connecting` to `ready`.
    case handshaking
    /// The app has declared the connection usable.
    case ready
    /// Socket released on purpose while the endpoint is retained, so returning
    /// to the foreground reconnects immediately instead of rediscovering
    /// everything. Not a failure — backoff is reset when entering this state.
    case suspended
    /// Fatal, non-retryable. Reconnects are suppressed until the next explicit
    /// `start()`. Carries a human-readable reason.
    case failed(String)

    /// True only in `ready`. Deliberately not true during `handshaking` — a
    /// half-authenticated socket must not be treated as usable.
    public var isReady: Bool { self == .ready }
}

/// Why a socket's receive loop ended, handed to the app's failure policy so it
/// can distinguish "retry this" from "this will keep failing for the same
/// reason".
/// Deliberately carries decomposed error facts rather than the raw `any Error`:
/// this value crosses an actor boundary into the app's failure policy, and
/// `Error` is not `Sendable`. Every real decision the two source
/// implementations made used `closeCode`, not the error object; anything else
/// worth seeing is already in `diagnostic`.
public struct RAVETransportFailure: Sendable {
    /// `NSError` domain of the underlying receive failure.
    public let errorDomain: String
    /// `NSError` code of the underlying receive failure.
    public let errorCode: Int
    /// `localizedDescription` of the underlying receive failure.
    public let errorDescription: String
    /// Close code reported by the task, if any. Spatial Stash halts on
    /// `.policyViolation` (1008), which is how its broker rejects a bad token.
    public let closeCode: URLSessionWebSocketTask.CloseCode
    /// UTF-8 decoded close reason, when the peer sent one.
    public let closeReason: String?
    /// Pre-formatted diagnostic line (URLError code, peer trust, failing URL,
    /// close code and reason) suitable for logging verbatim.
    public let diagnostic: String
}

/// What the app wants done about a `RAVETransportFailure`.
public enum RAVEFailureDecision: Sendable, Equatable {
    /// Schedule a backoff reconnect (the normal path).
    case reconnect
    /// Stop permanently and enter `.failed`, surfacing this reason. Use when
    /// retrying cannot help — a rejected token, a protocol-level auth failure.
    case halt(String)
}
