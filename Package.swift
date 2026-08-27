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
    platforms: [.visionOS(.v26), .macOS(.v14), .iOS(.v26)],
    products: [
        .library(name: "RAVENet", targets: ["RAVENet"]),
        .library(name: "RAVEUI", targets: ["RAVEUI"]),
        .library(name: "RAVEConsole", targets: ["RAVEConsole"]),
        .library(name: "RAVEMedia", targets: ["RAVEMedia"]),
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
    ]
)
