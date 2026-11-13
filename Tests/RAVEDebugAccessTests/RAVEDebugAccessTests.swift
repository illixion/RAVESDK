import DebugTrace
import DebugTraceServer
import Foundation
import Network
import RAVECompanion
import Testing
@testable import RAVEDebugAccess

@Suite struct RAVEDebugAccessProtocolTests {
    @Test("a record is recognised by a paired computer's token and by no other")
    func advertisement() {
        let record = RAVEDebugAccessProtocol.txtRecord(tokens: ["token-one", "token-two"], nonce: "0011223344556677")
        #expect(record["v"] == "1")
        #expect(RAVEDebugAccessProtocol.matches(txt: record, token: "token-one"))
        #expect(RAVEDebugAccessProtocol.matches(txt: record, token: "token-two"))
        #expect(!RAVEDebugAccessProtocol.matches(txt: record, token: "token-three"))
        // The tag is bound to the record's nonce: a copy under another nonce is nobody's.
        var replayed = record
        replayed["n"] = "8899aabbccddeeff"
        #expect(!RAVEDebugAccessProtocol.matches(txt: replayed, token: "token-one"))
        #expect(!RAVEDebugAccessProtocol.matches(txt: ["v": "2", "n": record["n"]!, "t": record["t"]!], token: "token-one"))
        // No paired computer: a record nobody matches, and still under a TXT entry's limit with many.
        #expect(!RAVEDebugAccessProtocol.matches(txt: RAVEDebugAccessProtocol.txtRecord(tokens: [], nonce: "00"), token: ""))
        let many = RAVEDebugAccessProtocol.txtRecord(tokens: (0..<40).map { "t\($0)" }, nonce: "0011223344556677")
        #expect((many["t"] ?? "").utf8.count + 2 <= 255)
    }

    @Test("names shown to the person are short and printable")
    func names() {
        #expect(RAVEDebugAccessProtocol.displayName("  Pegasus\u{7}\n ", fallback: "A computer") == "Pegasus")
        #expect(RAVEDebugAccessProtocol.displayName("\u{1}\u{2}", fallback: "A computer") == "A computer")
        #expect(RAVEDebugAccessProtocol.displayName(String(repeating: "x", count: 200), fallback: "").count == 80)
    }

    @Test("the identify frame is a little-endian length and the JSON")
    func frame() {
        let identify = RAVECompanionIdentify(deviceID: "computer", proof: Data([1, 2, 3]))
        let framed = RAVEDebugAccessProtocol.frame(identify)
        let length = framed.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        #expect(length == framed.count - 4)
        #expect(RAVECompanionIdentify.decode(framed.dropFirst(4)) == identify)
    }

    @Test("the paired computers survive a relaunch, and an unreadable list is empty")
    func storage() throws {
        let computers = [RAVEDebugComputer(id: "a", name: "Pegasus", pairedAt: Date(timeIntervalSince1970: 1_800_000_000), token: "t")]
        let data = try #require(try RAVEDebugComputerList.encode(computers))
        #expect(RAVEDebugComputerList.decode(data) == computers)
        #expect(try RAVEDebugComputerList.encode([]) == nil)
        #expect(RAVEDebugComputerList.decode(Data("not json".utf8)).isEmpty)
        #expect(RAVEDebugComputerList.decode(nil).isEmpty)
    }

    #if os(macOS)
    @Test("the proxy lets in only its own bearer token")
    func proxyBearer() {
        func head(_ authorization: String?) -> Data {
            Data(("GET /_info HTTP/1.1\r\nHost: 127.0.0.1\r\n" + (authorization.map { "Authorization: \($0)\r\n" } ?? "") + "\r\nbody").utf8)
        }
        #expect(RAVEDebugProxy.authorized(head("Bearer secret"), token: "secret"))
        #expect(RAVEDebugProxy.authorized(head("bearer   secret "), token: "secret"))
        #expect(!RAVEDebugProxy.authorized(head("Bearer other"), token: "secret"))
        #expect(!RAVEDebugProxy.authorized(head("Basic secret"), token: "secret"))
        #expect(!RAVEDebugProxy.authorized(head(nil), token: "secret"))
        // A header in the body is not a header.
        #expect(!RAVEDebugProxy.authorized(Data("GET / HTTP/1.1\r\n\r\nAuthorization: Bearer secret\r\n\r\n".utf8), token: "secret"))
    }

