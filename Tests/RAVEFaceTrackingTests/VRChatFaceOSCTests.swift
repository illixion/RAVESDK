import Foundation
import RAVEFaceTracking
import Testing

@Suite struct VRChatFaceOSCTests {

    @Test func encodesAsOSCSays() {
        // "/a" pads to 4 bytes, ",ff" to 4, then two big-endian floats.
        let bytes = [UInt8](OSCMessage("/a", [1, -2]).encoded())
        #expect(bytes == [0x2F, 0x61, 0, 0, 0x2C, 0x66, 0x66, 0, 0x3F, 0x80, 0, 0, 0xC0, 0, 0, 0])
        // An address of exactly four bytes still gets a NUL, so it pads to
        // eight; an empty type tag string is "," and pads to four.
        #expect(OSCMessage("/abc", []).encoded().count == 12)
    }

    func reading(_ shapes: [FaceBlendShape: Float], presence: Float = 1) -> FaceReading {
        var r = FaceReading()
        r.shapes = shapes
        r.presence = presence
        return r
    }

    func value(_ messages: [OSCMessage], _ address: String) -> [Float]? {
        messages.first { $0.address == address }?.arguments
    }

    @Test func eyesInVRChatsOwnTerms() throws {
        // Looking to the wearer's left (our + yaw) and up: VRChat's yaw is to
        // the right and its pitch down, so both come out negative.
        let look = EyeLook(left: SIMD2(0.2, 0.1), right: SIMD2(0.2, 0.1))
        let messages = VRChatFaceOSC.messages(for: reading([.eyeBlinkLeft: 0.2, .eyeBlinkRight: 0.9]), look: look)
        let eyes = try #require(value(messages, "/tracking/eye/LeftRightPitchYaw"))
        #expect(eyes.count == 4)
        #expect(abs(eyes[0] + 0.1 * 180 / .pi) < 1e-3)
        #expect(abs(eyes[1] + 0.2 * 180 / .pi) < 1e-3)
        #expect(value(messages, "/tracking/eye/EyesClosedAmount") == [0.9])
    }

    @Test func unifiedV2Parameters() throws {
        let messages = VRChatFaceOSC.messages(
            for: reading([.jawOpen: 0.6, .mouthSmileLeft: 0.8, .mouthFrownRight: 0.5, .eyeBlinkLeft: 1]), look: nil)
        #expect(value(messages, "/avatar/parameters/FT/v2/JawOpen") == [0.6])
        #expect(value(messages, "/avatar/parameters/FT/v2/SmileFrownLeft") == [0.8])
        #expect(value(messages, "/avatar/parameters/FT/v2/SmileFrownRight") == [-0.5])
        #expect(value(messages, "/avatar/parameters/FT/v2/EyeLidLeft") == [0])
        #expect(value(messages, "/avatar/parameters/FT/v2/EyeLidRight") == [0.75])
        #expect(value(messages, "/avatar/parameters/FT/v2/EyeLeftX") == nil, "no look, no eye direction")
        #expect(value(messages, "/tracking/eye/LeftRightPitchYaw") == nil)
    }

    @Test func arkitParametersAndALostFace() {
        var options = VRChatFaceOSC.Options()
        options.style = .arkit
        options.prefix = ""
        options.nativeEyes = false
        let messages = VRChatFaceOSC.messages(for: reading([.jawOpen: 0.6], presence: 0.5), look: nil, options: options)
        #expect(messages.count == 52)
        #expect(value(messages, "/avatar/parameters/JawOpen") == [0.3], "eased out with the face")
        let gone = VRChatFaceOSC.messages(for: reading([.jawOpen: 0.6], presence: 0), look: nil, options: options)
        #expect(value(gone, "/avatar/parameters/JawOpen") == [0])
    }
}
