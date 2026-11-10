/*
 RAVEHome - HomeKit backend

 Drives a native HomeKit home so people who don't run Home Assistant can still
 use the app. It mirrors `HAConnection`'s shape — a live `entities` store keyed
 by id — but sources that store from `HMHomeManager` instead of a WebSocket.

 Each controllable `HMService` is mapped to one `HAEntity` (the same universal
 accessory snapshot the HA backend produces), so the Home.app-style grid, the
 detail controls, and the glowing pop-out cube work unchanged. Characteristic
 values are primed with `readValue`, kept live via `enableNotification` + the
 accessory delegate, and commands are written straight back to the underlying
 characteristics.

 `HMHomeManager` is created lazily in `activate()` so HA-only users are never
 shown a HomeKit authorization prompt they didn't ask for.
 */

#if canImport(HomeKit)
import DebugLog
import Foundation
import HomeKit

@MainActor
@Observable
public final class HomeKitConnection: NSObject, HomeBackend {
    // MARK: - Observable state

    public private(set) var entities: [String: HAEntity] = [:]
    @ObservationIgnored public var onSensorUpdate: ((HAEntity) -> Void)?

    /// Mirror of `HMHomeManager.authorizationStatus`, stored so SwiftUI observes
    /// changes (the manager itself isn't `@Observable`).
    public private(set) var authorization: HMHomeManagerAuthorizationStatus = []

    public private(set) var homeCount: Int = 0

    public override init() { super.init() }

    // MARK: - HomeKit internals (not observed)

    @ObservationIgnored private var manager: HMHomeManager?
    @ObservationIgnored private var activatedAt: Date?
    /// entity id → characteristic type → characteristic, for reads and writes.
    @ObservationIgnored private var charCache: [String: [String: HMCharacteristic]] = [:]
    /// entity id → the service/accessory it was built from.
    @ObservationIgnored private var serviceIndex: [String: ServiceRef] = [:]
    /// service UUID → entity id, for routing delegate updates.
    @ObservationIgnored private var serviceUUIDToId: [UUID: String] = [:]
    /// entity id → room name, for `areaName(forEntity:)`.
    @ObservationIgnored private var roomName: [String: String] = [:]
    /// entity id → name of the HomeKit home it lives in, for `homeName(forEntity:)`.
    @ObservationIgnored private var homeNames: [String: String] = [:]

    private struct ServiceRef {
        let accessory: HMAccessory
        let service: HMService
        let domain: String
        let deviceClass: String?
    }

    // MARK: - HomeBackend status

    public var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    public var status: HomeBackendStatus {
        guard manager != nil else { return .idle }
        if authorization.contains(.restricted) {
            return .unavailable("HomeKit access is restricted")
        }
        // `.determined` means the system has finished deciding; without
        // `.authorized` alongside it, the user declined.
        if authorization.contains(.determined) && !authorization.contains(.authorized) {
            return .unavailable("HomeKit access denied — enable it in Settings")
        }
        if !authorization.contains(.authorized) {
            return .connecting
        }
        if homeCount == 0 {
            return .unavailable("No HomeKit homes — set one up in the Home app")
        }
        return .connected
    }

    public var statusDetail: String? {
        guard isConnected else { return nil }
        let homes = homeCount == 1 ? "1 home" : "\(homeCount) homes"
        return "\(homes) · \(entities.count) accessories"
    }

    /// True when HomeKit has said nothing at all for `after` seconds since
    /// `activate()`: no authorization decision, not even a refusal. That is
    /// what an app signed without the HomeKit capability sees (the system logs
    /// the missing entitlement and the manager just never answers), so a UI
    /// can say so instead of "connecting" forever. Not observable over time:
    /// ask it from a clock (a `TimelineView`).
    public func isSilent(after seconds: TimeInterval = 8, at date: Date = Date()) -> Bool {
        guard manager != nil, authorization.isEmpty, let activatedAt else { return false }
        return date.timeIntervalSince(activatedAt) >= seconds
    }

    public func areaName(forEntity id: String) -> String? { roomName[id] }

    public func homeName(forEntity id: String) -> String? { homeNames[id] }

    // MARK: - Lifecycle

