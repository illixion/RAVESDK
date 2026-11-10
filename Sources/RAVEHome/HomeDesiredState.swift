/*
 RAVEHome - A state to put an accessory in

 What "set this accessory to a desired state" can mean, across both backends:
 power, a level (brightness, fan speed, cover position), a lock, a cover, or
 running a scene. `options(for:)` lists the ones that make sense for an
 entity, so a picker never offers "Lock" for a lamp.
 */

import Foundation

public enum HomeDesiredState: Codable, Hashable, Sendable {
    case off
    case on
    /// Percent, 0...100: brightness, fan speed, or cover position.
    case level(Int)
    case locked
    case unlocked
    case open
    case closed
    /// A scene, script or button: there is no state, it just runs.
    case activate

    /// The state kinds an entity can be put in. `.level` carries a default
    /// that a picker replaces with the person's choice.
    public static func options(for entity: HAEntity) -> [HomeDesiredState] {
        options(forDomain: entity.domain, supportsLevel: entity.supportsSlider)
    }

    public static func options(forDomain domain: String, supportsLevel: Bool) -> [HomeDesiredState] {
        switch domain {
        case "light":
            return supportsLevel ? [.off, .on, .level(20)] : [.off, .on]
        case "fan":
            return supportsLevel ? [.off, .on, .level(30)] : [.off, .on]
        case "switch", "input_boolean", "siren", "remote", "automation", "media_player", "climate":
            return [.off, .on]
        case "humidifier":
            return supportsLevel ? [.off, .on, .level(40)] : [.off, .on]
        case "lock":
            return [.locked, .unlocked]
        case "cover":
            return [.closed, .open, .level(50)]
        case "scene", "script", "button", "input_button":
            return [.activate]
        default:
            return []
        }
    }

    /// Whether anything can be done to an entity at all.
    public static func isControllable(_ entity: HAEntity) -> Bool {
        !options(for: entity).isEmpty
    }

    /// Same kind, ignoring a level's value: how a picker highlights its choice.
    public func sameKind(as other: HomeDesiredState) -> Bool {
        if case .level = self, case .level = other { return true }
        return self == other
    }

    public var isLevel: Bool {
        if case .level = self { return true }
        return false
    }

    /// A verb phrase: "Turn off", "Set to 20%", "Lock".
    public var title: String {
        switch self {
        case .off: return "Turn Off"
        case .on: return "Turn On"
        case .level(let percent): return "Set to \(percent)%"
        case .locked: return "Lock"
        case .unlocked: return "Unlock"
        case .open: return "Open"
        case .closed: return "Close"
        case .activate: return "Run"
        }
    }

    /// The word for the state itself, for a one-line summary ("Off", "20%").
    public var shortTitle: String {
        switch self {
        case .off: return "Off"
        case .on: return "On"
        case .level(let percent): return "\(percent)%"
        case .locked: return "Locked"
        case .unlocked: return "Unlocked"
        case .open: return "Open"
        case .closed: return "Closed"
        case .activate: return "Run"
        }
    }

    /// The accessory's entity state this corresponds to, for choosing its icon
    /// the way it will look once the action has run.
    var iconState: (isOn: Bool, locked: Bool, open: Bool) {
        switch self {
        case .off: return (false, false, false)
        case .on, .activate: return (true, false, false)
        case .level(let percent): return (percent > 0, false, percent > 0)
        case .locked: return (false, true, false)
        case .unlocked: return (false, false, false)
        case .open: return (true, false, true)
        case .closed: return (false, false, false)
        }
    }
}

/// Why `apply` could not do what it was asked.
public enum HomeActionError: LocalizedError, Sendable {
    case notConnected(HomeSource)
    case accessoryMissing
    case unsupported(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected(let source): return "\(source.title) is not connected"
        case .accessoryMissing: return "The accessory is no longer in the home"
        case .unsupported(let what): return what
        case .failed(let message): return message
        }
    }
}
