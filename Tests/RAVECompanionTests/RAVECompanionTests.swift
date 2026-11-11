import CryptoKit
import Foundation
import Network
import Testing
@testable import RAVECompanion

enum TestGrant: String, Codable, Hashable, Sendable, CaseIterable {
    case screen, audio, input, projects, sshKey
}

typealias Message = RAVEPairingMessage<TestGrant>
let ns = RAVECompanionNamespace.longwave

@Suite("Knock")
struct KnockTests {
    @Test("valid within a minute either side")
    func window() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let minute = RAVECompanionDiscovery.minute(of: now)
        for offset in [-1, 0, 1] as [Int64] {
            let tag = RAVECompanionDiscovery.knockTag(ns, token: "tok", hostID: "mac", deviceID: "hs", minute: minute + offset)
            #expect(RAVECompanionDiscovery.isValidKnock(ns, tag: tag, token: "tok", hostID: "mac", deviceID: "hs", now: now))
        }
        let stale = RAVECompanionDiscovery.knockTag(ns, token: "tok", hostID: "mac", deviceID: "hs", minute: minute - 2)
        #expect(!RAVECompanionDiscovery.isValidKnock(ns, tag: stale, token: "tok", hostID: "mac", deviceID: "hs", now: now))
    }

    @Test("binds token, host and device; fits a TXT entry")
    func binding() {
        let now = Date()
        let tag = RAVECompanionDiscovery.knockTag(ns, token: "tok", hostID: "mac", deviceID: "hs",
                                                  minute: RAVECompanionDiscovery.minute(of: now))
        #expect(!RAVECompanionDiscovery.isValidKnock(ns, tag: tag, token: "other", hostID: "mac", deviceID: "hs", now: now))
        #expect(!RAVECompanionDiscovery.isValidKnock(ns, tag: tag, token: "tok", hostID: "mac2", deviceID: "hs", now: now))
        #expect(!RAVECompanionDiscovery.isValidKnock(ns, tag: tag, token: "tok", hostID: "mac", deviceID: "hs2", now: now))
        #expect(tag.utf8.count < 32)
    }

    @Test("another namespace's tag doesn't open this one's ports")
    func namespaces() {
        let other = RAVECompanionNamespace(serviceStem: "convolution", labelPrefix: "Convolution", urlScheme: "hypnos",
                                           defaultPairPort: 4869, hostAppName: "Convolution")
        let now = Date()
        let tag = RAVECompanionDiscovery.knockTag(other, token: "tok", hostID: "mac", deviceID: "hs",
                                                  minute: RAVECompanionDiscovery.minute(of: now))
        #expect(!RAVECompanionDiscovery.isValidKnock(ns, tag: tag, token: "tok", hostID: "mac", deviceID: "hs", now: now))
        #expect(other.knockServiceType == "_convolution-knock._tcp")
    }
}

@Suite("Pairing exchange")
struct ExchangeTests {
    struct Run {
        let device = RAVEPairingExchange()
        let host = RAVEPairingExchange()
        let deviceID = "device-1"
        let deviceName = "Vision Pro"
        let requested = ["audio", "screen"]
        let sshPublicKey: String? = nil
        var commitment: Data {
            RAVEPairingExchange.commitment(ns, publicKey: device.publicKey, nonce: device.nonce,
                                            deviceID: deviceID, deviceName: deviceName,
                                            requested: requested, sshPublicKey: sshPublicKey)
        }

        func deviceSide(hostPublicKey: Data? = nil) -> RAVEPairingExchange.Agreement? {
            RAVEPairingExchange.agree(
                ns, mine: device, theirPublicKey: hostPublicKey ?? host.publicKey, commitment: commitment,
                devicePublicKey: device.publicKey, deviceNonce: device.nonce,
                hostPublicKey: hostPublicKey ?? host.publicKey, hostNonce: host.nonce,
                hostID: "mac", hostName: "Studio Mac",
                deviceID: deviceID, deviceName: deviceName, requested: requested, sshPublicKey: sshPublicKey
            )
        }

