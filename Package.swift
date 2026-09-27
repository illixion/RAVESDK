// swift-tools-version: 6.2
import PackageDescription

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
        .library(name: "RAVEConsole", targets: ["RAVEConsole"]),
        .library(name: "RAVEMedia", targets: ["RAVEMedia"]),
        .library(name: "RAVECamera", targets: ["RAVECamera"]),
        .library(name: "RAVESlideshow", targets: ["RAVESlideshow"]),
        .library(name: "RAVEFilm", targets: ["RAVEFilm"]),
        .library(name: "RAVESpatialAudio", targets: ["RAVESpatialAudio"]),
    ],
    targets: [
        .target(name: "RAVENet"),
        .testTarget(name: "RAVENetTests", dependencies: ["RAVENet"]),
        .target(name: "RAVEUI"),
        // Unit tests, despite the name: SwiftPM has no UI-testing product type
        // and XCUITest needs a host app, so driving these views for real
        // happens in a host app's UI test target (Spatial Stash's, which links
        // RAVEUI and matches on `RAVEA11y`). What runs here is the arithmetic
        // and bookkeeping — the views are visionOS-only and `swift test` is on
        // the host.
        .testTarget(name: "RAVEUITests", dependencies: ["RAVEUI"]),
        // Separate from RAVEUI on purpose: two of the five apps want an
        // on-device log viewer and have no tab bar at all to hang it off.
        .target(name: "RAVEConsole"),
        .testTarget(name: "RAVEConsoleTests", dependencies: ["RAVEConsole"]),
        // Core ML depth + the windowed-stereo warp. visionOS is the product;
        // the depth half also builds on macOS so `swift test` can reach the
        // conversion arithmetic. `RAVEStereoShaders.metal` is a plain target
        // source: Xcode compiles it into the target's own `default.metallib`,
        // which is why nothing here reads the app's default library. (The
        // SwiftPM CLI ignores `.metal` altogether — see RAVEMediaMetal.)
        .target(name: "RAVEMedia"),
        .testTarget(name: "RAVEMediaTests", dependencies: ["RAVEMedia"]),
        // The Persona camera as AVCapture delivers it, plus the realtime H.264
        // encoder and AVCC helpers every consumer of those frames needs. Its
        // own product, not a corner of RAVEMedia, because two of its consumers
        // are broadcast *extensions* (Longwave's and Raven's ReplayKit upload
        // extensions) that have no business linking Core ML and Metal shaders
        // to encode a screen. Builds on macOS so `swift test` reaches the
        // container arithmetic; the interruption notifications are iOS-family
        // only and guarded.
        .target(name: "RAVECamera"),
        .testTarget(name: "RAVECameraTests", dependencies: ["RAVECamera"]),
        // Source-agnostic slideshow lifecycle, local sync payloads, display
        // settings, and render hooks. Apps provide their own data adapters and
        // chrome; depth/stereo stays in RAVEMedia and transport in RAVENet.
        .target(name: "RAVESlideshow", dependencies: ["RAVEMedia"]),
        .testTarget(name: "RAVESlideshowTests", dependencies: ["RAVESlideshow"]),
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
        .target(name: "RAVESpatialAudio"),
        .target(
            name: "RAVEFilm",
            dependencies: ["RAVESpatialAudio"],
            // UIWindow.avDisplayManager is an AVKit category; Swift's autolink
            // drops the framework when nothing else from it is used.
            linkerSettings: [.linkedFramework("AVKit", .when(platforms: [.tvOS, .visionOS]))]
        ),
        .testTarget(name: "RAVEFilmTests", dependencies: ["RAVEFilm"], resources: [.copy("Fixtures")]),
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