    /// Create the home manager (triggering the authorization prompt on first
    /// use) and start loading homes. Idempotent.
    public func activate() {
        guard manager == nil else { return }
        activatedAt = Date()
        let manager = HMHomeManager()
        manager.delegate = self
        self.manager = manager
        self.authorization = manager.authorizationStatus
        HomeLog.connection.info("HomeKit manager created")
    }

    /// A restored/resumed panel must read fresh characteristics rather than
    /// treating its pre-suspension snapshot as a new observation.
    public func refreshSensor(entityID: String) {
        guard let ref = serviceIndex[entityID], ref.domain == "sensor" || ref.domain == "binary_sensor" else { return }
        primeCharacteristics(of: ref.service)
    }

    // MARK: - Store building

    private func rebuildAllEntities() {
        guard let manager else { return }
        homeCount = manager.homes.count

        var newCharCache: [String: [String: HMCharacteristic]] = [:]
        var newIndex: [String: ServiceRef] = [:]
        var newUUIDToId: [UUID: String] = [:]
        var newRoomName: [String: String] = [:]
        var newHomeNames: [String: String] = [:]

        for home in manager.homes {
            home.delegate = self
            for accessory in home.accessories {
                accessory.delegate = self
                for service in accessory.services {
                    guard let mapping = Self.domainAndClass(for: service.serviceType) else { continue }
                    let id = "\(mapping.domain).\(service.uniqueIdentifier.uuidString)"

                    var chars: [String: HMCharacteristic] = [:]
                    for c in service.characteristics { chars[c.characteristicType] = c }
                    newCharCache[id] = chars
                    newIndex[id] = ServiceRef(accessory: accessory, service: service,
                                              domain: mapping.domain, deviceClass: mapping.deviceClass)
                    newUUIDToId[service.uniqueIdentifier] = id
                    if let room = accessory.room?.name { newRoomName[id] = room }
                    newHomeNames[id] = home.name

                    primeCharacteristics(of: service)
                }
            }
        }

        charCache = newCharCache
        serviceIndex = newIndex
        serviceUUIDToId = newUUIDToId
        roomName = newRoomName
        homeNames = newHomeNames

        var built: [String: HAEntity] = [:]
        built.reserveCapacity(newIndex.count)
        for (id, ref) in newIndex { built[id] = makeEntity(ref: ref, id: id) }
        entities = built
        for entity in built.values { onSensorUpdate?(entity) }
        HomeLog.entities.info("HomeKit mapped \(built.count) accessories across \(self.homeCount) home(s)")
    }

    /// Prime a service's characteristics: read current values and subscribe to
    /// change notifications so the store stays live.
    private func primeCharacteristics(of service: HMService) {
        let sid = service.uniqueIdentifier
        for c in service.characteristics {
            if c.properties.contains(HMCharacteristicPropertyReadable) {
                c.readValue { [weak self] _ in
                    Task { @MainActor in self?.rebuildEntity(serviceUUID: sid) }
                }
            }
            if c.properties.contains(HMCharacteristicPropertySupportsEventNotification) {
                c.enableNotification(true) { _ in }
            }
        }
    }

    private func rebuildEntity(serviceUUID: UUID) {
        guard let id = serviceUUIDToId[serviceUUID], let ref = serviceIndex[id] else { return }
        let entity = makeEntity(ref: ref, id: id)
        entities[id] = entity
        onSensorUpdate?(entity)
    }

    // MARK: - Service → HAEntity mapping

    /// Which HA-style domain (and optional device_class) a HomeKit service maps
    /// to. `nil` for services we don't surface (accessory info, batteries, …).
    private static func domainAndClass(for serviceType: String) -> (domain: String, deviceClass: String?)? {
        switch serviceType {
        case HMServiceTypeLightbulb: return ("light", nil)
        case HMServiceTypeSwitch: return ("switch", nil)
        case HMServiceTypeOutlet: return ("switch", "outlet")
        case HMServiceTypeFan: return ("fan", nil)
        case HMServiceTypeLockMechanism: return ("lock", nil)
        case HMServiceTypeThermostat: return ("climate", nil)
        case HMServiceTypeWindowCovering: return ("cover", nil)
        case HMServiceTypeGarageDoorOpener: return ("cover", "garage")
        case HMServiceTypeTemperatureSensor: return ("sensor", "temperature")
        case HMServiceTypeHumiditySensor: return ("sensor", "humidity")
        case HMServiceTypeLightSensor: return ("sensor", "illuminance")
        case HMServiceTypeMotionSensor: return ("binary_sensor", "motion")
        case HMServiceTypeContactSensor: return ("binary_sensor", "opening")
        case HMServiceTypeOccupancySensor: return ("binary_sensor", "occupancy")
        case HMServiceTypeLeakSensor: return ("binary_sensor", "moisture")
        case HMServiceTypeSmokeSensor: return ("binary_sensor", "smoke")
        default: return nil
        }
    }

