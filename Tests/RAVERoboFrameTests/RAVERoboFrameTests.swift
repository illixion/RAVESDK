import Foundation
import Testing
@testable import RAVERoboFrame

@Suite("Inbound frames")
struct RoboFrameDecodingTests {

    private func message(_ text: String) -> RoboFrameMessage? {
        guard case .message(let message)? = RoboFrameFrames.decode(text)?.kind else { return nil }
        return message
    }

    @Test("A playback frame decodes every field, routing ids included")
    func playback() throws {
        let text = """
        {"action":"playback","sessionIds":["win1","win2"],"payload":{
          "deviceId":"screen1","mergeDriver":null,"interval":15000,"currentList":2,
          "modTags":["rating:s"],
          "current":{"id":4181569,"ext":"jpg"},
          "next":{"id":4516954,"ext":"png"},
          "upcoming":[{"id":4516954,"ext":"png"},{"id":2192588,"ext":"webm","durationMs":122000.4}]
        }}
        """
        let inbound = try #require(RoboFrameFrames.decode(text))
        #expect(inbound.sessionIds == ["win1", "win2"])
        guard case .message(.playback(let playback))? = inbound.kind else {
            Issue.record("not a playback frame")
            return
        }
        #expect(playback.deviceId == "screen1")
        #expect(playback.mergeDriver == nil)
        #expect(playback.interval == 15)
        #expect(playback.currentList == 2)
        #expect(playback.modTags == ["rating:s"])
        #expect(playback.current == RoboFramePost(id: 4181569, ext: "jpg"))
        #expect(playback.next?.id == 4516954)
        #expect(playback.upcoming.map(\.id) == [4516954, 2192588])
        #expect(playback.upcoming.last?.durationMs == 122000)
        #expect(playback.upcoming.last?.isVideo == true)
        #expect(playback.upcoming.last?.isISOMedia == false)
    }

    @Test("A malformed upcoming entry drops alone, and a parked channel has no current")
    func lenientPlayback() {
        let text = #"{"action":"playback","payload":{"current":null,"upcoming":[{"id":"x"},{"id":7,"ext":"mp4","durationMs":0}]}}"#
        guard case .playback(let playback)? = message(text) else {
            Issue.record("not a playback frame")
            return
        }
        #expect(playback.current == nil)
        #expect(playback.interval == nil)
        #expect(playback.upcoming == [RoboFramePost(id: 7, ext: "mp4")])
    }

    @Test("Tag lists accept the legacy flat form")
    func tagLists() {
        #expect(message(#"{"action":"tagLists","payload":[["robot","solo"],["dragon"]]}"#) == .tagLists([["robot", "solo"], ["dragon"]]))
        #expect(message(#"{"action":"tagLists","payload":["robot solo","dragon"]}"#) == .tagLists([["robot", "solo"], ["dragon"]]))
    }

    @Test("A displayState without a state toggles nothing; booleans and HA strings both work")
    func displayState() {
        #expect(message(#"{"action":"displayState","payload":{"target":"screen1"}}"#) == nil)
        #expect(message(#"{"action":"displayState","payload":{"target":"screen1","state":"off"}}"#) == .displayState(target: "screen1", on: false))
        #expect(message(#"{"action":"displayState","payload":{"target":"screen1","state":"on"}}"#) == .displayState(target: "screen1", on: true))
        #expect(message(#"{"action":"displayState","payload":{"target":"screen1","state":false}}"#) == .displayState(target: "screen1", on: false))
        #expect(message(#"{"action":"setSuppress","payload":{"target":"screen1","state":"on"}}"#) == .suppress(target: "screen1", on: true))
        #expect(message(#"{"action":"setBrightness","payload":{"target":"screen1","brightness":64}}"#) == .brightness(target: "screen1", value: 64))
        // Out of Int's range: dropped, not a trap.
        #expect(message(#"{"action":"setBrightness","payload":{"target":"screen1","brightness":1e19}}"#) == nil)
    }

    @Test("Effect frames and sensor updates")
    func effects() {
        #expect(message(##"{"action":"showText","payload":{"text":"Hi","bgColorHex":"#ff0000"}}"##) == .alert(RoboFrameAlert(text: "Hi", backgroundHex: "#ff0000")))
        #expect(message(#"{"action":"playScene","payload":{"streamId":"aquarium","rtsp":"rtsp://s:8554/aquarium"}}"#)
            == .playScene(RoboFrameScene(streamId: "aquarium", rtsp: URL(string: "rtsp://s:8554/aquarium"), whep: nil)))
        #expect(message(#"{"action":"stopScene"}"#) == .stopScene)
        #expect(message(#"{"action":"searchEmpty","payload":{"query":"cats"}}"#) == .searchEmpty(query: "cats"))
        #expect(message(#"{"action":"update","payload":{"entity":"sensor.t","state":"12.4","attributes":{"unit_of_measurement":"°C","friendly_name":"Outdoor"}}}"#)
            == .sensor(RoboFrameSensorReading(entityId: "sensor.t", state: "12.4", friendlyName: "Outdoor", unit: "°C")))
    }

    @Test("Liveness frames, unknown actions and non-frames")
    func controlFrames() {
        #expect(RoboFrameFrames.decode(#"{"action":"ping"}"#)?.kind == .ping)
        #expect(RoboFrameFrames.decode(#"{"action":"pong"}"#)?.kind == .pong)
        #expect(RoboFrameFrames.decode(#"{"action":"mjpgstreaming","payload":{}}"#)?.kind == nil)
        #expect(RoboFrameFrames.decode("not json") == nil)
    }
}

