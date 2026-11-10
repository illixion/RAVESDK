import Foundation
import Testing
@testable import RAVEHome

@MainActor
private final class MockHome: HomeBackend {
    var entities: [String: HAEntity]
    var isConnected: Bool
    var failuresLeft: Int
    private(set) var applied: [(HomeDesiredState, String)] = []

    init(entities: [HAEntity] = [], connected: Bool = true, failures: Int = 0) {
        self.entities = Dictionary(uniqueKeysWithValues: entities.map { ($0.entityId, $0) })
        self.isConnected = connected
        self.failuresLeft = failures
    }

    var status: HomeBackendStatus { isConnected ? .connected : .idle }
    var statusDetail: String? { nil }
    func areaName(forEntity id: String) -> String? { "Den" }
    func homeName(forEntity id: String) -> String? { nil }
    func performDefaultAction(on entity: HAEntity) {}
    func setLightBrightness(entityId: String, fraction: Double) {}
    func setLightColorTempKelvin(entityId: String, kelvin: Int) {}
    func setSliderFraction(entity: HAEntity, fraction: Double) {}
    func setClimateTemperature(entityId: String, temperature: Double) {}
    func setClimateHvacMode(entityId: String, mode: String) {}
    func setClimateFanMode(entityId: String, mode: String) {}
    func setClimatePresetMode(entityId: String, mode: String) {}
    func setClimateSwingMode(entityId: String, mode: String) {}

    func apply(_ desired: HomeDesiredState, toEntity id: String) async throws {
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw HomeActionError.failed("unreachable")
        }
        applied.append((desired, id))
    }
}

private func entity(_ id: String, state: String = "on", _ attributes: [String: Any] = [:]) -> HAEntity {
    HAEntity(entityId: id, state: state, attributes: attributes)
}

@Suite struct HomeConfigTests {
    @Test func webSocketURLFollowsTheScheme() {
        #expect(HAConfig(baseURL: "https://home.example/", accessToken: "t").webSocketURL?.absoluteString
                == "wss://home.example/api/websocket")
        #expect(HAConfig(baseURL: "http://192.168.1.2:8123", accessToken: "t").webSocketURL?.absoluteString
                == "ws://192.168.1.2:8123/api/websocket")
        #expect(HAConfig(baseURL: "home.example", accessToken: "t").webSocketURL?.absoluteString
                == "wss://home.example/api/websocket")
        #expect(!HAConfig(baseURL: "home.example", accessToken: "  ").isConfigured)
    }

    @Test func parsesAStateDictionary() {
        let parsed = HAConnection.parseEntity([
            "entity_id": "light.desk", "state": "on",
            "attributes": ["friendly_name": "Desk", "brightness": 128],
            "last_updated": "2026-11-10T21:00:00.123456+00:00",
        ])
        #expect(parsed?.friendlyName == "Desk")
        #expect(parsed?.brightness == 128)
        #expect(parsed?.lastUpdated != nil)
        #expect(HAConnection.parseEntity(["state": "on"]) == nil)
    }
}

@Suite struct HomeDesiredStateTests {
    @Test func offersOnlyWhatFitsTheAccessory() {
        #expect(HomeDesiredState.options(for: entity("lock.front")) == [.locked, .unlocked])
        #expect(HomeDesiredState.options(for: entity("switch.hdmi")) == [.off, .on])
        #expect(HomeDesiredState.options(for: entity("scene.movie")) == [.activate])
        #expect(HomeDesiredState.options(for: entity("sensor.temp")).isEmpty)
        // A dimmable bulb adds a level, an on/off one doesn't.
        let dimmable = entity("light.a", ["supported_color_modes": ["brightness"]])
        let plain = entity("light.b", ["supported_color_modes": ["onoff"]])
        #expect(HomeDesiredState.options(for: dimmable).contains { $0.isLevel })
        #expect(!HomeDesiredState.options(for: plain).contains { $0.isLevel })
    }