    private func makeEntity(ref: ServiceRef, id: String) -> HAEntity {
        let chars = charCache[id] ?? [:]
        var attrs: [String: Any] = [:]
        let name = ref.service.name.isEmpty ? ref.accessory.name : ref.service.name
        attrs["friendly_name"] = name
        if let dc = ref.deviceClass { attrs["device_class"] = dc }
        var state = "off"

        switch ref.domain {
        case "light":
            let on = boolVal(chars[HMCharacteristicTypePowerState]) ?? false
            state = on ? "on" : "off"
            var modes: [String] = []
            if let b = chars[HMCharacteristicTypeBrightness] {
                let pct = intVal(b) ?? 0
                attrs["brightness"] = Int((Double(pct) / 100.0 * 255.0).rounded())
                modes.append("brightness")
            }
            if let ct = chars[HMCharacteristicTypeColorTemperature] {
                if let mired = intVal(ct), mired > 0 { attrs["color_temp_kelvin"] = Int(1_000_000.0 / Double(mired)) }
                // HomeKit min mired ⇒ max kelvin, and vice-versa.
                if let maxMired = ct.metadata?.maximumValue?.doubleValue, maxMired > 0 {
                    attrs["min_color_temp_kelvin"] = Int(1_000_000.0 / maxMired)
                }
                if let minMired = ct.metadata?.minimumValue?.doubleValue, minMired > 0 {
                    attrs["max_color_temp_kelvin"] = Int(1_000_000.0 / minMired)
                }
                modes.append("color_temp")
            }
            if let hueC = chars[HMCharacteristicTypeHue], let satC = chars[HMCharacteristicTypeSaturation] {
                let hue = doubleVal(hueC) ?? 0
                let sat = (doubleVal(satC) ?? 0) / 100.0
                let rgb = Self.hsvToRGB(h: hue, s: sat, v: 1.0)
                attrs["rgb_color"] = [rgb.r, rgb.g, rgb.b]
                modes.append("hs")
            }
            attrs["supported_color_modes"] = modes.isEmpty ? ["onoff"] : modes

        case "switch":
            let on = boolVal(chars[HMCharacteristicTypePowerState]) ?? false
            state = on ? "on" : "off"

        case "fan":
            let active = boolVal(chars[HMCharacteristicTypeActive])
                ?? boolVal(chars[HMCharacteristicTypePowerState]) ?? false
            state = active ? "on" : "off"
            if let rs = chars[HMCharacteristicTypeRotationSpeed] { attrs["percentage"] = intVal(rs) ?? 0 }

        case "lock":
            // 0 unsecured, 1 secured, 2 jammed, 3 unknown.
            let s = intVal(chars[HMCharacteristicTypeCurrentLockMechanismState]) ?? 3
            state = s == 1 ? "locked" : (s == 0 ? "unlocked" : "unknown")

        case "cover":
            if let pos = chars[HMCharacteristicTypeCurrentPosition] {
                let p = intVal(pos) ?? 0
                attrs["current_position"] = p
                state = p > 0 ? "open" : "closed"
            } else if let ds = chars[HMCharacteristicTypeCurrentDoorState] {
                // 0 open, 1 closed, 2 opening, 3 closing, 4 stopped.
                state = (intVal(ds) ?? 1) == 0 ? "open" : "closed"
            }

        case "climate":
            let mode = intVal(chars[HMCharacteristicTypeTargetHeatingCooling]) ?? 0
            state = Self.hvacModeString(mode)
            attrs["hvac_modes"] = ["off", "heat", "cool", "heat_cool"]
            attrs["supported_features"] = 1 // TARGET_TEMPERATURE
            if let ct = chars[HMCharacteristicTypeCurrentTemperature] { attrs["current_temperature"] = doubleVal(ct) }
            if let tt = chars[HMCharacteristicTypeTargetTemperature] {
                attrs["temperature"] = doubleVal(tt)
                if let mn = tt.metadata?.minimumValue?.doubleValue { attrs["min_temp"] = mn }
                if let mx = tt.metadata?.maximumValue?.doubleValue { attrs["max_temp"] = mx }
                if let step = tt.metadata?.stepValue?.doubleValue { attrs["target_temp_step"] = step }
            }

        case "sensor":
            switch ref.deviceClass {
            case "temperature":
                state = doubleVal(chars[HMCharacteristicTypeCurrentTemperature]).map { String(format: "%.1f", $0) } ?? "unknown"
                attrs["unit_of_measurement"] = "°C"
            case "humidity":
                state = doubleVal(chars[HMCharacteristicTypeCurrentRelativeHumidity]).map { String(Int($0.rounded())) } ?? "unknown"
                attrs["unit_of_measurement"] = "%"
            case "illuminance":
                state = doubleVal(chars[HMCharacteristicTypeCurrentLightLevel]).map { String(Int($0.rounded())) } ?? "unknown"
                attrs["unit_of_measurement"] = "lx"
            default: break
            }

        case "binary_sensor":
            let detected: Bool?
            switch ref.deviceClass {
            case "motion": detected = boolVal(chars[HMCharacteristicTypeMotionDetected])
            case "occupancy": detected = intVal(chars[HMCharacteristicTypeOccupancyDetected]).map { $0 != 0 }
            case "opening": detected = intVal(chars[HMCharacteristicTypeContactState]).map { $0 != 0 }
            case "moisture": detected = intVal(chars[HMCharacteristicTypeLeakDetected]).map { $0 != 0 }
            case "smoke": detected = intVal(chars[HMCharacteristicTypeSmokeDetected]).map { $0 != 0 }
            default: detected = nil
            }
            state = detected.map { $0 ? "on" : "off" } ?? "unknown"

        default:
            break
        }

        if (ref.domain == "sensor" || ref.domain == "binary_sensor"), !ref.accessory.isReachable { state = "unavailable" }
        return HAEntity(entityId: id, state: state, attributes: attrs, lastUpdated: Date())
    }