@Suite("Outbound frames")
struct RoboFrameEncodingTests {

    private func object(_ text: String?) throws -> [String: Any] {
        let data = Data(try #require(text).utf8)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Only session-scoped actions carry the sessionId")
    func sessionScope() throws {
        let ready = try object(RoboFrameFrames.encode(action: "imageReady", sessionId: "win1", payload: ["id": 3]))
        #expect(ready["sessionId"] as? String == "win1")
        let visibility = try object(RoboFrameFrames.encode(action: "visibility", sessionId: "win1", payload: ["deviceId": "d", "visible": true]))
        #expect(visibility["sessionId"] == nil)
        #expect(RoboFrameFrames.encode(action: "pong") == #"{"action":"pong"}"#)
    }

    @Test("slideshowConfig leaves out unset variant fields")
    func slideshowConfig() {
        let minimal = RoboFrameFrames.slideshowConfigPayload(RoboFrameSlideshowConfig(deviceId: "d", intervalMs: 15_000))
        #expect(Set(minimal.keys) == ["deviceId", "interval", "modTags", "bright"])
        let kiosk = RoboFrameFrames.slideshowConfigPayload(RoboFrameSlideshowConfig(
            deviceId: "d", intervalMs: 15_000, ratio: 1.778, width: 1920, height: 1080, convert: true, lowmem: true
        ))
        #expect(kiosk["width"] as? Int == 1920)
        #expect(kiosk["lowmem"] as? Bool == true)
        #expect(kiosk["gif"] == nil)
    }
}

@Suite("Scene state")
struct RoboFrameSceneStateTests {

    @Test("Visibility ORs across a device's sessions; presence stays per session")
    func aggregation() {
        var scene = RoboFrameSceneState()
        scene.report(sessionId: "a", deviceId: "room", present: true, visible: true)
        scene.report(sessionId: "b", deviceId: "room", present: true, visible: false)
        #expect(scene.flush() == [
            .present(sessionId: "a", deviceId: "room", present: true),
            .present(sessionId: "b", deviceId: "room", present: true),
            .visibility(deviceId: "room", visible: true),
        ])
        scene.report(sessionId: "a", deviceId: "room", present: false, visible: false)
        #expect(scene.flush() == [
            .present(sessionId: "a", deviceId: "room", present: false),
            .visibility(deviceId: "room", visible: false),
        ])
        #expect(scene.flush().isEmpty)
        #expect(!scene.allAbsent)
    }

    @Test("Removing a device's last visible session emits its OFF edge once")
    func removalEdge() {
        var scene = RoboFrameSceneState()
        scene.report(sessionId: "a", deviceId: "room", present: true, visible: true)
        _ = scene.flush()
        scene.remove(sessionId: "a")
        #expect(scene.flush() == [.visibility(deviceId: "room", visible: false)])
        #expect(scene.flush().isEmpty)
        #expect(scene.allAbsent)
    }

    @Test("A forced flush after a reconnect re-states everything")
    func forcedReplay() {
        var scene = RoboFrameSceneState()
        scene.report(sessionId: "a", deviceId: "room", present: true, visible: true)
        _ = scene.flush()
        #expect(scene.flush(force: true) == [
            .present(sessionId: "a", deviceId: "room", present: true),
            .visibility(deviceId: "room", visible: true),
        ])
    }

    @Test("A session's presence waits until it has joined; visibility doesn't")
    func presenceWaitsForJoin() {
        var scene = RoboFrameSceneState()
        scene.report(sessionId: "a", deviceId: "room", present: true, visible: true)
        scene.report(sessionId: "b", deviceId: "room", present: true, visible: false)
        #expect(scene.flush(joined: ["a"]) == [
            .present(sessionId: "a", deviceId: "room", present: true),
            .visibility(deviceId: "room", visible: true),
        ])
        #expect(scene.flush(joined: ["a"]).isEmpty)
        #expect(scene.flush(joined: ["a", "b"]) == [.present(sessionId: "b", deviceId: "room", present: true)])
    }
}

@Suite("Slideshow items")
struct RoboFrameSlideshowItemTests {