        func hostSide(revealedKey: Data? = nil, revealedNonce: Data? = nil) -> RAVEPairingExchange.Agreement? {
            RAVEPairingExchange.agree(
                ns, mine: host, theirPublicKey: revealedKey ?? device.publicKey, commitment: commitment,
                devicePublicKey: revealedKey ?? device.publicKey, deviceNonce: revealedNonce ?? device.nonce,
                hostPublicKey: host.publicKey, hostNonce: host.nonce,
                hostID: "mac", hostName: "Studio Mac",
                deviceID: deviceID, deviceName: deviceName, requested: requested, sshPublicKey: sshPublicKey
            )
        }
    }

    @Test("both ends agree on code and key")
    func agree() throws {
        let run = Run()
        let d = try #require(run.deviceSide())
        let h = try #require(run.hostSide())
        #expect(d.code == h.code)
        #expect(d.code.count == 6 && d.code.allSatisfy(\.isNumber))
        let grant = RAVEPairingGrant(token: "secret", macID: "mac", macName: "Studio Mac", addresses: ["192.0.2.10"],
                                     grants: ["audio", "screen"])
        #expect(try RAVEPairingExchange.open(RAVEPairingExchange.seal(grant, with: h.key), with: d.key) == grant)
    }

    @Test("a reveal that doesn't match the commitment is rejected")
    func badReveal() {
        let run = Run()
        #expect(run.hostSide(revealedNonce: RAVEPairingExchange.randomNonce()) == nil)
        #expect(run.hostSide(revealedKey: RAVEPairingExchange().publicKey) == nil)
    }