    // MARK: - Commands
    //
    // Every command applies an immediate *optimistic* local state change and
    // then writes to HomeKit. HomeKit's change notifications can lag or, for
    // some accessories/transitions, not fire at all — without the optimistic
    // update the UI would appear "stuck" on the previous state (e.g. a light
    // that stays on after being switched off, so the next tap just re-sends
    // the same value). The accessory delegate reconciles to the real value
    // whenever a notification does arrive.

    public func performDefaultAction(on entity: HAEntity) {
        let id = entity.entityId
        switch entity.domain {
        case "light", "switch":
            let newOn = !entity.isOn
            write(newOn, type: HMCharacteristicTypePowerState, entityId: id)
            optimistic(id) { $0.state = newOn ? "on" : "off" }
        case "fan":
            let newOn = !entity.isOn
            if charCache[id]?[HMCharacteristicTypeActive] != nil {
                write(newOn ? 1 : 0, type: HMCharacteristicTypeActive, entityId: id)
            } else {
                write(newOn, type: HMCharacteristicTypePowerState, entityId: id)
            }
            optimistic(id) { $0.state = newOn ? "on" : "off" }
        case "lock":
            let willLock = entity.state != "locked"
            // Target: 0 unsecured, 1 secured.
            write(willLock ? 1 : 0, type: HMCharacteristicTypeTargetLockMechanismState, entityId: id)
            optimistic(id) { $0.state = willLock ? "locked" : "unlocked" }
        case "cover":
            let willOpen = !(entity.state == "open" || entity.isOn)
            if charCache[id]?[HMCharacteristicTypeTargetPosition] != nil {
                write(willOpen ? 100 : 0, type: HMCharacteristicTypeTargetPosition, entityId: id)
                optimistic(id) {
                    $0.state = willOpen ? "open" : "closed"
                    $0.attributes["current_position"] = willOpen ? 100 : 0
                }
            } else if charCache[id]?[HMCharacteristicTypeTargetDoorState] != nil {
                // 0 open, 1 closed.
                write(willOpen ? 0 : 1, type: HMCharacteristicTypeTargetDoorState, entityId: id)
                optimistic(id) { $0.state = willOpen ? "open" : "closed" }
            }
        case "climate":
            let turningOn = entity.state == "off"
            write(turningOn ? 3 : 0, type: HMCharacteristicTypeTargetHeatingCooling, entityId: id)
            optimistic(id) { $0.state = turningOn ? "heat_cool" : "off" }
        default:
            break
        }
    }

