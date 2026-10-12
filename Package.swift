// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Vergence (the public stereo 3D pipeline, ../vergence) is only needed by RAVEMedia and what builds
// on it. Without a vergence checkout beside this one, those targets and products are left out, so
// an app that uses none of them (Apparition, LambdaVision) resolves without it. An app that does
// use them needs the checkout, and gets "no such product" without it.
let hasVergence = FileManager.default.fileExists(atPath: Context.packageDirectory + "/../vergence/Package.swift")
let needsVergence: Set<String> = [
    "RAVEMedia", "RAVEMediaTests", "RAVESlideshow", "RAVESlideshowTests", "RAVEFilm", "RAVEFilmTests", "RAVEFilmLab",
]

let applePlatforms: [Platform] = [.macOS, .iOS, .tvOS, .visionOS]

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
        .library(name: "RAVESlideshowCore", targets: ["RAVESlideshowCore"]),
        .library(name: "RAVESlideshow", targets: ["RAVESlideshow"]),
        .library(name: "RAVERoboFrame", targets: ["RAVERoboFrame"]),
        .library(name: "RAVEFilm", targets: ["RAVEFilm"]),
        .library(name: "RAVESpatialAudio", targets: ["RAVESpatialAudio"]),
        .library(name: "RAVEDeviceSetup", targets: ["RAVEDeviceSetup"]),
        .library(name: "RAVEBrowser", targets: ["RAVEBrowser"]),
        .library(name: "RAVELLM", targets: ["RAVELLM"]),
    ],
    // The two sibling packages, neither depending on a RAVE package, so
    // neither adds a cycle or a RAVESDK <-> RAVEEngine edge (see
    // ~/Projects/CLAUDE.md). Targets that log do it through DebugTrace's
    // `DebugLogger`, so their lines reach the in-app console and debug
    // traces; the console also hosts its capture button. Vergence is the
    // public stereo 3D pipeline RAVEMedia is moving into.
    dependencies: [.package(path: "../DebugTrace")] + (hasVergence ? [.package(path: "../vergence")] : []),
    targets: [
        // DebugTrace only where it builds (Apple platforms): RAVENet and the
        // targets above it also build on Linux for RoboFrame's Pi kiosk, and
        // log there through RAVENet's stderr stand-in.
        .target(name: "RAVENet", dependencies: [.product(name: "DebugTrace", package: "DebugTrace", condition: .when(platforms: applePlatforms))]),
        .testTarget(name: "RAVENetTests", dependencies: ["RAVENet", .product(name: "DebugTrace", package: "DebugTrace", condition: .when(platforms: applePlatforms))]),
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
            .product(name: "DebugTrace", package: "DebugTrace"),
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
        .target(name: "RAVECamera", dependencies: [.product(name: "DebugTrace", package: "DebugTrace")]),
        .testTarget(name: "RAVECameraTests", dependencies: ["RAVECamera"]),
        // Source-agnostic slideshow lifecycle, local sync payloads, display
        // settings, and render hooks. Apps provide their own data adapters and
        // chrome; depth/stereo stays in RAVEMedia and transport in RAVENet.
        // The engine and models are RAVESlideshowCore, Foundation-only so the
        // Pi kiosk builds them on Linux; RAVESlideshow adds the SwiftUI
        // surfaces and re-exports the core.
        .target(name: "RAVESlideshowCore"),
        .testTarget(name: "RAVESlideshowCoreTests", dependencies: ["RAVESlideshowCore"]),
        .target(name: "RAVESlideshow", dependencies: ["RAVESlideshowCore", "RAVEMedia"]),
        // RoboFrame's WebSocket protocol client, shared by every Swift
        // RoboFrame client: Hypnos's remote viewer, RoboFrame's NativeClient
        // and its Linux kiosk. Typed messages, session multiplexing, the
        // present/visibility replay and the media URLs; transport is RAVENet.
        .target(name: "RAVERoboFrame", dependencies: ["RAVENet"]),
        .testTarget(name: "RAVERoboFrameTests", dependencies: ["RAVERoboFrame", "RAVENet"]),
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
        .target(name: "RAVESpatialAudio", dependencies: [.product(name: "DebugTrace", package: "DebugTrace")]),
        .testTarget(name: "RAVESpatialAudioTests", dependencies: ["RAVESpatialAudio"]),
        .target(
            name: "RAVEFilm",
            dependencies: ["RAVESpatialAudio", "RAVEMedia", .product(name: "DebugTrace", package: "DebugTrace")],
            // UIWindow.avDisplayManager is an AVKit category; Swift's autolink
            // drops the framework when nothing else from it is used.
            linkerSettings: [.linkedFramework("AVKit", .when(platforms: [.tvOS, .visionOS]))]
        ),
        .testTarget(name: "RAVEFilmTests", dependencies: ["RAVEFilm"], resources: [.copy("Fixtures")]),
        // Hand an app's configuration, secrets included, to the same app on
        // another device: the receiver shows a QR code carrying a fresh
        // public key, the sender seals the payload to it with HPKE and sends
        // it over Bonjour. First consumer is Hypnos provisioning an Apple TV.
        .target(name: "RAVEDeviceSetup", dependencies: [.product(name: "DebugTrace", package: "DebugTrace")]),
        .testTarget(name: "RAVEDeviceSetupTests", dependencies: ["RAVEDeviceSetup"]),
        // A tool surface over a WKWebView the app already shows — navigate,
        // read (Mozilla's Readability, bundled), numbered elements, marked
        // snapshots, click/type/scroll — for a language model to use pages
        // with nothing site-specific. First consumer is spatial-ai-character's
        // ambient browsing; Raven's assistant is the planned second. The
        // driver needs WebKit, so on tvOS only the model types build.
        // A language model as the apps use one (messages in, text out, a JSON
        // schema, streaming) and Ollama behind it. Foundation only, so it
        // builds everywhere; PCC or the on-device model become further
        // implementations of the same protocol.
        .target(name: "RAVELLM"),
        .testTarget(name: "RAVELLMTests", dependencies: ["RAVELLM"]),
        .target(
            name: "RAVEBrowser",
            dependencies: ["RAVELLM"],
            resources: [.copy("Resources/Readability.js"), .copy("Resources/Readability-LICENSE.md")]
        ),
        .testTarget(name: "RAVEBrowserTests", dependencies: ["RAVEBrowser"]),
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
    "RAVERoboFrame", "RAVERoboFrameTests",
]
package.targets.removeAll { !portableTargets.contains($0.name) }
package.products.removeAll { !portableTargets.contains($0.name) }
#endif
