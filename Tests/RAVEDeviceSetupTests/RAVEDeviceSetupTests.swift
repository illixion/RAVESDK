import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
@testable import RAVEDeviceSetup
import Testing
import UniformTypeIdentifiers

private let service = RAVESetupService(urlScheme: "ravetest", bonjourType: "_ravetest-setup._tcp")

private struct Payload: Codable, Sendable, Equatable {
    var server: String
    var apiKey: String
}

@Suite struct RAVESetupCodeTests {
    @Test func linkRoundTrips() throws {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let code = RAVESetupCode(service: service, instance: "Setup 0A1B2C3D", publicKey: key)
        let parsed = try #require(RAVESetupCode(url: code.url, service: service))
        #expect(parsed == code)
    }

    @Test func anotherAppsCodeIsRejected() {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let other = RAVESetupCode(service: RAVESetupService(urlScheme: "other", bonjourType: "_other._tcp"),
                                  instance: "Setup 1", publicKey: key)
        #expect(RAVESetupCode(url: other.url, service: service) == nil)
    }

    @Test func malformedKeyIsRejected() throws {
        let url = try #require(URL(string: "ravetest://setup?v=1&s=Setup%201&k=AAAA"))
        #expect(RAVESetupCode(url: url, service: service) == nil)
    }

    @Test func qrCodeReadsBack() throws {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let code = RAVESetupCode(service: service, instance: "Setup 0A1B2C3D", publicKey: key)
        let modules = try #require(RAVESetupQRCode.cgImage(for: code.url))
        // Vision wants more than one pixel per module; scale as a camera would see it.
        let size = modules.width * 8
        let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.interpolationQuality = .none
        context.draw(modules, in: CGRect(x: 0, y: 0, width: size, height: size))
        let png = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(RAVESetupQRCode.codes(inImageData: png as Data, service: service) == [code])
    }
}

/// A real transfer over Bonjour on this machine.
@Suite(.serialized) @MainActor struct RAVESetupTransferTests {
    private func startedReceiver(onPayload: @escaping @MainActor (Payload) -> Void) async throws -> RAVESetupReceiver<Payload> {
        let receiver = RAVESetupReceiver<Payload>(service: service, onPayload: onPayload)
        receiver.start()
        for _ in 0..<50 where receiver.status == .starting {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(receiver.status == .waiting)
        return receiver
    }

    @Test func payloadArrives() async throws {
        var received: Payload?
        let receiver = try await startedReceiver { received = $0 }
        defer { receiver.stop() }
        let payload = Payload(server: "http://nas:9999", apiKey: "s3cr3t")
        try await RAVESetupSender.send(payload, to: try #require(receiver.code))
        #expect(received == payload)
        #expect(receiver.status == .received)
    }

    @Test func wrongKeyIsDroppedAndTheReceiverKeepsWaiting() async throws {
        var received: Payload?
        let receiver = try await startedReceiver { received = $0 }
        defer { receiver.stop() }
        let real = try #require(receiver.code)
        let forged = RAVESetupCode(service: service, instance: real.instance,
                                   publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
        await #expect(throws: (any Error).self) {
            try await RAVESetupSender.send(Payload(server: "evil", apiKey: "evil"), to: forged, timeout: 5)
        }
        #expect(received == nil)
        #expect(receiver.status == .waiting)

        // The real code still works afterwards.
        try await RAVESetupSender.send(Payload(server: "ok", apiKey: "ok"), to: real)
        #expect(received?.server == "ok")
    }
}
