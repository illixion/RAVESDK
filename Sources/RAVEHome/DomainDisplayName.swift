/*
 RAVEHome - Domain display names

 Turns a raw entity domain (e.g. "binary_sensor") into a human-readable,
 pluralized label ("Binary Sensors") for section headers and filters.
 Domain-keyed so it works for both Home Assistant and HomeKit-mapped entities.
 */

import Foundation

public enum DomainDisplayName {
    /// Curated plural labels for the domains the app commonly shows. Anything
    /// not listed falls back to a generic humanize + pluralize.
    private static let plurals: [String: String] = [
        "light": "Lights",
        "switch": "Switches",
        "sensor": "Sensors",
        "binary_sensor": "Binary Sensors",
        "climate": "Climate",
        "fan": "Fans",
        "cover": "Covers",
        "lock": "Locks",
        "media_player": "Media Players",
        "camera": "Cameras",
        "vacuum": "Vacuums",
        "scene": "Scenes",
        "script": "Scripts",
        "automation": "Automations",
        "input_boolean": "Toggles",
        "humidifier": "Humidifiers",
        "remote": "Remotes",
        "siren": "Sirens",
        "button": "Buttons",
        "number": "Numbers",
        "select": "Selects",
        "person": "People",
        "device_tracker": "Device Trackers",
        "weather": "Weather",
        "alarm_control_panel": "Alarm Panels",
        "water_heater": "Water Heaters",
        "valve": "Valves",
        "update": "Updates",
    ]

    /// A plural, human-readable label for a domain, used for section headers.
    public static func plural(_ domain: String) -> String {
        plurals[domain] ?? pluralize(humanize(domain))
    }

    /// A singular, human-readable label for a domain, used inline in menus.
    public static func singular(_ domain: String) -> String {
        humanize(domain)
    }

    private static func humanize(_ domain: String) -> String {
        domain.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func pluralize(_ text: String) -> String {
        if text.hasSuffix("s") { return text }
        if text.hasSuffix("y") { return String(text.dropLast()) + "ies" }
        return text + "s"
    }
}