    public func setLightBrightness(entityId: String, fraction: Double) {
        let pct = max(0, min(100, Int((fraction * 100).rounded())))
        if pct == 0 {
            write(false, type: HMCharacteristicTypePowerState, entityId: entityId)
            optimistic(entityId) { $0.state = "off" }
        } else {
            write(true, type: HMCharacteristicTypePowerState, entityId: entityId)
            write(pct, type: HMCharacteristicTypeBrightness, entityId: entityId)
            optimistic(entityId) {
                $0.state = "on"
                $0.attributes["brightness"] = Int((Double(pct) / 100.0 * 255.0).rounded())
            }
        }
    }

    public func setLightColorTempKelvin(entityId: String, kelvin: Int) {
        guard kelvin > 0, let char = charCache[entityId]?[HMCharacteristicTypeColorTemperature] else { return }
        var mired = Int((1_000_000.0 / Double(kelvin)).rounded())
        if let mn = char.metadata?.minimumValue?.intValue { mired = max(mired, mn) }
        if let mx = char.metadata?.maximumValue?.intValue { mired = min(mired, mx) }
        write(mired, type: HMCharacteristicTypeColorTemperature, entityId: entityId)
        optimistic(entityId) { $0.attributes["color_temp_kelvin"] = kelvin }
    }

    public func setSliderFraction(entity: HAEntity, fraction: Double) {
        let pct = max(0, min(100, Int((fraction * 100).rounded())))
        let id = entity.entityId
        switch entity.domain {
        case "light":
            setLightBrightness(entityId: id, fraction: fraction)
        case "fan":
            if pct == 0 {
                if charCache[id]?[HMCharacteristicTypeActive] != nil {
                    write(0, type: HMCharacteristicTypeActive, entityId: id)
                } else {
                    write(false, type: HMCharacteristicTypePowerState, entityId: id)
                }
            } else {
                if charCache[id]?[HMCharacteristicTypeActive] != nil {
                    write(1, type: HMCharacteristicTypeActive, entityId: id)
                }
                write(pct, type: HMCharacteristicTypeRotationSpeed, entityId: id)
            }
            optimistic(id) {
                $0.state = pct == 0 ? "off" : "on"
                $0.attributes["percentage"] = pct
            }
        case "cover":
            write(pct, type: HMCharacteristicTypeTargetPosition, entityId: id)
            optimistic(id) {
                $0.state = pct > 0 ? "open" : "closed"
                $0.attributes["current_position"] = pct
            }
        default:
            break
        }
    }

    public func setClimateTemperature(entityId: String, temperature: Double) {
        write(temperature, type: HMCharacteristicTypeTargetTemperature, entityId: entityId)
        optimistic(entityId) { $0.attributes["temperature"] = temperature }
    }

    public func setClimateHvacMode(entityId: String, mode: String) {
        write(Self.hvacModeInt(mode), type: HMCharacteristicTypeTargetHeatingCooling, entityId: entityId)
        optimistic(entityId) { $0.state = mode }
    }

    // HomeKit thermostats (as mapped here) have no fan/preset/swing modes.
    public func setClimateFanMode(entityId: String, mode: String) {}
    public func setClimatePresetMode(entityId: String, mode: String) {}
    public func setClimateSwingMode(entityId: String, mode: String) {}

    /// Apply an immediate local state change so the UI reflects a commanded
    /// action without waiting for HomeKit's change notification. Reconciled by
    /// the accessory delegate when the real value arrives.
    private func optimistic(_ entityId: String, _ change: (inout HAEntity) -> Void) {
        guard var entity = entities[entityId] else { return }
        change(&entity)
        entities[entityId] = entity
    }

