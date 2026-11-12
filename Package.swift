// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Vergence (the public stereo 3D pipeline, ../vergence) is only needed by RAVEMedia and what builds
// on it. Without a vergence checkout beside this one, those targets and products are left out, so
// an app that uses none of them (Apparition, LambdaVision) resolves without it. An app that does
// use them needs the checkout, and gets "no such product" without it.
let hasVergence = FileManager.default.fileExists(atPath: Context.packageDirectory + "/../vergence/Package.swift")
let needsVergence: Set<String> = [
    "RAVEMedia", "RAVEMediaTests", "RAVESlideshow", "RAVEFilm", "RAVEFilmTests", "RAVEFilmLab",
]

let package = Package(
    name: "RAVESDK",
    // visionOS is the product focus. macOS is declared because nothing in
    // RAVENet is visionOS-specific and `swift test` needs a host platform to
    // build for — visionOS-only targets added later (RAVEUI) guard with
    // `#if os(visionOS)` rather than forcing the whole package to one platform.
    // iOS is declared for the same reason and matters more than it looks:
    // leaving a platform out does not exclude it, it silently gives that
    // platform SwiftPM's own ancient default floor, and RAVEConsole then fails
    // to build for an iOS client with "'Color' is only available in iOS 13.0 or
    // newer" — a version nothing here has ever targeted.
    // tvOS is a real target (Hypnos on Apple TV). What tvOS lacks is fenced
    // with `!os(tvOS)`: pointer-driven views (EQEditorView), the pasteboard,
    // and the open-a-window half of the window-session registry (openWindow capture) and its App Intent.
    platforms: [.visionOS(.v26), .macOS(.v14), .iOS(.v26), .tvOS(.v26)],
    products: [
        .library(name: "RAVENet", targets: ["RAVENet"]),
        .library(name: "RAVEUI", targets: ["RAVEUI"]),
        .library(name: "RAVEMediaCore", targets: ["RAVEMediaCore"]),
        .library(name: "RAVEQuestCore", type: .dynamic, targets: ["RAVEQuestCore"]),
        .library(name: "RAVEConsole", targets: ["RAVEConsole"]),
        .library(name: "RAVEMedia", targets: ["RAVEMedia"]),
        .library(name: "RAVECamera", targets: ["RAVECamera"]),
        .library(name: "RAVEFaceTracking", targets: ["RAVEFaceTracking"]),
        .library(name: "RAVEBroadcast", targets: ["RAVEBroadcast"]),
        .library(name: "RAVESlideshowCore", targets: ["RAVESlideshowCore"]),
        .library(name: "RAVESlideshow", targets: ["RAVESlideshow"]),
        .library(name: "RAVEFilm", targets: ["RAVEFilm"]),
        .library(name: "RAVESpatialAudio", targets: ["RAVESpatialAudio"]),
        .library(name: "RAVEDeviceSetup", targets: ["RAVEDeviceSetup"]),
        .library(name: "RAVECompanion", targets: ["RAVECompanion"]),
        .library(name: "RAVEDebugAccess", targets: ["RAVEDebugAccess"]),
        // The Mac half of RAVEDebugAccess; `Tools/rave-debug` builds and runs it.
        .executable(name: "rave-debug", targets: ["RAVEDebugHelper"]),
        .library(name: "RAVEBrowser", targets: ["RAVEBrowser"]),
        .library(name: "RAVELLM", targets: ["RAVELLM"]),
        .library(name: "RAVEConsent", targets: ["RAVEConsent"]),
        .library(name: "RAVESupport", targets: ["RAVESupport"]),
        .library(name: "RAVELauncher", targets: ["RAVELauncher"]),
        .library(name: "RAVESearch", targets: ["RAVESearch"]),
        .library(name: "RAVEHome", targets: ["RAVEHome"]),
    ],
    // The two sibling packages, neither depending on a RAVE package, so
    // neither adds a cycle or a RAVESDK <-> RAVEEngine edge (see
    // ~/Projects/CLAUDE.md). Targets that only log depend on DebugTrace's
    // small `DebugLog` product (`DebugLogger` and its sinks; no dependencies,
    // builds on Linux): their lines reach the in-app console and debug traces
    // whenever the app links DebugTrace, without these targets pulling it in.
    // The two that use more of DebugTrace link the whole product: RAVEConsole
    // (the log buffer's reader, `DebugTraceUI`'s capture button) and RAVEBrowser
    // (its tool surface is a set of `DebugEndpoint`s). Vergence is the
    // public stereo 3D pipeline RAVEMedia is moving into.
    dependencies: [.package(path: "../DebugTrace")] + (hasVergence ? [.package(path: "../vergence")] : []),
    targets: [
        // DebugLog on every platform: RAVENet and the targets above it also build
        // on Linux for RoboFrame's Pi kiosk, where the facility logs to stderr.
        .target(name: "RAVENet", dependencies: [.product(name: "DebugLog", package: "DebugTrace")]),
        .testTarget(name: "RAVENetTests", dependencies: ["RAVENet", .product(name: "DebugLog", package: "DebugTrace")]),
        .target(name: "RAVEUI", dependencies: ["RAVEMediaCore"]),
        .target(name: "RAVEMediaCore"),
        .target(name: "RAVEQuestCore", dependencies: ["RAVEMediaCore"]),
        // Drives the JSON boundary (`rave_quest_call`) the Quest app calls,
        // against a URLProtocol stub of Jellyfin: no server is ever reached.
        .testTarget(name: "RAVEQuestCoreTests", dependencies: ["RAVEQuestCore", "RAVEMediaCore"]),
        // Unit tests, despite the name: SwiftPM has no UI-testing product type
        // and XCUITest needs a host app, so driving these views for real
        // happens in a host app's UI test target (Spatial Stash's, which links
        // RAVEUI and matches on `RAVEA11y`). What runs here is the arithmetic
        // and bookkeeping — the views are visionOS-only and `swift test` is on
        // the host.
        .testTarget(name: "RAVEUITests", dependencies: ["RAVEUI"]),
        // Separate from RAVEUI on purpose: two of the five apps want an
        // on-device log viewer and have no tab bar at all to hang it off.
        .target(name: "RAVEConsole", dependencies: [
            .product(name: "DebugTrace", package: "DebugTrace"),
            .product(name: "DebugTraceUI", package: "DebugTrace"),
        ]),
        .testTarget(name: "RAVEConsoleTests", dependencies: ["RAVEConsole"]),
        // Core ML depth + the windowed-stereo warp. visionOS is the product;
        // the depth half also builds on macOS so `swift test` can reach the
        // conversion arithmetic. `StereoShaders.metal` is a plain target
        // source: Xcode compiles it into the target's own `default.metallib`,
        // which is why nothing here reads the app's default library. (The
        // SwiftPM CLI ignores `.metal` altogether — see VergenceMetal.)
        .target(name: "RAVEMedia", dependencies: [
            .product(name: "DebugLog", package: "DebugTrace"),
            .product(name: "VergenceApple", package: "vergence"),
        ]),
        .testTarget(name: "RAVEMediaTests", dependencies: ["RAVEMedia"]),
        // The Persona camera as AVCapture delivers it, plus the realtime H.264
        // encoder and AVCC helpers every consumer of those frames needs. Its
        // own product, not a corner of RAVEMedia, because two of its consumers
        // are broadcast *extensions* (Longwave's and Raven's ReplayKit upload
        // extensions) that have no business linking Core ML and Metal shaders
        // to encode a screen. Builds on macOS so `swift test` reaches the
        // container arithmetic; the interruption notifications are iOS-family
        // only and guarded.
        .target(name: "RAVECamera", dependencies: [.product(name: "DebugLog", package: "DebugTrace")]),
        .testTarget(name: "RAVECameraTests", dependencies: ["RAVECamera"]),
        // The wearer's face from their Persona: the Persona camera's frames
        // through Vision's face landmarks, solved into ARKit's 52 blend
        // shapes (framework-free, `FaceSolver`), and those as VRChat OSC.
        // spatial-ai-character puts the face on its performed avatar;
        // Longwave's PC VR path is to send it to VRChat.
        .target(name: "RAVEFaceTracking", dependencies: ["RAVECamera", .product(name: "DebugLog", package: "DebugTrace")]),
        .testTarget(name: "RAVEFaceTrackingTests", dependencies: ["RAVEFaceTracking"]),
        // Publishing to an RTSP server (mediamtx): H.264 and Opus over
        // interleaved RTP on one TCP connection, with RTCP sender reports for
        // A/V sync. Lifted from Longwave's BroadcastCore when
        // spatial-ai-character's program feed became its second consumer. The
        // video encoder is RAVECamera's, reshaped for RTP; Opus is Apple's
        // native AudioToolbox codec.
        .target(name: "RAVEBroadcast", dependencies: ["RAVECamera", .product(name: "DebugLog", package: "DebugTrace")]),
        .testTarget(name: "RAVEBroadcastTests", dependencies: ["RAVEBroadcast"]),
        // Source-agnostic slideshow lifecycle, local sync payloads, display
        // settings, and render hooks. Apps provide their own data adapters and
        // chrome; depth/stereo stays in RAVEMedia and transport in RAVENet.
        // The engine and models are RAVESlideshowCore, Foundation-only so the
        // Pi kiosk builds them on Linux; RAVESlideshow adds the SwiftUI
        // surfaces and re-exports the core.
        .target(name: "RAVESlideshowCore"),
        .testTarget(name: "RAVESlideshowCoreTests", dependencies: ["RAVESlideshowCore"]),
        .target(name: "RAVESlideshow", dependencies: ["RAVESlideshowCore", "RAVEMedia"]),
        // The film player: a film's picture through AVSampleBufferDisplayLayer
        // on a host-clock timebase, and its Atmos objects rendered as spatial
        // sources on the same clock, both served by Hypnos's Jellyfin Atmos
        // Objects plugin. Its object audio uses Synchronization.Atomic, so
        // those types say macOS 15 while the package floor stays at 14 for
        // Longwave's Mac app.
        // A PHASE sound stage fed by pull streams: positioned sources and
        // head-locked beds, head-tracked listener, live room reverb. First
        // consumer is RAVEFilm on tvOS; built generic so a game's mixer
        // (LambdaVision's parked PHASE backend) can feed it too.
        // Also: `RAVEChannelFeed` (live multichannel PCM → host-aligned
        // per-channel pull streams, Longwave's Moonlight surround) and the
        // host-clock alignment RAVEFilm's Atmos objects use.
        .target(name: "RAVESpatialAudio", dependencies: [.product(name: "DebugLog", package: "DebugTrace")]),
        .testTarget(name: "RAVESpatialAudioTests", dependencies: ["RAVESpatialAudio"]),
        .target(
            name: "RAVEFilm",
            dependencies: ["RAVESpatialAudio", "RAVEMedia", .product(name: "DebugLog", package: "DebugTrace")],
            // UIWindow.avDisplayManager is an AVKit category; Swift's autolink
            // drops the framework when nothing else from it is used. iOS and
            // macOS use it for Picture in Picture (FilmPictureInPicture).
            linkerSettings: [.linkedFramework("AVKit")]
        ),
        .testTarget(name: "RAVEFilmTests", dependencies: ["RAVEFilm"], resources: [.copy("Fixtures")]),
        // Hand an app's configuration, secrets included, to the same app on
        // another device: the receiver shows a QR code carrying a fresh
        // public key, the sender seals the payload to it with HPKE and sends
        // it over Bonjour. First consumer is Hypnos provisioning an Apple TV.
        // Also moves them through a file (`RAVESealedFile`): sealed under five EFF words with
        // Argon2id and ChaCha20-Poly1305, for AirDrop, Files and anything else nobody vouches for.
        // CryptoKit has no Argon2, so `CRAVEArgon2` is Monocypher 4.0.2 (BSD-2-Clause or CC0,
        // vendored whole, only `crypto_argon2` is used).
        .target(name: "CRAVEArgon2", exclude: ["LICENCE.md"]),
        .target(name: "RAVEDeviceSetup", dependencies: ["CRAVEArgon2", .product(name: "DebugLog", package: "DebugTrace")]),
        .testTarget(name: "RAVEDeviceSetupTests", dependencies: ["RAVEDeviceSetup"]),
        .target(name: "RAVECompanion", dependencies: [.product(name: "DebugLog", package: "DebugTrace")]),
        .testTarget(name: "RAVECompanionTests", dependencies: ["RAVECompanion"], resources: [.copy("longwave-golden.json")]),
        // Debugging an app from a paired computer: RAVECompanion's pairing with the
        // device as the side that approves, and the TLS-PSK listener DebugTrace's
        // server takes as a transport. The one target that links both.
        .target(name: "RAVEDebugAccess", dependencies: [
            "RAVECompanion",
            .product(name: "DebugLog", package: "DebugTrace"),
            .product(name: "DebugTraceServer", package: "DebugTrace"),
        ]),
        .testTarget(name: "RAVEDebugAccessTests", dependencies: [
            "RAVEDebugAccess", "RAVECompanion",
            .product(name: "DebugTrace", package: "DebugTrace"),
            .product(name: "DebugTraceServer", package: "DebugTrace"),
        ]),
        .executableTarget(name: "RAVEDebugHelper", dependencies: ["RAVEDebugAccess"]),
        // A tool surface over a WKWebView the app already shows — navigate,
        // read (Mozilla's Readability, bundled), numbered elements, marked
        // snapshots, click/type/scroll — for a language model to use pages
        // with nothing site-specific. First consumer is spatial-ai-character's
        // ambient browsing; Raven's assistant is the second. The driver needs
        // WebKit, so on tvOS only the model types build.
        // Also the browser tab core lifted from Raven (2026-10-17): the tab
        // that owns its WKWebView, the page-feature seam, hibernation,
        // profiles, and the opt-in call layer. The camera proxy relays
        // RAVECamera's feeds, hence that dependency; RAVECamera builds on every
        // platform this does, so it is unconditional. DebugTrace for its tool
        // endpoints (`DebugEndpoint`), which is why it is not on DebugLog.
        // A language model as the apps use one (messages in, text out, a JSON
        // schema, streaming) and Ollama behind it. Foundation only, so it
        // builds everywhere; PCC or the on-device model become further
        // implementations of the same protocol.
        .target(name: "RAVELLM"),
        .testTarget(name: "RAVELLMTests", dependencies: ["RAVELLM"]),
        // Typo-tolerant, weighted search over a few text fields per item, in memory (`RAVEFuzzyIndex`), and the
        // text handling a results screen needs (`RAVEFuzzyText`: folding, HTML to text, highlighted excerpts).
        // Lifted from Worldcast's episode search and Hypnos's music search, which each wrote it. Foundation
        // only, so it builds everywhere, Linux included.
        .target(name: "RAVESearch"),
        .testTarget(name: "RAVESearchTests", dependencies: ["RAVESearch"]),
        // Asking before personal data leaves an app's hands: the question
        // (what, where to, a preview of the payload), the 15-minute grants,
        // and where it appears (a window on visionOS/macOS, a sheet on
        // iOS/tvOS). Here and not in DebugTrace: it ships in App Store builds,
        // and DebugTrace cannot import RAVESDK, which depends on it. Logs
        // through DebugLog alone: no registry, trace or server comes with it.
        // Home Assistant and HomeKit behind one `HomeBackend` surface, and the
        // accessory icons, states and saved actions that sit on it. Extracted from
        // Spatial Home; the Hypnos sleep timer is the second consumer.
        .target(name: "RAVEHome", dependencies: ["RAVENet", .product(name: "DebugLog", package: "DebugTrace")]),
        .testTarget(name: "RAVEHomeTests", dependencies: ["RAVEHome"]),
        .target(name: "RAVEConsent", dependencies: [.product(name: "DebugLog", package: "DebugTrace")]),
        .testTarget(name: "RAVEConsentTests", dependencies: ["RAVEConsent"]),
        // The "Hi, I'm Ixion" support card: a one-time welcome sheet and an inline card for
        // Settings that point at GitHub Sponsors. No dependencies, so any app links it. The
        // pose artwork lives once, in Sources/RAVESupport/Poses (see its README).
        .target(name: "RAVESupport", resources: [.copy("Poses")]),
        .testTarget(name: "RAVESupportTests", dependencies: ["RAVESupport"]),
        // A launcher screen: sections of app tiles whose buttons the app defines (open by
        // URL, start a JIT session, or run an app hosted in the same process), plus the
        // shortcuts other apps ask to pin, with the request parsing and the approve sheet.
        // Lifted from Apparition's visionOS Home tab; the super-app host is its second
        // consumer. Its stored shortcut JSON is Apparition's.
        .target(name: "RAVELauncher", dependencies: ["RAVEUI"]),
        .testTarget(name: "RAVELauncherTests", dependencies: ["RAVELauncher"]),
        .target(
            name: "RAVEBrowser",
            dependencies: ["RAVELLM", "RAVECamera", .product(name: "DebugTrace", package: "DebugTrace")],
            resources: [.copy("Resources/Readability.js"), .copy("Resources/Readability-LICENSE.md")]
        ),
        .testTarget(name: "RAVEBrowserTests", dependencies: ["RAVEBrowser", "RAVECamera"]),
        // Mac bench for RAVEBrowser's agent loop against a model on Ollama
        // (`swift run RAVEBrowserLab --model …`). Not a product, like
        // RAVEFilmLab: no app builds it.
        .executableTarget(name: "RAVEBrowserLab", dependencies: ["RAVEBrowser", "RAVELLM"]),
        // Mac bench for RAVEFilm (scripts/run-film-lab.sh). Not a product, so
        // no app builds it. Reads the server and token from the environment so
        // none are committed. An unbundled executable has no Info.plist, so
        // one is embedded in the binary: head tracking needs its
        // NSMotionUsageDescription.
        .executableTarget(
            name: "RAVEFilmLab",
            dependencies: ["RAVEFilm"],
            exclude: ["Info.plist"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                "-Xlinker", Context.packageDirectory + "/Sources/RAVEFilmLab/Info.plist",
            ])]
        ),
    ]
)

if !hasVergence {
    package.products.removeAll { needsVergence.contains($0.name) }
    package.targets.removeAll { needsVergence.contains($0.name) }
}

// Evaluated on Linux (RoboFrame's Pi kiosk, its Docker builds), the package
// offers only the targets that build there, so `swift build` and `swift test`
// don't trip over the Apple-only ones. RAVEQuestCore is left out too: its
// Android builds cross-compile from macOS with their own pinned toolchain.
#if os(Linux)
let portableTargets: Set<String> = [
    "RAVENet", "RAVENetTests",
    "RAVEMediaCore",
    "RAVESlideshowCore", "RAVESlideshowCoreTests",
    "RAVESearch", "RAVESearchTests",
]
package.targets.removeAll { !portableTargets.contains($0.name) }
package.products.removeAll { !portableTargets.contains($0.name) }
#endif