    @Test("records are private files, found by id, prefix or name, and list without their token")
    func records() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RAVEDebugAccessTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let apps = RAVEDebugPairedApps(directory: directory)
        #expect(apps.all().isEmpty)
        let id = try apps.computerID()
        #expect(try apps.computerID() == id)
        let app = RAVEDebugPairedApp(hostID: "ABCDEF12-0000-0000-0000-000000000000", name: "Apparition on Apple Vision Pro",
                                     computerID: id, token: "the-token", addresses: ["192.168.1.20"], host: nil, lastPort: nil,
                                     pairedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try apps.save(app)
        #expect(apps.all() == [app])
        #expect(apps.app("abcdef")?.hostID == app.hostID)
        #expect(apps.app("apparition on apple vision pro")?.hostID == app.hostID)
        #expect(apps.app("Apparition")?.hostID == app.hostID)
        #expect(apps.app("nothing") == nil)
        let file = directory.appendingPathComponent("\(app.hostID).json")
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o077 == 0)
        let summary = try JSONSerialization.data(withJSONObject: app.summary)
        #expect(!String(decoding: summary, as: UTF8.self).contains("the-token"))
        #expect(apps.remove(app.hostID))
        #expect(apps.all().isEmpty)
        // An id that is not an id never becomes a path outside the directory.
        #expect(!apps.remove("../computer-id"))
        #expect(try apps.computerID() == id)
    }
    #endif
}

#if os(macOS)
/// The whole route on this Mac: the app's side and the computer's side in one
/// process, over loopback. Pair by comparing the code, reach the debug server
/// through the proxy, then remove the computer and lose it.
@MainActor
@Suite(.serialized) struct RAVEDebugAccessEndToEndTests {
    @MainActor final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    struct TimedOut: Error {}

    func waitFor<T>(_ what: String, seconds: Double = 15, _ value: @MainActor () -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let value = value() { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out waiting for \(what)")
        throw TimedOut()
    }

    func get(_ port: UInt16, _ path: String, token: String?, method: String = "GET", body: String? = nil) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 30
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((response as! HTTPURLResponse).statusCode, object)
    }