    private func write(_ value: Any, type: String, entityId: String) {
        guard let char = charCache[entityId]?[type] else { return }
        char.writeValue(value) { error in
            if let error {
                HomeLog.entities.error("HomeKit write \(type, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    // MARK: - Awaitable apply

    /// Put an accessory in `desired`, returning when HomeKit has written every
    /// characteristic (`HomeBackend.apply`). The local state is updated
    /// optimistically, like the fire-and-forget commands.
    public func apply(_ desired: HomeDesiredState, toEntity id: String) async throws {
        guard let ref = serviceIndex[id] else { throw HomeActionError.accessoryMissing }
        let chars = charCache[id] ?? [:]
        func has(_ type: String) -> Bool { chars[type] != nil }
        var writes: [(String, Any)] = []
        var local: (inout HAEntity) -> Void = { _ in }

        switch (ref.domain, desired) {
        case ("light", .on), ("switch", .on):
            writes = [(HMCharacteristicTypePowerState, true)]
            local = { $0.state = "on" }
        case ("light", .off), ("switch", .off):
            writes = [(HMCharacteristicTypePowerState, false)]
            local = { $0.state = "off" }
        case ("light", .level(let raw)):
            let percent = max(0, min(100, raw))
            if percent == 0 {
                writes = [(HMCharacteristicTypePowerState, false)]
                local = { $0.state = "off" }
            } else {
                writes = [(HMCharacteristicTypePowerState, true), (HMCharacteristicTypeBrightness, percent)]
                local = { $0.state = "on"; $0.attributes["brightness"] = Int((Double(percent) / 100 * 255).rounded()) }
            }
        case ("fan", .on), ("fan", .off):
            let on = desired == .on
            writes = [has(HMCharacteristicTypeActive) ? (HMCharacteristicTypeActive, on ? 1 : 0)
                                                       : (HMCharacteristicTypePowerState, on)]
            local = { $0.state = on ? "on" : "off" }
        case ("fan", .level(let raw)):
            let percent = max(0, min(100, raw))
            if has(HMCharacteristicTypeActive) { writes.append((HMCharacteristicTypeActive, percent == 0 ? 0 : 1)) }
            else { writes.append((HMCharacteristicTypePowerState, percent > 0)) }
            if percent > 0 { writes.append((HMCharacteristicTypeRotationSpeed, percent)) }
            local = { $0.state = percent == 0 ? "off" : "on"; $0.attributes["percentage"] = percent }
        case ("lock", .locked), ("lock", .unlocked):
            let lock = desired == .locked
            writes = [(HMCharacteristicTypeTargetLockMechanismState, lock ? 1 : 0)]
            local = { $0.state = lock ? "locked" : "unlocked" }
        case ("cover", .open), ("cover", .closed):
            let open = desired == .open
            if has(HMCharacteristicTypeTargetPosition) {
                writes = [(HMCharacteristicTypeTargetPosition, open ? 100 : 0)]
            } else {
                writes = [(HMCharacteristicTypeTargetDoorState, open ? 0 : 1)]
            }
            local = { $0.state = open ? "open" : "closed" }
        case ("cover", .level(let raw)):
            let percent = max(0, min(100, raw))
            writes = [(HMCharacteristicTypeTargetPosition, percent)]
            local = { $0.state = percent > 0 ? "open" : "closed"; $0.attributes["current_position"] = percent }
        case ("climate", .on), ("climate", .off):
            let on = desired == .on
            writes = [(HMCharacteristicTypeTargetHeatingCooling, on ? 3 : 0)]
            local = { $0.state = on ? "heat_cool" : "off" }
        default:
            throw HomeActionError.unsupported("HomeKit can't \(desired.title.lowercased()) a \(DomainDisplayName.singular(ref.domain).lowercased())")
        }

        for (type, value) in writes {
            guard let char = chars[type] else {
                throw HomeActionError.unsupported("\(ref.accessory.name) doesn't support that")
            }
            try await char.writeValueAsync(value)
        }
        optimistic(id, local)
    }

    // MARK: - Value helpers

    private func boolVal(_ c: HMCharacteristic?) -> Bool? {
        guard let v = c?.value else { return nil }
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return nil
    }

    private func intVal(_ c: HMCharacteristic?) -> Int? {
        guard let v = c?.value else { return nil }
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let d = v as? Double { return Int(d) }
        return nil
    }

    private func doubleVal(_ c: HMCharacteristic?) -> Double? {
        guard let v = c?.value else { return nil }
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    private static func hvacModeString(_ mode: Int) -> String {
        switch mode {
        case 1: return "heat"
        case 2: return "cool"
        case 3: return "heat_cool"
        default: return "off"
        }
    }

    private static func hvacModeInt(_ mode: String) -> Int {
        switch mode {
        case "heat": return 1
        case "cool": return 2
        case "heat_cool", "auto": return 3
        default: return 0
        }
    }

    private static func hsvToRGB(h: Double, s: Double, v: Double) -> (r: Int, g: Int, b: Int) {
        let c = v * s
        let hp = h / 60.0
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        var r = 0.0, g = 0.0, b = 0.0
        switch hp {
        case 0..<1: (r, g, b) = (c, x, 0)
        case 1..<2: (r, g, b) = (x, c, 0)
        case 2..<3: (r, g, b) = (0, c, x)
        case 3..<4: (r, g, b) = (0, x, c)
        case 4..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        let m = v - c
        return (Int(((r + m) * 255).rounded()), Int(((g + m) * 255).rounded()), Int(((b + m) * 255).rounded()))
    }
}

// MARK: - HomeKit delegates

extension HomeKitConnection: @preconcurrency HMHomeManagerDelegate {
    public func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        authorization = manager.authorizationStatus
        rebuildAllEntities()
    }

    public func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        authorization = status
        rebuildAllEntities()
    }

    public func homeManagerDidUpdatePrimaryHome(_ manager: HMHomeManager) {
        rebuildAllEntities()
    }
}

extension HomeKitConnection: @preconcurrency HMHomeDelegate {
    public func home(_ home: HMHome, didAdd accessory: HMAccessory) { rebuildAllEntities() }
    public func home(_ home: HMHome, didRemove accessory: HMAccessory) { rebuildAllEntities() }
    public func home(_ home: HMHome, didUpdate room: HMRoom, for accessory: HMAccessory) { rebuildAllEntities() }
}

extension HomeKitConnection: @preconcurrency HMAccessoryDelegate {
    public func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        rebuildEntity(serviceUUID: service.uniqueIdentifier)
    }

    public func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        for service in accessory.services { rebuildEntity(serviceUUID: service.uniqueIdentifier) }
    }
}

private extension HMCharacteristic {
    /// `writeValue` as `async`. The characteristic and value never leave the
    /// main actor except through HomeKit's own completion handler.
    @MainActor
    func writeValueAsync(_ value: Any) async throws {
        struct Box: @unchecked Sendable { let value: Any }
        let box = Box(value: value)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeValue(box.value) { error in
                if let error { continuation.resume(throwing: HomeActionError.failed(error.localizedDescription)) }
                else { continuation.resume() }
            }
        }
    }
}

#else

import Foundation
import Observation

/// Stands in where HomeKit doesn't exist (native macOS), so callers needn't
/// fence every mention: it never connects and says why.
@MainActor
@Observable
public final class HomeKitConnection: HomeBackend {
    public private(set) var entities: [String: HAEntity] = [:]
    @ObservationIgnored public var onSensorUpdate: ((HAEntity) -> Void)?

