/*
 RAVEHome - Saved accessory actions and their runner

 A `HomeActionTarget` is "put this accessory in this state", remembered by id
 together with the name, room and icon it had when it was picked, so a list of
 them renders without a live connection (a sleep timer's settings screen, with
 the home still connecting). `HomeActionRunner` runs a list against whichever
 backends the app has, waiting for each to be ready and retrying once, and
 reports each outcome.
 */

import DebugLog
import Foundation

public struct HomeActionTarget: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var source: HomeSource
    public var entityId: String
    public var name: String
    public var room: String?
    public var domain: String
    public var deviceClass: String?
    public var state: HomeDesiredState

    public init(id: UUID = UUID(), source: HomeSource, entityId: String, name: String, room: String? = nil,
                domain: String, deviceClass: String? = nil, state: HomeDesiredState) {
        self.id = id
        self.source = source
        self.entityId = entityId
        self.name = name
        self.room = room
        self.domain = domain
        self.deviceClass = deviceClass
        self.state = state
    }

    /// Snapshot an entity as it is now, to be put in `state` later.
    @MainActor
    public init(entity: HAEntity, source: HomeSource, backend: any HomeBackend, state: HomeDesiredState) {
        self.init(source: source, entityId: entity.entityId, name: entity.friendlyName,
                  room: backend.areaName(forEntity: entity.entityId),
                  domain: entity.domain, deviceClass: entity.deviceClass, state: state)
    }

    /// The SF Symbol for the accessory as it will look once the action has run.
    public var symbol: String {
        let look = state.iconState
        return EntityIcon.symbol(domain: domain, deviceClass: deviceClass, isOn: look.isOn,
                                 locked: look.locked, open: look.open)
    }

    /// "Living Room · Turn Off", for a list row's subtitle.
    public var summary: String {
        [room, state.title].compactMap { $0 }.joined(separator: " · ")
    }
}

/// What one target's run came to.
public struct HomeActionOutcome: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let source: HomeSource
    public let succeeded: Bool
    public let message: String?
}

@MainActor
public enum HomeActionRunner {
    public typealias BackendProvider = @MainActor (HomeSource) -> (any HomeBackend)?

    private static let log = DebugLogger(subsystem: "pro.rave.home", category: "Actions")

    /// Run `targets` in order. Each waits for its backend to be connected and
    /// to know the accessory (up to `readyTimeout`), then is applied; a
    /// failure is retried once after `retryDelay`, since an accessory that
    /// just woke is often briefly unreachable. Never throws: a run is a list
    /// of outcomes.
    public static func run(
        _ targets: [HomeActionTarget],
        backend: BackendProvider,
        readyTimeout: Duration = .seconds(20),
        retryDelay: Duration = .seconds(4)
    ) async -> [HomeActionOutcome] {
        var outcomes: [HomeActionOutcome] = []
        for target in targets {
            guard !Task.isCancelled else { break }
            outcomes.append(await run(target, backend: backend, readyTimeout: readyTimeout, retryDelay: retryDelay))
        }
        return outcomes
    }

    private static func run(_ target: HomeActionTarget, backend: BackendProvider,
                            readyTimeout: Duration, retryDelay: Duration) async -> HomeActionOutcome {
        func outcome(_ error: Error?) -> HomeActionOutcome {
            HomeActionOutcome(id: target.id, name: target.name, source: target.source,
                              succeeded: error == nil, message: error?.localizedDescription)
        }
        guard let backend = backend(target.source) else {
            return outcome(HomeActionError.notConnected(target.source))
        }
        var lastError: Error = HomeActionError.notConnected(target.source)
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: retryDelay) }
            guard await backend.waitUntilReady(entityId: target.entityId, timeout: readyTimeout) else {
                lastError = backend.isConnected ? HomeActionError.accessoryMissing
                                                : HomeActionError.notConnected(target.source)
                continue
            }
            do {
                try await backend.apply(target.state, toEntity: target.entityId)
                log.info("applied \(target.state.shortTitle, privacy: .public) to \(target.domain, privacy: .public) via \(target.source.rawValue, privacy: .public)")
                return outcome(nil)
            } catch {
                lastError = error
                log.warning("apply to \(target.domain, privacy: .public) failed (attempt \(attempt + 1, privacy: .public)): \(error.localizedDescription, privacy: .private)")
            }
        }
        return outcome(lastError)
    }
}
