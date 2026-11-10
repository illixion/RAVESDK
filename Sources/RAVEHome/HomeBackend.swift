/*
 RAVEHome - Home backend abstraction

 An app can drive more than one kind of "home": a Home Assistant instance
 (`HAConnection`) or a native HomeKit home (`HomeKitConnection`). Both present
 the same small surface — a live `entities` store keyed by id, a connection
 status, room lookup, a fixed set of command methods and one awaitable
 `apply(_:toEntity:)` — so a grid, a detail control, a light cube or a sleep
 timer works against either one without caring which is behind it.

 `HAEntity` is the universal accessory snapshot: a HomeKit accessory is mapped
 into an `HAEntity` (domain, brightness, color temp, …), so everything built
 on it works for both.
 */

import Foundation

/// Backend-agnostic connection status for display in Settings and empty states.
public enum HomeBackendStatus: Equatable, Sendable {
    case idle
    case connecting
    case connected
    /// Not usable right now, with a human-readable reason (bad token, HomeKit
    /// access denied, no homes, …).
    case unavailable(String)
}

/// The surface every home backend exposes. Implementations are
/// `@MainActor @Observable` reference types, so property reads through the
/// existential are tracked by SwiftUI's observation system.
@MainActor
public protocol HomeBackend: AnyObject {
    /// Live accessory store, keyed by entity id.
    var entities: [String: HAEntity] { get }

    /// True when the backend is up and its store is authoritative.
    var isConnected: Bool { get }

    /// Backend-agnostic status for the Settings status row.
    var status: HomeBackendStatus { get }

    /// A short detail string (e.g. "HA 2024.6" or "2 homes · 14 accessories").
    var statusDetail: String? { get }

    /// The room/area name for an entity, if known.
    func areaName(forEntity id: String) -> String?

    /// The name of the home the entity belongs to — a HomeKit home's name, or
    /// the Home Assistant instance's. Saved windows are grouped under it.
    func homeName(forEntity id: String) -> String?

    // MARK: - Commands

    /// Perform the natural "tap" action for an entity's domain.
    func performDefaultAction(on entity: HAEntity)

    func setLightBrightness(entityId: String, fraction: Double)
    func setLightColorTempKelvin(entityId: String, kelvin: Int)

    /// Set the generic slider value (brightness, fan speed, cover position, …).
    func setSliderFraction(entity: HAEntity, fraction: Double)

    func setClimateTemperature(entityId: String, temperature: Double)
    func setClimateHvacMode(entityId: String, mode: String)
    func setClimateFanMode(entityId: String, mode: String)
    func setClimatePresetMode(entityId: String, mode: String)
    func setClimateSwingMode(entityId: String, mode: String)

    /// Put an accessory into `desired` and return once the home has accepted
    /// it. Unlike the fire-and-forget commands above, a failure is thrown, so
    /// something acting unattended (a sleep timer) can retry and report.
    func apply(_ desired: HomeDesiredState, toEntity id: String) async throws
}

public extension HomeBackend {
    /// Wait until the backend is connected and `entityId` is in its store, or
    /// `timeout` passes. A backend that just woke from sleep needs a moment
    /// before either is true.
    func waitUntilReady(entityId: String, timeout: Duration = .seconds(20)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !(isConnected && entities[entityId] != nil) {
            if ContinuousClock.now >= deadline || Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }
}