    public init() {}

    public var isConnected: Bool { false }
    public var status: HomeBackendStatus { .unavailable("HomeKit isn't available on the Mac") }
    public var statusDetail: String? { nil }
    public func areaName(forEntity id: String) -> String? { nil }
    public func homeName(forEntity id: String) -> String? { nil }
    public func activate() {}
    public func isSilent(after seconds: TimeInterval = 8, at date: Date = Date()) -> Bool { false }
    public func refreshSensor(entityID: String) {}
    public func performDefaultAction(on entity: HAEntity) {}
    public func setLightBrightness(entityId: String, fraction: Double) {}
    public func setLightColorTempKelvin(entityId: String, kelvin: Int) {}
    public func setSliderFraction(entity: HAEntity, fraction: Double) {}
    public func setClimateTemperature(entityId: String, temperature: Double) {}
    public func setClimateHvacMode(entityId: String, mode: String) {}
    public func setClimateFanMode(entityId: String, mode: String) {}
    public func setClimatePresetMode(entityId: String, mode: String) {}
    public func setClimateSwingMode(entityId: String, mode: String) {}
    public func apply(_ desired: HomeDesiredState, toEntity id: String) async throws {
        throw HomeActionError.unsupported("HomeKit isn't available on the Mac")
    }
}

#endif