    @Test("something in the middle gets different codes")
    func middle() throws {
        let run = Run()
        let impostor = RAVEPairingExchange()
        let deviceCode = try #require(run.deviceSide(hostPublicKey: impostor.publicKey)).code
        let fake = RAVEPairingExchange()
        let fakeCommitment = RAVEPairingExchange.commitment(
            ns, publicKey: fake.publicKey, nonce: fake.nonce, deviceID: "fake",
            deviceName: "Fake device", requested: nil, sshPublicKey: nil
        )
        let hostCode = try #require(RAVEPairingExchange.agree(
            ns, mine: run.host, theirPublicKey: fake.publicKey, commitment: fakeCommitment,
            devicePublicKey: fake.publicKey, deviceNonce: fake.nonce,
            hostPublicKey: run.host.publicKey, hostNonce: run.host.nonce,
            hostID: "mac", hostName: "Studio Mac",
            deviceID: "fake", deviceName: "Fake device", requested: nil, sshPublicKey: nil
        )).code
        #expect(deviceCode != hostCode)
    }

    @Test("a grant sealed for one key won't open with another")
    func wrongKey() throws {
        let grant = RAVEPairingGrant(token: "secret", macID: "mac", macName: "M", addresses: [])
        let sealed = try RAVEPairingExchange.seal(grant, with: SymmetricKey(size: .bits256))
        #expect(throws: (any Error).self) { try RAVEPairingExchange.open(sealed, with: SymmetricKey(size: .bits256)) }
    }

    @Test("tampering with a sealed grant is rejected")
    func tamperedGrant() throws {
        let grant = RAVEPairingGrant(token: "secret", macID: "mac", macName: "M", addresses: [])
        var sealed = try RAVEPairingExchange.seal(grant, with: SymmetricKey(size: .bits256))
        sealed[sealed.index(before: sealed.endIndex)] ^= 1
        #expect(throws: (any Error).self) {
            try RAVEPairingExchange.open(sealed, with: SymmetricKey(size: .bits256))
        }
    }

    @Test("the transcript binds host values and the app namespace")
    func transcriptBinding() throws {
        let run = Run()
        let agreement = try #require(run.deviceSide())
        let changedID = RAVEPairingExchange.agree(
            ns, mine: run.host, theirPublicKey: run.device.publicKey, commitment: run.commitment,
            devicePublicKey: run.device.publicKey, deviceNonce: run.device.nonce,
            hostPublicKey: run.host.publicKey, hostNonce: run.host.nonce,
            hostID: "mac", hostName: "Studio Mac",
            deviceID: "another-device", deviceName: run.deviceName,
            requested: run.requested, sshPublicKey: run.sshPublicKey
        )
        let changedGrantRequest = RAVEPairingExchange.agree(
            ns, mine: run.host, theirPublicKey: run.device.publicKey, commitment: run.commitment,
            devicePublicKey: run.device.publicKey, deviceNonce: run.device.nonce,
            hostPublicKey: run.host.publicKey, hostNonce: run.host.nonce,
            hostID: "mac", hostName: "Studio Mac",
            deviceID: run.deviceID, deviceName: run.deviceName,
            requested: ["audio", "projects", "screen"], sshPublicKey: run.sshPublicKey
        )
        #expect(changedID == nil)
        #expect(changedGrantRequest == nil)
        let changedHostIdentity = RAVEPairingExchange.agree(
            ns, mine: run.device, theirPublicKey: run.host.publicKey, commitment: run.commitment,
            devicePublicKey: run.device.publicKey, deviceNonce: run.device.nonce,
            hostPublicKey: run.host.publicKey, hostNonce: run.host.nonce,
            hostID: "spoofed-mac", hostName: "Studio Mac",
            deviceID: run.deviceID, deviceName: run.deviceName,
            requested: run.requested, sshPublicKey: run.sshPublicKey
        )
        #expect(changedHostIdentity?.code != run.deviceSide()?.code)
        let changedHostNonce = RAVEPairingExchange.agree(
            ns, mine: run.device, theirPublicKey: run.host.publicKey, commitment: run.commitment,
            devicePublicKey: run.device.publicKey, deviceNonce: run.device.nonce,
            hostPublicKey: run.host.publicKey, hostNonce: Data(repeating: 0x99, count: 32),
            hostID: "mac", hostName: "Studio Mac",
            deviceID: run.deviceID, deviceName: run.deviceName,
            requested: run.requested, sshPublicKey: run.sshPublicKey
        )
        #expect(changedHostNonce?.code != agreement.code)
        #expect(changedHostNonce?.key.withUnsafeBytes { Data($0) } != agreement.key.withUnsafeBytes { Data($0) })

        let other = RAVECompanionNamespace(serviceStem: "other", labelPrefix: "Other", urlScheme: "other",
                                           defaultPairPort: 4859, hostAppName: "Other")
        let otherCommitment = RAVEPairingExchange.commitment(
            other, publicKey: run.device.publicKey, nonce: run.device.nonce,
            deviceID: run.deviceID, deviceName: run.deviceName,
            requested: run.requested, sshPublicKey: run.sshPublicKey
        )
        let otherAgreement = try #require(RAVEPairingExchange.agree(
            other, mine: run.device, theirPublicKey: run.host.publicKey, commitment: otherCommitment,
            devicePublicKey: run.device.publicKey, deviceNonce: run.device.nonce,
            hostPublicKey: run.host.publicKey, hostNonce: run.host.nonce,
            hostID: "mac", hostName: "Studio Mac",
            deviceID: run.deviceID, deviceName: run.deviceName,
            requested: run.requested, sshPublicKey: run.sshPublicKey
        ))
        #expect(otherAgreement.key.withUnsafeBytes { Data($0) } != agreement.key.withUnsafeBytes { Data($0) })
    }

    @Test("messages frame and split across reads")
    func framing() throws {
        let messages: [Message] = [
            .commit(headsetID: "hs", headsetName: "Vision Pro", commitment: Data([1, 2, 3]), requested: [.screen, .projects]),
            .macHello(macID: "mac", macName: "Studio Mac", publicKey: Data(count: 32), nonce: Data(count: 32)),
            .deny,
        ]
        var stream = Data()
        for message in messages { stream.append(try message.framed()) }
        var buffer = Data()
        var received: [Message] = []
        for byte in stream {
            buffer.append(byte)
            while let message = try Message.take(from: &buffer) { received.append(message) }
        }
        #expect(received == messages)
    }

    @Test("an oversized frame throws")
    func oversized() {
        var buffer = Data([0xFF, 0xFF, 0x00, 0x00])
        #expect(throws: (any Error).self) { try Message.take(from: &buffer) }
    }

    @Test("zero-length frames and oversized outgoing messages are rejected")
    func invalidFrameBounds() {
        var empty = Data([0, 0, 0, 0])
        #expect(throws: (any Error).self) { try Message.take(from: &empty) }

        let oversized: Message = .commit(
            headsetID: "hs", headsetName: String(repeating: "x", count: Message.maxBytes),
            commitment: Data(repeating: 0, count: 32), requested: nil
        )
        #expect(throws: (any Error).self) { try oversized.framed() }
    }
}

