/*
 RAVEHome - Entity icon mapping

 Maps a Home Assistant entity (by domain + device_class + state) to an SF
 Symbol. HA ships Material Design Icons (mdi:*) which don't exist in SF
 Symbols, so rather than bundle a font we map the common domains/classes to
 the closest system symbol, with a sensible generic fallback. Domain-keyed, so
 it serves HomeKit-mapped entities too.
 */

import Foundation

public enum EntityIcon {
    public static func symbol(for entity: HAEntity) -> String {
        if entity.domain == "weather" { return WeatherCondition.symbol(entity.state) }
        return symbol(domain: entity.domain, deviceClass: entity.deviceClass, isOn: entity.isOn,
                      locked: entity.state == "locked", open: entity.state == "open")
    }

    /// The symbol for an accessory described by its parts, so a saved action
    /// can show the icon for the state it will leave the accessory in without
    /// a live entity.
    public static func symbol(domain: String, deviceClass: String?, isOn: Bool, locked: Bool = false,
                              open: Bool = false) -> String {
        switch domain {
        case "light":
            return isOn ? "lightbulb.fill" : "lightbulb"
        case "switch":
            // HomeKit outlets and HA's `device_class: outlet` are a wall socket.
            return deviceClass == "outlet" ? (isOn ? "poweroutlet.type.f.fill" : "poweroutlet.type.f") : "switch.2"
        case "fan":
            return "fanblades.fill"
        case "input_boolean":
            return "togglepower"
        case "automation":
            return "bolt.horizontal.fill"
        case "script":
            return "scroll.fill"
        case "scene":
            return "theatermasks.fill"
        case "lock":
            return locked ? "lock.fill" : "lock.open.fill"
        case "cover":
            if deviceClass == "garage" || deviceClass == "garage_door" {
                return open ? "door.garage.open" : "door.garage.closed"
            }
            return open ? "blinds.horizontal.open" : "blinds.horizontal.closed"
        case "climate":
            return "thermometer.medium"
        case "media_player":
            switch deviceClass {
            case "tv": return "tv.fill"
            case "speaker": return "hifispeaker.fill"
            case "receiver": return "hifispeaker.and.appletv.fill"
            default: return "play.rectangle.fill"
            }
        case "camera":
            return "video.fill"
        case "vacuum":
            return "robotic.vacuum"
        case "siren":
            return "speaker.wave.3.fill"
        case "humidifier":
            return "humidity.fill"
        case "remote":
            return "av.remote.fill"
        case "person":
            return "person.fill"
        case "device_tracker":
            return "location.fill"
        case "sun":
            return "sun.max.fill"
        case "binary_sensor":
            return binarySensorSymbol(deviceClass: deviceClass, isOn: isOn)
        case "sensor":
            return sensorSymbol(deviceClass: deviceClass)
        case "button", "input_button":
            return "button.programmable"
        case "number", "input_number":
            return "slider.horizontal.3"
        case "select", "input_select":
            return "list.bullet"
        default:
            return "square.dashed"
        }
    }

    private static func binarySensorSymbol(deviceClass: String?, isOn: Bool) -> String {
        switch deviceClass {
        case "motion": return "figure.walk.motion"
        case "door", "garage_door": return "door.left.hand.closed"
        case "window": return "window.vertical.closed"
        case "moisture": return "drop.fill"
        case "smoke": return "smoke.fill"
        case "occupancy", "presence": return "person.fill.checkmark"
        case "lock": return "lock.fill"
        case "opening": return "rectangle.portrait.and.arrow.right"
        default: return isOn ? "dot.radiowaves.left.and.right" : "circle"
        }
    }

    private static func sensorSymbol(deviceClass: String?) -> String {
        switch deviceClass {
        case "temperature": return "thermometer.medium"
        case "humidity": return "humidity.fill"
        case "pressure": return "gauge.medium"
        case "battery": return "battery.50"
        case "power", "energy": return "bolt.fill"
        case "illuminance": return "sun.max.fill"
        case "co2", "carbon_dioxide": return "carbon.dioxide.cloud.fill"
        case "voltage", "current": return "bolt.fill"
        default: return "chart.line.uptrend.xyaxis"
        }
    }
}

/// Home Assistant `weather.*` conditions as words and symbols.
public enum WeatherCondition {
    public static func title(_ condition: String) -> String {
        if condition == "partlycloudy" { return "Partly cloudy" }
        return condition.replacingOccurrences(of: "-", with: " ").capitalized
    }

    public static func symbol(_ condition: String) -> String {
        switch condition {
        case "sunny": "sun.max.fill"
        case "clear-night": "moon.stars.fill"
        case "partlycloudy": "cloud.sun.fill"
        case "cloudy": "cloud.fill"
        case "fog": "cloud.fog.fill"
        case "rainy": "cloud.rain.fill"
        case "pouring": "cloud.heavyrain.fill"
        case "snowy": "cloud.snow.fill"
        case "snowy-rainy": "cloud.sleet.fill"
        case "hail": "cloud.hail.fill"
        case "lightning", "lightning-rainy": "cloud.bolt.rain.fill"
        case "windy", "windy-variant": "wind"
        case "exceptional": "exclamationmark.triangle.fill"
        default: "cloud.sun.fill"
        }
    }
}
