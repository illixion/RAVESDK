/*
 RAVEHome - Home Assistant entity

 A lightweight value type mirroring a single HA entity's state and attributes,
 as delivered by `get_states` and `state_changed` events. Raw attributes are
 kept as a loosely-typed dictionary; typed accessors expose the fields the UI
 needs (brightness, color temperature, supported color modes, …).

 Everything here is read on the main actor (the connection is @MainActor), so
 the `[String: Any]` attribute bag does not need to be Sendable.
 */

import Foundation


public struct HAEntity: Identifiable {
    public let entityId: String
    public var state: String
    public var attributes: [String: Any]
    public var lastUpdated: Date?

    public var id: String { entityId }

    public init(entityId: String, state: String, attributes: [String: Any], lastUpdated: Date? = nil) {
        self.entityId = entityId
        self.state = state
        self.attributes = attributes
        self.lastUpdated = lastUpdated
    }

    /// The domain portion of the entity id, e.g. "light" for "light.desk".
    public var domain: String {
        guard let dot = entityId.firstIndex(of: ".") else { return entityId }
        return String(entityId[..<dot])
    }

    /// The object id portion, e.g. "desk" for "light.desk".
    public var objectId: String {
        guard let dot = entityId.firstIndex(of: ".") else { return entityId }
        return String(entityId[entityId.index(after: dot)...])
    }

