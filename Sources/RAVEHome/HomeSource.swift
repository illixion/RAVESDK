/*
 RAVEHome - Home source

 Which backend an accessory belongs to. Its own file, free of everything else,
 so dependency-light types can use it.
 */

import Foundation

/// Which home a given accessory / favorite / action belongs to. Carried
/// alongside entity ids wherever an app crosses a boundary (favorites
/// persistence, a window value, a saved action) so commands route to the
/// owning backend.
public enum HomeSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case homeAssistant
    case homeKit

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .homeAssistant: return "Home Assistant"
        case .homeKit: return "HomeKit"
        }
    }

    public var systemImage: String {
        switch self {
        case .homeAssistant: return "house.fill"
        case .homeKit: return "homekit"
        }
    }

    /// Whether this platform can talk to the source at all. HomeKit has no
    /// native macOS framework (Mac Catalyst only), so the Mac build has
    /// Home Assistant alone.
    public var isSupportedOnThisPlatform: Bool {
        switch self {
        case .homeAssistant: return true
        case .homeKit:
            #if canImport(HomeKit)
            return true
            #else
            return false
            #endif
        }
    }
}
