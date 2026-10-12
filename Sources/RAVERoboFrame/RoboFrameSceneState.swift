/*
 RAVERoboFrame - presence and visibility bookkeeping

 `present` is session-scoped: each window has its own server channel, and a
 channel whose every session is absent does one dark advance and parks, so
 the next arrival sees a fresh post. `visibility` is device-scoped
 home-location telemetry (the HA motion sensor), OR-aggregated across the
 sessions sharing a deviceId.

 A pure value so the edge logic is testable without a socket. The connection
 keeps one across reconnects (the socket dies, the windows don't) and forces a
 full replay after each, because the server forgets every report with the
 socket.
 */

import Foundation

public struct RoboFrameSceneState: Equatable, Sendable {
    /// One frame the bookkeeping wants on the wire.
    public enum Report: Equatable, Sendable {
        case present(sessionId: String, deviceId: String, present: Bool)
        case visibility(deviceId: String, visible: Bool)
    }

    private struct Contribution: Equatable, Sendable {
        var deviceId: String
        var present: Bool
        var visible: Bool
    }

    private var contributions: [String: Contribution] = [:]
    /// What was last put on the wire.
    private var sentPresence: [String: Bool] = [:]
    private var sentVisibility: [String: Bool] = [:]

    public init() {}

    /// Record a session's scene state. Call `flush` to get the edges.
    public mutating func report(sessionId: String, deviceId: String, present: Bool, visible: Bool) {
        contributions[sessionId] = Contribution(deviceId: deviceId, present: present, visible: visible)
    }

    /// Forget a session. If it was the last one reporting its deviceId
    /// visible, the next flush emits the OFF edge, so a closed window doesn't
    /// leave the socket asserting a display that no longer exists.
    public mutating func remove(sessionId: String) {
        contributions.removeValue(forKey: sessionId)
        sentPresence.removeValue(forKey: sessionId)
    }

    /// The session's last reported deviceId and presence.
    public func contribution(for sessionId: String) -> (deviceId: String, present: Bool)? {
        contributions[sessionId].map { ($0.deviceId, $0.present) }
    }

    /// True when no session is present: nothing on the connection shows a slideshow.
    public var allAbsent: Bool {
        !contributions.values.contains(where: \.present)
    }

    /// The reports that differ from what was last sent, marking them sent.
    /// `force` re-sends everything (after a reconnect). Presence comes first,
    /// in session order, then visibility in deviceId order.
    public mutating func flush(force: Bool = false) -> [Report] {
        if force {
            sentPresence.removeAll()
            sentVisibility.removeAll()
        }
        var reports: [Report] = []
        var visibility: [String: Bool] = [:]
        for (sessionId, contribution) in contributions.sorted(by: { $0.key < $1.key }) {
            if sentPresence[sessionId] != contribution.present {
                sentPresence[sessionId] = contribution.present
                reports.append(.present(sessionId: sessionId, deviceId: contribution.deviceId, present: contribution.present))
            }
            visibility[contribution.deviceId] = (visibility[contribution.deviceId] ?? false) || contribution.visible
        }
        // A deviceId whose last session went away still owes its OFF edge.
        for deviceId in sentVisibility.keys where visibility[deviceId] == nil {
            visibility[deviceId] = false
        }
        for (deviceId, visible) in visibility.sorted(by: { $0.key < $1.key }) where sentVisibility[deviceId] != visible {
            sentVisibility[deviceId] = visible
            reports.append(.visibility(deviceId: deviceId, visible: visible))
        }
        // Devices with no sessions left that already went dark need no more
        // bookkeeping, so the map doesn't grow over a long run.
        let live = Set(contributions.values.map(\.deviceId))
        sentVisibility = sentVisibility.filter { live.contains($0.key) || $0.value }
        return reports
    }
}