    public var friendlyName: String {
        attribute("friendly_name") ?? objectId.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Material Design Icon string from HA (e.g. "mdi:desk-lamp"), if present.
    public var mdiIcon: String? { attribute("icon") }

    public var deviceClass: String? { attribute("device_class") }

    public var unitOfMeasurement: String? { attribute("unit_of_measurement") }

    public var isUnavailable: Bool {
        state == "unavailable" || state == "unknown" || state == "none"
    }

    public var isOn: Bool {
        if domain == "climate" {
            return state != "off" && !isUnavailable
        }
        return state == "on"
    }

    // MARK: - Capabilities

    /// Domains the app knows how to toggle with a single default action.
    public static let toggleableDomains: Set<String> = [
        "light", "switch", "fan", "input_boolean", "automation",
        "script", "scene", "siren", "humidifier", "remote", "climate"
    ]

    /// Whether tapping the tile should perform a toggle / activate action.
    public var isToggleable: Bool {
        HAEntity.toggleableDomains.contains(domain)
    }

    public var isWeather: Bool { domain == "weather" }

    public var isLight: Bool { domain == "light" }

    /// A read-only measurement entity (temperature, humidity, illuminance, …).
    public var isSensor: Bool { domain == "sensor" }

    /// Controllable accessories use cubes; sensors use flat sensor panels.
    public var canPopOutAsCube: Bool { isToggleable }

    public var canPinSensor: Bool { isSensor || domain == "binary_sensor" }
    public var isBinarySensor: Bool { domain == "binary_sensor" }

    public var sensorStatusLabel: String {
        guard !isUnavailable else { return "Unavailable" }
        guard isBinarySensor else { return state }
        switch deviceClass {
        case "opening", "door", "window", "garage_door": return isOn ? "Open" : "Closed"
        case "motion": return isOn ? "Motion detected" : "No motion"
        case "occupancy", "presence": return isOn ? "Occupied" : "Clear"
        case "moisture": return isOn ? "Leak detected" : "Dry"
        case "smoke": return isOn ? "Smoke detected" : "Clear"
        case "gas": return isOn ? "Gas detected" : "Clear"
        case "battery": return isOn ? "Low battery" : "Normal"
        case "connectivity": return isOn ? "Connected" : "Disconnected"
        default: return isOn ? "Detected" : "Clear"
        }
    }

    /// A compact value string for the sensor cube's hero 3D text — the reading
    /// with its unit glued on (`"22.5°C"`, `"48%"`, `"320 lx"`).
    public var sensorDisplayValue: String {
        guard !isUnavailable else { return "—" }
        let unit = unitOfMeasurement ?? ""
        guard !unit.isEmpty else { return state }
        // Degree and percent hug the number; worded units (lx, ppm, W) get a space.
        let hugs = unit == "%" || unit.hasPrefix("°")
        return hugs ? "\(state)\(unit)" : "\(state) \(unit)"
    }

    // MARK: - Light attributes

    public var supportedColorModes: [String] {
        (attributes["supported_color_modes"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// Brightness 0–255 as reported by HA.
    public var brightness: Int? {
        if let i = attributes["brightness"] as? Int { return i }
        if let d = attributes["brightness"] as? Double { return Int(d) }
        return nil
    }

    /// Brightness as a 0...1 fraction. Zero whenever the light is off — some
    /// backends (HomeKit) keep reporting a bulb's last brightness while it's
    /// off, whereas Home Assistant drops it; gating on `isOn` standardizes both
    /// so an off light shows an empty gauge. Falls back to full when on without
    /// a numeric brightness.
    public var brightnessFraction: Double {
        guard isOn else { return 0 }
        if let b = brightness { return Double(b) / 255.0 }
        return 1.0
    }

    public var supportsBrightness: Bool {
        // Every color mode except "onoff"/"unknown" implies brightness control.
        let brightnessless: Set<String> = ["onoff", "unknown"]
        if supportedColorModes.contains(where: { !brightnessless.contains($0) }) { return true }
        return brightness != nil
    }

    // MARK: - Generic Slider

    public var supportsSlider: Bool {
        switch domain {
        case "light": return supportsBrightness
        case "fan", "cover", "media_player", "humidifier", "climate": return true
        default: return false
        }
    }

    public var sortedFanModes: [String] {
        let modes = (attributes["fan_modes"] as? [Any])?.compactMap { $0 as? String } ?? []
        return modes.sorted { a, b in
            let aDigits = a.filter { $0.isNumber }
            let bDigits = b.filter { $0.isNumber }
            if !aDigits.isEmpty, !bDigits.isEmpty, let aNum = Int(aDigits), let bNum = Int(bDigits), aNum != bNum {
                return aNum < bNum
            }
            let known = ["off": 0, "quiet": 1, "low": 2, "medium": 3, "high": 4, "auto": 5]
            let aKnown = known[a.lowercased()] ?? 99
            let bKnown = known[b.lowercased()] ?? 99
            if aKnown != bKnown {
                return aKnown < bKnown
            }
            return a < b
        }
    }

    public var climateFanModes: [String] {
        let modes = sortedFanModes
        let filtered = modes.filter { $0.lowercased() == "low" || $0.lowercased() == "high" }
        return filtered.isEmpty ? modes : filtered
    }

    public var sliderFraction: Double {
        switch domain {
        case "light": return brightnessFraction
        case "fan":
            if let p = attributes["percentage"] as? Double { return p / 100.0 }
            if let p = attributes["percentage"] as? Int { return Double(p) / 100.0 }
            return isOn ? 1.0 : 0.0
        case "cover":
            if let p = attributes["current_position"] as? Double { return p / 100.0 }
            if let p = attributes["current_position"] as? Int { return Double(p) / 100.0 }
            return (state == "open") ? 1.0 : 0.0
        case "media_player":
            if let v = attributes["volume_level"] as? Double { return v }
            return isOn ? 1.0 : 0.0
        case "humidifier":
            if let h = attributes["humidity"] as? Double { return h / 100.0 }
            if let h = attributes["humidity"] as? Int { return Double(h) / 100.0 }
            return isOn ? 1.0 : 0.0
        case "climate":
            let modes = climateFanModes
            guard !modes.isEmpty else { return 0.0 }
            let current = attributes["fan_mode"] as? String ?? ""
            
            // First try case-insensitive match
            if let idx = modes.firstIndex(where: { $0.lowercased() == current.lowercased() }) {
                return Double(idx + 1) / Double(modes.count)
            }
            
            // If match fails, try parsing numbers (e.g. if current is "50" but mode is "50%")
            let currentDigits = current.filter { $0.isNumber }
            if !currentDigits.isEmpty, let currentNum = Int(currentDigits) {
                for (idx, mode) in modes.enumerated() {
                    let modeDigits = mode.filter { $0.isNumber }
                    if !modeDigits.isEmpty, let modeNum = Int(modeDigits), modeNum == currentNum {
                        return Double(idx + 1) / Double(modes.count)
                    }
                }
            }
            
            return 0.0
        default:
            return isOn ? 1.0 : 0.0
        }
    }

    public var colorTempKelvin: Int? {
        if let i = attributes["color_temp_kelvin"] as? Int { return i }
        if let d = attributes["color_temp_kelvin"] as? Double { return Int(d) }
        return nil
    }

    public var minColorTempKelvin: Int? {
        if let i = attributes["min_color_temp_kelvin"] as? Int { return i }
        if let d = attributes["min_color_temp_kelvin"] as? Double { return Int(d) }
        return nil
    }

    public var maxColorTempKelvin: Int? {
        if let i = attributes["max_color_temp_kelvin"] as? Int { return i }
        if let d = attributes["max_color_temp_kelvin"] as? Double { return Int(d) }
        return nil
    }

    public var supportsColorTemp: Bool {
        supportedColorModes.contains("color_temp")
    }

    /// `rgb_color` as a SwiftUI Color, if the light reports one.
    public var rgbColor: (r: Int, g: Int, b: Int)? {
        guard let arr = attributes["rgb_color"] as? [Any], arr.count >= 3 else { return nil }
        let comps = arr.compactMap { ($0 as? Int) ?? ($0 as? Double).map(Int.init) }
        guard comps.count >= 3 else { return nil }
        return (comps[0], comps[1], comps[2])
    }

    // MARK: - Supported features bitmask

    /// HA's `supported_features` integer bitmask (domain-specific bit meanings).
    public var supportedFeatures: Int {
        if let i = attributes["supported_features"] as? Int { return i }
        if let d = attributes["supported_features"] as? Double { return Int(d) }
        return 0
    }

    // MARK: - Climate
    //
    // For `climate.*` the entity `state` *is* the active HVAC mode
    // (e.g. "off", "auto", "heat"). `ClimateEntityFeature` bits:
    // TARGET_TEMPERATURE=1, TARGET_TEMPERATURE_RANGE=2, TARGET_HUMIDITY=4,
    // FAN_MODE=8, PRESET_MODE=16, SWING_MODE=32, TURN_OFF=128, TURN_ON=256.

    private func doubleAttr(_ key: String) -> Double? {
        if let d = attributes[key] as? Double { return d }
        if let i = attributes[key] as? Int { return Double(i) }
        return nil
    }

    private func stringList(_ key: String) -> [String] {
        (attributes[key] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// The climate's current target temperature setpoint.
    public var targetTemperature: Double? { doubleAttr("temperature") }

    public var currentTemperature: Double? { doubleAttr("current_temperature") }

    public var minTemp: Double { doubleAttr("min_temp") ?? 7 }
    public var maxTemp: Double { doubleAttr("max_temp") ?? 35 }
    public var targetTempStep: Double { doubleAttr("target_temp_step") ?? 0.5 }

    /// Available HVAC modes (includes "off"); the active one is `state`.
    public var hvacModes: [String] { stringList("hvac_modes") }
    public var hvacMode: String { state }

    /// Raw `fan_modes` list (unfiltered, sorted for display).
    public var fanModesAll: [String] { sortedFanModes }
    public var currentFanMode: String? { attributes["fan_mode"] as? String }

    public var presetModes: [String] { stringList("preset_modes") }
    public var presetMode: String? { attributes["preset_mode"] as? String }

    public var swingModes: [String] { stringList("swing_modes") }
    public var swingMode: String? { attributes["swing_mode"] as? String }

    public var climateSupportsTargetTemp: Bool { supportedFeatures & 1 != 0 || targetTemperature != nil }
    public var climateSupportsFanMode: Bool { supportedFeatures & 8 != 0 || !fanModesAll.isEmpty }
    public var climateSupportsPreset: Bool { supportedFeatures & 16 != 0 || !presetModes.isEmpty }
    public var climateSupportsSwing: Bool { supportedFeatures & 32 != 0 || !swingModes.isEmpty }

    // MARK: - Display

    /// A short human-readable state line for tiles and lists.
    public var displayState: String {
        if isUnavailable { return "Unavailable" }
        switch domain {
        case "weather":
            let temperature = (attributes["temperature"] as? NSNumber).map { $0.stringValue } ?? "—"
            return "\(temperature)\(attributes["temperature_unit"] as? String ?? "") · \(WeatherCondition.title(state))"
        case "light":
            guard isOn else { return "Off" }
            if let b = brightness { return "On · \(Int((Double(b) / 255.0 * 100).rounded()))%" }
            return "On"
        case "switch", "fan", "input_boolean", "automation", "siren", "humidifier", "remote":
            return isOn ? "On" : "Off"
        case "scene":
            return "Scene"
        case "script":
            return isOn ? "Running" : "Run"
        case "lock":
            return state.capitalized
        case "cover":
            return state.capitalized
        case "sensor", "binary_sensor":
            if let unit = unitOfMeasurement, !unit.isEmpty {
                return "\(state) \(unit)"
            }
            return state.capitalized
        default:
            return state.capitalized
        }
    }

    // MARK: - Helpers

    private func attribute(_ key: String) -> String? {
        attributes[key] as? String
    }
}
