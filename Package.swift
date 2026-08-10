// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RAVESDK",
    // visionOS is the product focus. macOS is declared because nothing in
    // RAVENet is visionOS-specific and `swift test` needs a host platform to
    // build for — visionOS-only targets added later (RAVEUI) guard with
    // `#if os(visionOS)` rather than forcing the whole package to one platform.
    platforms: [.visionOS(.v26), .macOS(.v14)],
    products: [
        .library(name: "RAVENet", targets: ["RAVENet"]),
    ],
    targets: [
        .target(name: "RAVENet"),
        .testTarget(name: "RAVENetTests", dependencies: ["RAVENet"]),
    ]
)