    @Test("A post survives the round trip through a slideshow item")
    func roundTrip() {
        let video = RoboFramePost(id: 2192588, ext: "webm", durationMs: 122_000)
        #expect(video.slideshowItem.mediaKind == .video)
        #expect(video.slideshowItem.duration == 122)
        #expect(RoboFramePost(slideshowItem: video.slideshowItem) == video)
        #expect(RoboFramePost(id: 7, ext: "jpg").slideshowItem.mediaKind == .image)
    }
}

@Suite("Endpoint URLs")
struct RoboFrameEndpointTests {

    @Test("A bare address means https, and the socket URL carries the token")
    func webSocketURL() throws {
        let endpoint = try #require(RoboFrameEndpoint(server: " frame.local:3123 ", accessToken: "t0k", deviceId: "d"))
        #expect(endpoint.baseURL.absoluteString == "https://frame.local:3123")
        #expect(endpoint.webSocketURL?.absoluteString == "wss://frame.local:3123/rpc/ws?token=t0k")
    }

    @Test("A kiosk's configured socket URL gives back its HTTP base")
    func fromWebSocketURL() throws {
        let socket = try #require(URL(string: "ws://100.103.115.47:3123/rpc/ws"))
        let endpoint = try #require(RoboFrameEndpoint(webSocketURL: socket, accessToken: "t", deviceId: "slideshow_display"))
        #expect(endpoint.baseURL.absoluteString == "http://100.103.115.47:3123")
        #expect(endpoint.webSocketURL?.absoluteString == "ws://100.103.115.47:3123/rpc/ws?token=t")
    }

    @Test("A pasted token's whitespace is trimmed for every route, not just the socket")
    func trimmedToken() throws {
        var endpoint = try #require(RoboFrameEndpoint(server: "http://frame.local:3123", accessToken: " t\n", deviceId: "d"))
        #expect(endpoint.webSocketURL?.absoluteString == "ws://frame.local:3123/rpc/ws?token=t")
        #expect(endpoint.url(path: "save", postID: 1)?.absoluteString == "http://frame.local:3123/save?id=1&deviceId=d&token=t")
        endpoint.accessToken = "u \n"
        #expect(endpoint.url(path: "history.json")?.absoluteString == "http://frame.local:3123/history.json?deviceId=d&token=u")
    }

    @Test("A + in the token or deviceId is escaped, not left for the server to read as a space")
    func plusEscaped() throws {
        let endpoint = try #require(RoboFrameEndpoint(server: "http://frame.local:3123", accessToken: "a+b/c=", deviceId: "kitchen+1"))
        for url in [endpoint.webSocketURL, endpoint.url(path: "save", postID: 1)] {
            let query = try #require(url?.query(percentEncoded: true))
            #expect(!query.contains("+"))
            let items = URLComponents(string: try #require(url?.absoluteString))?.queryItems ?? []
            #expect(items.first { $0.name == "token" }?.value == "a+b/c=")
        }
        #expect(endpoint.url(path: "save")?.query(percentEncoded: true)?.contains("deviceId=kitchen%2B1") == true)
    }

    @Test("/get carries the variant, then the deviceId and token")
    func mediaURL() throws {
        let endpoint = try #require(RoboFrameEndpoint(server: "http://frame.local:3123", accessToken: "t", deviceId: "d"))
        let url = endpoint.mediaURL(postID: 42, options: RoboFrameMediaOptions(width: 1920, height: 1080, lowmem: true, vcodec: "h264"))
        #expect(url?.absoluteString == "http://frame.local:3123/get?id=42&record=0&width=1920&height=1080&lowmem=1&vcodec=h264&deviceId=d&token=t")
        #expect(endpoint.url(path: "history.json")?.absoluteString == "http://frame.local:3123/history.json?deviceId=d&token=t")
        let poster = endpoint.mediaURL(postID: 7, options: RoboFrameMediaOptions(width: 72, height: 72, poster: true))
        #expect(poster?.absoluteString == "http://frame.local:3123/get?id=7&record=0&width=72&height=72&poster=1&deviceId=d&token=t")
    }

    @Test("/history.json decodes newest first, and a missing list is empty")
    func history() throws {
        let json = #"{"history":[{"id":3,"ext":"mp4"},{"id":1,"ext":"jpg"}],"groups":[{"deviceId":"a","posts":[{"id":3,"ext":"mp4"}]}]}"#
        let history = try JSONDecoder().decode(RoboFrameHistory.self, from: Data(json.utf8))
        #expect(history.history.map(\.id) == [3, 1] && history.history[0].isVideo)
        #expect(history.groups.map(\.id) == ["a"])
        #expect(try JSONDecoder().decode(RoboFrameHistory.self, from: Data("{}".utf8)) == RoboFrameHistory(history: []))
    }
}