    @Test func levelsCompareByKind() {
        #expect(HomeDesiredState.level(10).sameKind(as: .level(80)))
        #expect(!HomeDesiredState.level(10).sameKind(as: .off))
    }

    @Test func aTargetSurvivesCodingAndShowsTheOutcomeIcon() throws {
        let target = HomeActionTarget(source: .homeKit, entityId: "switch.X", name: "TV Plug", room: "Den",
                                      domain: "switch", deviceClass: "outlet", state: .off)
        let back = try JSONDecoder().decode(HomeActionTarget.self, from: JSONEncoder().encode(target))
        #expect(back == target)
        #expect(back.symbol == "poweroutlet.type.f")
        #expect(back.summary == "Den · Turn Off")

        var lamp = target
        lamp.domain = "light"; lamp.deviceClass = nil
        lamp.state = .level(20)
        #expect(lamp.symbol == "lightbulb.fill")
        lamp.state = .off
        #expect(lamp.symbol == "lightbulb")
    }

    @Test func iconsFollowDomainAndClass() {
        #expect(EntityIcon.symbol(domain: "media_player", deviceClass: "tv", isOn: true) == "tv.fill")
        #expect(EntityIcon.symbol(domain: "lock", deviceClass: nil, isOn: false, locked: true) == "lock.fill")
        #expect(EntityIcon.symbol(domain: "cover", deviceClass: "garage", isOn: false, open: true) == "door.garage.open")
        #expect(EntityIcon.symbol(domain: "nonsense", deviceClass: nil, isOn: false) == "square.dashed")
    }
}

@MainActor
@Suite struct HomeActionRunnerTests {
    private func target(_ id: String = "switch.hdmi", _ state: HomeDesiredState = .off) -> HomeActionTarget {
        HomeActionTarget(source: .homeAssistant, entityId: id, name: id, domain: "switch", state: state)
    }

    @Test func appliesEveryTargetInOrder() async {
        let home = MockHome(entities: [entity("switch.hdmi"), entity("light.den")])
        let outcomes = await HomeActionRunner.run(
            [target("switch.hdmi"), target("light.den", .level(15))], backend: { _ in home },
            readyTimeout: .milliseconds(200), retryDelay: .milliseconds(10))
        #expect(outcomes.allSatisfy { $0.succeeded })
        #expect(home.applied.map(\.1) == ["switch.hdmi", "light.den"])
        #expect(home.applied.last?.0 == .level(15))
    }

    @Test func retriesOnceThenSucceeds() async {
        let home = MockHome(entities: [entity("switch.hdmi")], failures: 1)
        let outcomes = await HomeActionRunner.run([target()], backend: { _ in home },
                                                  readyTimeout: .milliseconds(200), retryDelay: .milliseconds(10))
        #expect(outcomes.first?.succeeded == true)
    }

    @Test func reportsAFailureThatSurvivesTheRetry() async {
        let home = MockHome(entities: [entity("switch.hdmi")], failures: 2)
        let outcomes = await HomeActionRunner.run([target()], backend: { _ in home },
                                                  readyTimeout: .milliseconds(200), retryDelay: .milliseconds(10))
        #expect(outcomes.first?.succeeded == false)
        #expect(outcomes.first?.message == "unreachable")
    }

    @Test func reportsAMissingBackendAndAMissingAccessory() async {
        let none = await HomeActionRunner.run([target()], backend: { _ in nil },
                                              readyTimeout: .milliseconds(100), retryDelay: .milliseconds(10))
        #expect(none.first?.succeeded == false)

        let home = MockHome(entities: [])
        let missing = await HomeActionRunner.run([target()], backend: { _ in home },
                                                 readyTimeout: .milliseconds(100), retryDelay: .milliseconds(10))
        #expect(missing.first?.message == HomeActionError.accessoryMissing.errorDescription)
    }
}
