import DebugLog
import Foundation
import Testing
@testable import RAVENet

@Suite("Transport logging")
struct RAVENetLoggingTests {

    @Test("A logged endpoint drops the query and credentials, where tokens ride")
    func endpointDropsQuery() throws {
        let url = try #require(URL(string: "wss://user:pw@frame.local:8443/api/ws?token=abc123&x=1"))
        let endpoint = RAVEWebSocketTransport.loggableEndpoint(url)
        #expect(endpoint == "frame.local:8443/api/ws")
        #expect(!endpoint.contains("abc123"))
        #expect(!endpoint.contains("pw"))
    }

    @Test("The default sink keeps each value's privacy instead of publishing the line")
    func defaultSinkKeepsPrivacy() {
        let buffer = DebugLogBuffer(mode: .development)
        let logger = DebugLogger(subsystem: "pro.rave.tests.net", category: "websocket",
                                 hub: DebugLogHub(sinks: [buffer], privacyMode: .development))
        let host = "home.example"
        logger.info("connecting to wss://\(host, privacy: .private(mask: .hash)) attempt \(3)")
        let record = buffer.records().first
        #expect(record?.redactedMessage.hasPrefix("connecting to wss://<hash:") == true)
        #expect(record?.redactedMessage.hasSuffix("attempt 3") == true)
    }

    @Test("A transport message withholds every value that is not public")
    func messageWithholdsPrivateValues() {
        let host = "home.example"
        let token = "abc123"
        let message: RAVENetLogMessage = "wss://\(host, privacy: .private(mask: .hash)) \(token, privacy: .sensitive) \(token) attempt \(3) \("ready", privacy: .public)"
        let text = message.redacted
        #expect(text.hasPrefix("wss://<hash:"))
        #expect(text.hasSuffix(" <private> <private> attempt 3 ready"))
        #expect(!text.contains(host))
        #expect(!text.contains(token))
    }
}
