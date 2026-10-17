#if canImport(WebKit)
import Foundation
import Testing
import WebKit
@testable import RAVEBrowser

/// The proxy script's source shape, moved from Raven's `CameraReplayScriptTests`
/// with the script. What is pinned here is what a rename or a reorder would
/// break silently: the call shape the relay speaks, the flags the page keys
/// every branch on, and the fail-closed guards' positions. The behaviour is
/// driven for real in `RAVECameraProxyFailClosedTests`.
@Suite("Camera proxy script")
@MainActor
struct RAVECameraProxyScriptTests {
    private func source(_ mode: RAVECameraProxy.Mode, aspect: Double = 1) -> String {
        RAVECameraProxyScript.userScript(aspect: aspect, mode: mode, offlineCard: .init()).source
    }

    /// The guard and the global name are what make a command sent to a
    /// navigated-away frame a no-op instead of a `TypeError`.
    @Test func buildsACallGuardedByThePresenceOfTheBridge() {
        let js = RAVECameraProxyScript.command("nativeEnd", arguments: ["gone"])
        #expect(js.hasPrefix("window.__ravenReplay && window.__ravenReplay.nativeEnd("))
        #expect(js.hasSuffix(");"))
    }

    /// A device label or a reason is attacker-controlled text.
    @Test func commandArgumentsAreEscaped() {
        let js = RAVECameraProxyScript.command("nativeEnd", arguments: [#"x"); alert(1); ("#])
        #expect(!js.contains(#"x"); alert"#))
    }

    /// Every case reaches the page as the concrete ratio, unmodified — there is
    /// no "leave the camera alone" case to fall back to, since the two sources
    /// (the app's session, WebKit's track) have different native shapes and a
    /// pass-through would publish a different frame depending on which paints.
    @Test func passesTheConfiguredAspectToThePage() {
        #expect(source(.persona(nativeCapture: true), aspect: 0.75).contains("aspect:0.75"))
        #expect(source(.persona(nativeCapture: true), aspect: 1).contains("aspect:1.0"))
    }

    /// With native capture off the script must never ask Swift for the camera —
    /// `nativeStart` is what makes the app's own session take the device away
    /// from WebKit's — so the flag is what the page keys every native branch
    /// on, not a default it could fall into.
    @Test func passesTheNativeCaptureFlagToThePage() {
        #expect(source(.persona(nativeCapture: true)).contains("nativeCapture:true"))
        #expect(source(.persona(nativeCapture: false)).contains("nativeCapture:false"))
    }

    /// The fail-closed flag must never be inferred from anything else, and the
    /// Persona must never carry it.
    @Test func passesTheSourceToThePage() {
        #expect(source(.avatar).contains("avatar:true"))
        #expect(source(.avatar).contains("virtual:null"))
        #expect(source(.persona(nativeCapture: true)).contains("avatar:false"))
        #expect(source(.persona(nativeCapture: true)).contains("virtual:null"))
        // The avatar is native whatever the native-capture switch says, and
        // the virtual device fails closed through the same flag.
        #expect(source(.avatar).contains("var NATIVE_CAPTURE = AVATAR ||"))
        #expect(source(.avatar).contains("var AVATAR = CONFIG.avatar === true || VIRTUAL !== null;"))
    }

    /// The virtual device reaches the page whole: kind, ids and label, escaped.
    @Test func passesTheVirtualDeviceToThePage() {
        let device = RAVEVirtualCaptureDevice(label: #"Avatar "cam""#, deviceId: "abc", groupId: "def")
        let js = source(.virtualDevice(device))
        #expect(js.contains(#"virtual:{kind:"videoinput",deviceId:"abc",groupId:"def",label:"Avatar \"cam\""}"#))
    }

    /// Stable across launches and distinct per label, so a site that
    /// remembers the camera it was given finds the same one next time.
    @Test func virtualDeviceIdsAreStable() {
        let one = RAVEVirtualCaptureDevice(label: "Avatar")
        #expect(one.deviceId == RAVEVirtualCaptureDevice(label: "Avatar").deviceId)
        #expect(one.deviceId != RAVEVirtualCaptureDevice(label: "Other").deviceId)
        #expect(one.deviceId.count == 64 && one.groupId.count == 64 && one.deviceId != one.groupId)
    }

    /// The relay speaks to the page through these; a rename on one side is a
    /// silent black tile on the other, since a call to a missing method on
    /// `__ravenReplay` is swallowed by the guard.
    @Test func exposesTheNativeSourceCommands() {
        let js = source(.persona(nativeCapture: true))
        for name in ["nativeConfig", "nativeChunk", "nativeEnd", "nativeOffline"] {
            #expect(js.contains("\(name): function"), "missing \(name)")
        }
    }

    /// The page has no replay commands — a replay is Swift sending different
    /// chunks (`sendSubstitute`), and the page must not be able to tell.
    @Test func thePageHasNoReplayCommands() {
        let js = source(.persona(nativeCapture: true))
        #expect(!js.contains("startReplay"))
        #expect(!js.contains("stopReplay"))
        #expect(!js.contains("VideoEncoder"))
    }

    /// The page's camera-off switch is reported to Swift: frames from a camera
    /// the page turned off must not be recorded anywhere.
    @Test func reportsTheEnabledSwitchToSwift() {
        #expect(source(.persona(nativeCapture: true)).contains("kind: 'enabled'"))
    }

    /// Chunks travel through `callAsyncJavaScript` with the payload bound as an
    /// argument, so the call body names its parameters and the page function
    /// must take the same five in the same order. A mismatch is not an error
    /// anywhere: the decoder is simply fed `undefined`.
    @Test func nativeChunkCallAndPageFunctionAgreeOnArguments() {
        let js = source(.persona(nativeCapture: true))
        #expect(js.contains("nativeChunk: function (b64, timestamp, key, capturedAt, sentAt)"))
        #expect(RAVECameraProxyScript.nativeChunkCall.contains("nativeChunk(b64, ts, key, capturedAt, sentAt)"))
        // The payload must never be in the source text — that is the whole point.
        #expect(!RAVECameraProxyScript.nativeChunkCall.contains("\""))
    }

    /// The one function every degrade-to-WebKit path goes through refuses a
    /// fail-closed source *before* it touches the source or asks WebKit for
    /// the camera, and so does the hand-over of the real stream.
    @Test func everyFallbackRefusesFailClosedSourcesFirst() throws {
        let js = source(.avatar)
        func body(of function: String, upTo marker: String) throws -> Substring {
            let start = try #require(js.range(of: "function \(function)("))
            let end = try #require(js.range(of: marker, range: start.upperBound..<js.endIndex))
            return js[start.upperBound..<end.lowerBound]
        }
        #expect(try body(of: "fallBackToElement", upTo: "s.source = 'element'").contains("if (AVATAR)"))
        #expect(try body(of: "fallBackToElement", upTo: "nativeGetUserMedia(").contains("if (AVATAR)"))
        #expect(try body(of: "degradeToRealStream", upTo: "settle(real").contains("if (AVATAR)"))
        #expect(try body(of: "startElementLoop", upTo: "requestVideoFrameCallback").contains("if (AVATAR)"))
        #expect(js.contains("if (s.source === 'element' && !AVATAR) { el.srcObject = stream; }"))
    }

    /// The call layer comes out in its load-bearing order, and a fail-closed
    /// proxy turns the watchdog's camera probe off.
    @Test func theCallLayerComesInItsOrder() throws {
        let proxy = RAVECameraProxy(mode: .virtualDevice(.init(label: "Avatar")))
        let features = RAVECallFeatures.make(cameraProxy: proxy)
        #expect(features.count == 4)
        #expect(features.last === proxy)
        let scripts = features.dropLast().compactMap { ($0 as? RAVEUserScriptFeature)?.scripts.first?.source }
        #expect(scripts.count == 3)
        #expect(scripts[0].contains("maxTouchPoints"))
        #expect(scripts[1].contains("__ravenKeyboardGuard"))
        #expect(scripts[2].contains("probeCamera:false"))
        let persona = RAVECallFeatures.make(cameraProxy: RAVECameraProxy(mode: .persona(nativeCapture: true)))
        let recovery = try #require(persona[2] as? RAVEUserScriptFeature)
        #expect(recovery.scripts.first?.source.contains("probeCamera:true") == true)
    }

    /// A distinct global and handler name from the other page features: a
    /// collision would have one feature's commands landing on another's bridge.
    @Test func doesNotCollideWithTheOtherHandlers() {
        #expect(RAVECameraProxyScript.messageHandler != RAVEPageReports.messageHandler)
        #expect(RAVECameraProxyScript.messageHandler == "ravenReplay")
    }
}
#endif
