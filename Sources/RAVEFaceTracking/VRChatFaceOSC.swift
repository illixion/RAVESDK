/*
 RAVEFaceTracking - a face reading as VRChat OSC messages.

 For Longwave's PC VR path, where the wearer plays VRChat on a PC and the
 headset's face tracking should reach their avatar there. VRChat takes two
 kinds of face input over OSC (UDP, port 9000 on the PC running it):

 - **Its own eye tracking**: `/tracking/eye/LeftRightPitchYaw` (degrees,
   pitch positive *down*, yaw positive right, as Longwave's broker already
   sends `CenterPitchYaw`) and `/tracking/eye/EyesClosedAmount` (0 open … 1
   shut). Every avatar with eye bones uses these.
 - **Avatar parameters** (`/avatar/parameters/<name>`) for the rest of the
   face, which only avatars built for face tracking have. Two spellings are
   offered: VRCFaceTracking's "v2" set (`FT/v2/JawOpen`, `FT/v2/EyeLidLeft`,
   … the Unified Expressions avatar templates), and ARKit's names as they are
   (`JawOpen`, `EyeBlinkLeft`, … for "Perfect Sync" style avatars).

 The names of the v2 set follow VRCFaceTracking's simplified parameters as
 published for its avatar templates; check them against an avatar's own
 expression parameters before trusting one that does not move. Nothing here
 opens a socket: the bytes go wherever the caller sends them (Longwave's
 broker sends to VRChat on the PC's loopback).
 */

import Foundation
import simd

/// One OSC message with float arguments, encoded per OSC 1.0: the address
/// and type tags each NUL-terminated and padded to four bytes, then each
/// float big-endian.
public struct OSCMessage: Equatable, Sendable {
    public var address: String
    public var arguments: [Float]

    public init(_ address: String, _ arguments: [Float]) {
        self.address = address
        self.arguments = arguments
    }

    public func encoded() -> Data {
        var data = Data()
        func padded(_ string: String) {
            var bytes = Array(string.utf8)
            bytes.append(0)
            while bytes.count % 4 != 0 { bytes.append(0) }
            data.append(contentsOf: bytes)
        }
        padded(address)
        padded("," + String(repeating: "f", count: arguments.count))
        for value in arguments {
            withUnsafeBytes(of: value.bitPattern.bigEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

public enum VRChatFaceOSC {

    public enum Style: String, Sendable, CaseIterable {
        /// VRCFaceTracking's v2 parameters (Unified Expressions templates).
        case unifiedV2
        /// ARKit's 52 names, for avatars rigged with them.
        case arkit
    }

    public struct Options: Sendable, Equatable {
        public var style: Style = .unifiedV2
        /// Put before every parameter name. VRCFaceTracking's templates
        /// read `FT/v2/…`; older ones `v2/…`.
        public var prefix = "FT/"
        /// Send VRChat's own eye tracking too.
        public var nativeEyes = true
        /// The eye angle a full ±1 eye parameter stands for, radians.
        public var eyeRange: Float = EyeLook.yawLimit

        public init() {}
    }

    /// Everything to send for one reading. `look` is where the eyes look (an
    /// eye tracker's, else the reading's own from the pupils); nil sends no
    /// eye direction. A reading whose face is gone sends a neutral face.
    public static func messages(for reading: FaceReading, look: EyeLook?, options: Options = Options()) -> [OSCMessage] {
        var out: [OSCMessage] = []
        let w = reading.presence
        func s(_ shape: FaceBlendShape) -> Float { reading[shape] * w }
        let blink = SIMD2(s(.eyeBlinkLeft), s(.eyeBlinkRight))
        if options.nativeEyes {
            if let look {
                // Ours: yaw toward the face's own left, pitch up. VRChat's:
                // yaw to the right, pitch down, in degrees.
                func degrees(_ v: Float) -> Float { v * 180 / .pi }
                out.append(OSCMessage("/tracking/eye/LeftRightPitchYaw", [
                    degrees(-look.left.y), degrees(-look.left.x), degrees(-look.right.y), degrees(-look.right.x),
                ]))
            }
            out.append(OSCMessage("/tracking/eye/EyesClosedAmount", [max(blink.x, blink.y)]))
        }
        func parameter(_ name: String, _ value: Float) {
            out.append(OSCMessage("/avatar/parameters/" + options.prefix + name, [value]))
        }
        switch options.style {
        case .arkit:
            for shape in FaceBlendShape.allCases {
                let name = shape.rawValue.prefix(1).uppercased() + shape.rawValue.dropFirst()
                parameter(name, s(shape))
            }
        case .unifiedV2:
            func v2(_ name: String, _ value: Float) { parameter("v2/" + name, value) }
            func signed(_ v: Float) -> Float { max(-1, min(1, v)) }
            // Lids: 0 shut, 0.75 open, 1 wide.
            v2("EyeLidLeft", (1 - blink.x) * 0.75 + s(.eyeWideLeft) * 0.25)
            v2("EyeLidRight", (1 - blink.y) * 0.75 + s(.eyeWideRight) * 0.25)
            v2("EyeSquintLeft", s(.eyeSquintLeft))
            v2("EyeSquintRight", s(.eyeSquintRight))
            v2("EyeWideLeft", s(.eyeWideLeft))
            v2("EyeWideRight", s(.eyeWideRight))
            if let look {
                // −1 left … +1 right, −1 down … +1 up, of the wearer.
                v2("EyeLeftX", signed(-look.left.x / options.eyeRange))
                v2("EyeRightX", signed(-look.right.x / options.eyeRange))
                v2("EyeY", signed((look.left.y + look.right.y) / 2 / options.eyeRange))
            }
            v2("BrowInnerUp", s(.browInnerUp))
            v2("BrowUpLeft", s(.browOuterUpLeft))
            v2("BrowUpRight", s(.browOuterUpRight))
            v2("BrowDownLeft", s(.browDownLeft))
            v2("BrowDownRight", s(.browDownRight))
            v2("BrowExpressionLeft", signed((s(.browOuterUpLeft) + s(.browInnerUp)) / 2 - s(.browDownLeft)))
            v2("BrowExpressionRight", signed((s(.browOuterUpRight) + s(.browInnerUp)) / 2 - s(.browDownRight)))
            v2("JawOpen", s(.jawOpen))
            v2("JawX", signed(s(.jawRight) - s(.jawLeft)))
            v2("MouthClosed", s(.mouthClose))
            v2("MouthX", signed(s(.mouthRight) - s(.mouthLeft)))
            v2("SmileFrownLeft", signed(s(.mouthSmileLeft) - s(.mouthFrownLeft)))
            v2("SmileFrownRight", signed(s(.mouthSmileRight) - s(.mouthFrownRight)))
            v2("MouthStretchLeft", s(.mouthStretchLeft))
            v2("MouthStretchRight", s(.mouthStretchRight))
            v2("LipPucker", s(.mouthPucker))
            v2("LipFunnel", s(.mouthFunnel))
            v2("CheekSquintLeft", s(.cheekSquintLeft))
            v2("CheekSquintRight", s(.cheekSquintRight))
        }
        return out
    }
}