/// Fixed Swift values shared with the Windows Companion. The v2 commitment
/// binds the client identity and requested capabilities as well as its key.
@Suite("Longwave wire compatibility")
struct GoldenTests {
    struct Golden: Decodable {
        let knockTag, hsPublicKey, macPublicKey, commitment, code, key, sealedGrant, proof, pskAudio: String
        let pskIdentityDevice, pskIdentityLegacy, pairLink, identifyJSON: String
        let messages: [String]
    }

    static let golden: Golden = {
        let url = Bundle.module.url(forResource: "longwave-golden", withExtension: "json")!
        return try! JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }()

    static func data(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    let device = RAVEPairingExchange(
        privateKey: try! .init(rawRepresentation: Data(repeating: 0x11, count: 32)), nonce: Data(repeating: 0x33, count: 32))
    let host = RAVEPairingExchange(
        privateKey: try! .init(rawRepresentation: Data(repeating: 0x22, count: 32)), nonce: Data(repeating: 0x44, count: 32))

    @Test("knock tag")
    func knock() {
        #expect(RAVECompanionDiscovery.knockTag(ns, token: "tok-123", hostID: "MAC-1", deviceID: "HS-1",
                                                minute: 29_000_000) == Self.golden.knockTag)
    }

    @Test("exchange: keys, commitment, code, key, and a Longwave-sealed grant opens")
    func exchange() throws {
        let g = Self.golden
        #expect(Self.hex(device.publicKey) == g.hsPublicKey)
        #expect(Self.hex(host.publicKey) == g.macPublicKey)
        let commitment = RAVEPairingExchange.commitment(
            ns, publicKey: device.publicKey, nonce: device.nonce, deviceID: "device-1",
            deviceName: "Vision Pro", requested: ["audio", "screen"], sshPublicKey: nil
        )
        #expect(Self.hex(commitment) == g.commitment)
        for (mine, theirs) in [(device, host.publicKey), (host, device.publicKey)] {
            let agreement = try #require(RAVEPairingExchange.agree(
                ns, mine: mine, theirPublicKey: theirs, commitment: commitment,
                devicePublicKey: device.publicKey, deviceNonce: device.nonce,
                hostPublicKey: host.publicKey, hostNonce: host.nonce,
                hostID: "MAC-1", hostName: "Studio",
                deviceID: "device-1", deviceName: "Vision Pro",
                requested: ["audio", "screen"], sshPublicKey: nil))
            #expect(agreement.code == g.code)
            #expect(agreement.key.withUnsafeBytes { Self.hex(Data($0)) } == g.key)
            let grant = RAVEPairingGrant(token: "tok-123", macID: "MAC-1", macName: "Studio",
                                        addresses: ["192.0.2.10"], grants: ["audio", "screen"])
            #expect(try RAVEPairingExchange.open(RAVEPairingExchange.seal(grant, with: agreement.key),
                                                 with: agreement.key) == grant)
        }
    }

    @Test("device proof, PSK and PSK identities")
    func credentials() {
        let g = Self.golden
        #expect(Self.hex(RAVECompanionIdentify.proof(ns, token: "tok-123", binding: Data(repeating: 7, count: 32))) == g.proof)
        let audio = RAVECompanionChannel(identityBase: "LongwaveAudio/v5", salt: "Longwave-Audio-PSK-v5")
        #expect(Self.hex(Data(audio.derive(token: "tok-123"))) == g.pskAudio)
        #expect(String(decoding: RAVECompanionCredential(token: "t", deviceID: "HS-1").pskIdentity(base: "LongwaveAudio/v5"),
                       as: UTF8.self) == g.pskIdentityDevice)
        #expect(String(decoding: RAVECompanionCredential(token: "t", deviceID: nil).pskIdentity(base: "LongwaveAudio/v5"),
                       as: UTF8.self) == g.pskIdentityLegacy)
        let identify = RAVECompanionIdentify(deviceID: "HS-1", proof: Data([1, 2, 3]))
        #expect(Self.sameJSON(identify.encoded(), Data(g.identifyJSON.utf8)))
        #expect(RAVECompanionIdentify.decode(Data(g.identifyJSON.utf8)) == identify)
    }

    @Test("pair link")
    func link() throws {
        let link = RAVECompanionPairLink(ns, macID: "MAC-1", name: "Studio Mac", port: 4859,
                                         addresses: ["192.0.2.10", "100.64.0.3"])
        #expect(link.url?.absoluteString == Self.golden.pairLink)
        let parsed = try #require(RAVECompanionPairLink(ns, url: URL(string: Self.golden.pairLink)!))
        #expect(parsed == link)
    }

    @Test("every message Longwave framed decodes, and re-encodes to the same JSON")
    func messages() throws {
        for (index, hex) in Self.golden.messages.enumerated() {
            var buffer = Self.data(hex)
            let message = try #require(try Message.take(from: &buffer), "message \(index)")
            #expect(buffer.isEmpty)
            let reframed = try message.framed()
            #expect(Self.sameJSON(reframed.dropFirst(4), Self.data(hex).dropFirst(4)), "message \(index)")
        }
    }

    /// Key order isn't part of the format (Longwave's own encoder doesn't fix
    /// it), so compare parsed objects.
    static func sameJSON(_ a: Data, _ b: Data) -> Bool {
        guard let x = try? JSONSerialization.jsonObject(with: Data(a)) as? NSDictionary,
              let y = try? JSONSerialization.jsonObject(with: Data(b)) as? NSDictionary else { return false }
        return x.isEqual(y)
    }
}

