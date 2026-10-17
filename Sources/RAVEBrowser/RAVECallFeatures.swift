//
//  RAVECallFeatures.swift
//  RAVEBrowser
//
//  The opt-in call layer, in its load-bearing order. Raven built each of these
//  for Google Meet on visionOS, keyed on the symptom rather than the hostname,
//  and lifted them 2026-10-17 when spatial-ai-character needed a working call
//  inside its own app (an open immersive space hides every other app's
//  windows, so a call cannot run beside it in Raven):
//
//  1. `RAVEPlatformIdentityScript` — zero touch points, finishing the Mac
//     costume the Safari UA tail starts. First, so every later script sees it.
//  2. `RAVEKeyboardSuppressionScript` — no headset keyboard for a focus the
//     wearer did not ask for (Meet focuses its closed chat composer on join).
//  3. `RAVEWebRTCRecoveryScript` — restarts the remote video the visionOS 27
//     beta leaves unpainted. Below the camera proxy, so it probes and wraps
//     WebKit's real camera, never the canvas stream.
//  4. `RAVECameraProxy`, if any — the page's camera, painted from the app's
//     feed.
//
//  What goes after them is the app's: anything that must see a combined
//  `getUserMedia` before the proxy does (Raven's call audio) comes next, and
//  diagnostics last, so a capability report describes the world after every
//  shim installed. Raven interleaves its own features between these (dark
//  mode after identity, frame extraction and screen share before recovery),
//  so it composes the pieces itself; the relative order above is the contract.
//

#if canImport(WebKit)
import Foundation
import WebKit

public enum RAVECallFeatures {
    /// The call layer for a tab, in order. Append the app's own features
    /// after it, a `RAVEPageReports` among them unless the app has a
    /// diagnostics handler of its own (`reportHandler`).
    ///
    /// - Parameters:
    ///   - cameraProxy: the page's camera, or nil to leave `getUserMedia`'s
    ///     camera to WebKit. Its mode decides whether the WebRTC watchdog may
    ///     probe the real camera (only the Persona's).
    ///   - reportHandler: where the keyboard guard and the watchdog post their
    ///     lines.
    @MainActor
    public static func make(
        cameraProxy: RAVECameraProxy? = nil,
        reportHandler: String = RAVEPageReports.messageHandler
    ) -> [any RAVEPageFeature] {
        var features: [any RAVEPageFeature] = [
            RAVEPlatformIdentityScript.feature(),
            RAVEKeyboardSuppressionScript.feature(reportHandler: reportHandler),
            RAVEWebRTCRecoveryScript.feature(
                probeCamera: cameraProxy?.mode.allowsRealCameraProbe ?? true,
                reportHandler: reportHandler),
        ]
        if let cameraProxy { features.append(cameraProxy) }
        return features
    }
}
#endif