    @Test("a computer pairs by code, reaches the server without a prompt, and is cut off when removed")
    func pairThenDebugThenRemove() async throws {
        let hostIDKey = "RAVEDebugAccessTests.hostID.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: hostIDKey) }
        let storage = RAVEDebugMemoryStorage()
        let access = RAVEDebugAccess(hostName: { "Test App on Test Device" }, storage: storage, hostIDKey: hostIDKey, pairPort: 0)

        let surface = DebugSurface()
        surface.register(.command("echo", "say it back", parameters: [.string("text", "what to say", required: true)]) { arguments in
            ["text": .string(try arguments.requireString("text"))] as JSONValue
        })
        let asked = Box(0)
        let server = DebugTraceServer(surface: surface, configuration: .init(
            ports: 0...0, binding: .none, authentication: .none,
            approval: .custom { _ in asked.value += 1; return .deny }, approvalSound: false,
            transports: [access.transport]))
        try await server.start()
        defer { server.stop() }
        let reloads = Box(0)
        access.onChange = { Task { @MainActor in await server.reloadTransports(); reloads.value += 1 } }
        let transportPort = try #require(server.transportPorts["paired"])

        // The device: its pairing screen opens.
        access.beginPairing()
        let pairPort = try await waitFor("the pairing listener") { access.pairingPort }

        // The computer: told the address, it starts the exchange.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RAVEDebugAccessTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let apps = RAVEDebugPairedApps(directory: directory)
        let events = Box([RAVEDebugPairing.Event]())
        let pairing = RAVEDebugPairing(apps: apps, computerName: "Test Mac", host: "127.0.0.1", port: pairPort)
        let run = Task { @MainActor in await pairing.run { events.value.append($0) } }

        // Both screens show the same six digits, and the device names the computer.
        let shown = try await waitFor("the device's code") { () -> String? in
            if case .confirming(let code, let computer) = access.pairing, computer == "Test Mac" { return code }
            return nil
        }
        _ = try await waitFor("the computer's code") { events.value.contains(.code(shown)) ? true : nil }
        #expect(access.computers.isEmpty)
        // Nothing is granted until the person answers on the device.
        access.answer(true)
        let app = try #require(await run.value)
        #expect(app.name == "Test App on Test Device")
        #expect(app.hostID == access.hostID)
        #expect(access.computers.map(\.name) == ["Test Mac"])
        #expect(access.pairing == .paired(computer: "Test Mac"))
        #expect(apps.all().map(\.hostID) == [access.hostID])
        access.endPairing()
        #expect(access.pairingPort == nil)
        _ = try await waitFor("the listener to take the new key") { reloads.value == 1 ? true : nil }
        #expect(server.transportPorts["paired"] == transportPort)

        // The computer: plain HTTP to the proxy, TLS-PSK from there.
        let proxy = try RAVEDebugProxy(app: app, apps: apps, host: "127.0.0.1", port: transportPort)
        let (localPort, token) = try await proxy.start()
        defer { proxy.stop() }
        let (status, info) = try await get(localPort, "/_info", token: token)
        #expect(status == 200)
        #expect(info["ok"] as? Bool == true)
        // A command with a body goes through whole.
        let (posted, echo) = try await get(localPort, "/echo", token: token, method: "POST", body: #"{"text":"through the tunnel"}"#)
        #expect(posted == 200)
        #expect((echo["data"] as? [String: Any])?["text"] as? String == "through the tunnel")
        // Pairing was the approval: "Allow debug access?" is never asked.
        #expect(asked.value == 0)
        // Without the proxy's own token, nothing is forwarded.
        #expect(try await get(localPort, "/_info", token: nil).0 == 401)
        #expect(try await get(localPort, "/_info", token: "wrong").0 == 401)
        // The record remembers where the app answered.
        #expect(apps.app(app.hostID)?.lastPort == transportPort)

        // A relaunch of the app reads the same computers back.
        let relaunched = RAVEDebugAccess(hostName: { "Test App on Test Device" }, storage: storage, hostIDKey: hostIDKey, pairPort: 0)
        #expect(relaunched.computers == access.computers)
        #expect(relaunched.hostID == access.hostID)

        // Removed on the device: its key is gone, so the same proxy is refused.
        access.remove(access.computers[0].id)
        _ = try await waitFor("the listener to drop the key") { reloads.value == 2 ? true : nil }
        let (gone, error) = try await get(localPort, "/_info", token: token)
        #expect(gone == 502)
        #expect((error["error"] as? [String: Any])?["hint"] != nil)
    }

    @Test("a decline on the device pairs nothing, and the screen keeps waiting")
    func decline() async throws {
        let hostIDKey = "RAVEDebugAccessTests.hostID.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: hostIDKey) }
        let access = RAVEDebugAccess(hostName: { "Test App" }, storage: RAVEDebugMemoryStorage(), hostIDKey: hostIDKey, pairPort: 0)
        access.beginPairing()
        defer { access.endPairing() }
        let pairPort = try await waitFor("the pairing listener") { access.pairingPort }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RAVEDebugAccessTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let apps = RAVEDebugPairedApps(directory: directory)
        let events = Box([RAVEDebugPairing.Event]())
        let pairing = RAVEDebugPairing(apps: apps, computerName: "Test Mac", host: "127.0.0.1", port: pairPort)
        let run = Task { @MainActor in await pairing.run { events.value.append($0) } }
        _ = try await waitFor("the device's code") { () -> Bool? in
            if case .confirming = access.pairing { return true }
            return nil
        }
        access.answer(false)
        #expect(await run.value == nil)
        #expect(access.computers.isEmpty)
        #expect(apps.all().isEmpty)
        #expect(events.value.last == .failed("Pairing was declined on the device."))
        _ = try await waitFor("the screen to wait again") { access.pairing == .waiting ? true : nil }
    }
}
#endif