@Suite("Keyring")
struct KeyringTests {
    @Test("verifies a proof against the claimed device only, and enforces grants")
    func verify() {
        let a = RAVECompanionCredential(token: "token-a", deviceID: "A")
        let b = RAVECompanionCredential(token: "token-b", deviceID: "B")
        let keyring = RAVECompanionKeyring<TestGrant>(ns, entries: [
            .init(credential: a, grants: [.screen]), .init(credential: b, grants: [.audio]),
        ])
        let binding = Data(repeating: 9, count: 32)
        let proofA = RAVECompanionIdentify.proof(ns, token: "token-a", binding: binding)
        #expect(keyring.verify(.init(deviceID: "A", proof: proofA), binding: binding)?.credential == a)
        #expect(keyring.verify(.init(deviceID: "B", proof: proofA), binding: binding) == nil)
        #expect(keyring.verify(.init(deviceID: "A", proof: proofA), binding: Data(repeating: 8, count: 32)) == nil)
        #expect(keyring.allows("A", .screen) && !keyring.allows("A", .audio))
        #expect(keyring.entries(with: .audio).map(\.credential) == [b])

        // A proof captured on one TLS connection cannot be replayed after a
        // new exporter value is negotiated, and revocation takes effect in
        // the next keyring snapshot.
        #expect(keyring.verify(.init(deviceID: "A", proof: proofA), binding: Data(repeating: 10, count: 32)) == nil)
        keyring.replace([.init(credential: b, grants: [.audio])])
        #expect(keyring.verify(.init(deviceID: "A", proof: proofA), binding: binding) == nil)
        #expect(!keyring.allows("A", .screen))
    }
}

@Suite("Locating a host's address")
struct LocatorAddressTests {
    @Test("the lowest-ranked reachable address wins; none reachable keeps the host's first")
    func choice() {
        let addresses = ["192.168.80.1", "172.20.48.233", "100.120.197.67"]
        #expect(RAVECompanionLocator.chooseAddress(addresses, reachable: [1, 2]) == "172.20.48.233")
        #expect(RAVECompanionLocator.chooseAddress(addresses, reachable: [0, 1]) == "192.168.80.1")
        #expect(RAVECompanionLocator.chooseAddress(addresses, reachable: []) == "192.168.80.1")
        #expect(RAVECompanionLocator.chooseAddress([], reachable: []) == nil)
    }

    @Test("an address that doesn't answer is skipped for one that does")
    func skipsTheDeadOne() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port?.rawValue { continuation.yield(port); continuation.finish() }
            }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        var port: UInt16?
        for await value in ready { port = value }
        // 192.0.2.1 is TEST-NET-1: nothing answers there.
        let found = await RAVECompanionLocator.firstReachable(["192.0.2.1", "127.0.0.1"], port: try #require(port),
                                                              timeout: .milliseconds(400))
        #expect(found == "127.0.0.1")
    }

    @Test("a single address, or no port to try, is returned as is")
    func trivialCases() async {
        #expect(await RAVECompanionLocator.firstReachable(["10.0.0.5"], port: 4859) == "10.0.0.5")
        #expect(await RAVECompanionLocator.firstReachable(["10.0.0.5", "10.0.0.6"], port: nil) == "10.0.0.5")
        #expect(await RAVECompanionLocator.firstReachable([], port: 4859) == nil)
    }
}
