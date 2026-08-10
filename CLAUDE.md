# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**RAVE SDK** — *Robot-Assisted Vision Enhancements*, the **app-shaped** half of the RAVE
packages: general UI, app networking, on-device diagnostics viewing, and (planned) camera
and 2D/3D media conversion.

Its sibling is **RAVE Engine** (`../RAVEEngine`), the XR/game-shaped half — input, frame
diagnostics, RealityKit/CompositorServices scaffolding, PCVR.

**The two are siblings with no dependency between them, in either direction.** That is a
hard rule, not an accident: Engine's stated future is a Mac port, and it must be able to
get there on its own schedule without dragging visionOS-only SDK targets along. An app
that needs both simply links both. If you find yourself wanting to `import RAVEEngine`
here (or the reverse), the thing you want belongs in the app, or needs duplicating.

## Build and test

```bash
swift test                                    # all host-runnable targets
swift test --filter RAVELogFilterTests        # one suite
swift test --filter "RAVELogFilterTests/searchMatchesBothFields"   # one test

# visionOS build — the scheme is "<name>-Package", NOT "RAVESDK"
xcodebuild -scheme RAVESDK-Package -sdk xros -destination 'generic/platform=visionOS' build
```

**`-sdk xros` is required.** Without it, `xcodebuild -destination 'generic/platform=visionOS'`
reports `** BUILD SUCCEEDED **` while compiling nothing, after printing
`Supported platforms for the buildables in the current scheme is empty`. A "successful"
build that names no source files did not happen.

`swift test` only exercises the framework-free targets. Anything guarded by
`#if os(visionOS)` is compiled by the `xcodebuild` line and by nothing else, so run both.

## Platform declaration

`Package.swift` declares `[.visionOS(.v26), .macOS(.v14)]`. visionOS is the product;
macOS exists so `swift test` has a host to build for, and because `RAVEConsole` genuinely
runs there (Longwave's Mac app uses it).

Guard visionOS-only code with **`#if os(visionOS)`**, not `#if canImport(SwiftUI)`.
SwiftUI imports fine on macOS — it is `CustomHoverEffect`, `glassBackgroundEffect` and
ornaments that do not exist there. Getting this wrong fails only under `swift test`, which
is easy to skip.

## Targets

| Target | Purpose |
|---|---|
| `RAVENet` | WebSocket transport: reconnect, keepalive, path gating, wake probing |
| `RAVEUI` | Ornament tab bar, hover effects, grid column layout, window-session registry |
| `RAVEConsole` | On-device log viewer over `OSLogStore` |

### RAVENet — the transport never decides it is ready

This merges two independently-hardened clients (Spatial Stash's `RemoteWebSocketClient`,
Spatial Home's `HAConnection`). The seam that makes it work: **readiness is app-declared.**
Stash promotes on the first inbound frame; Home promotes on a parsed `auth_ok`. Neither
rule generalises, so:

- the app calls `markReady()` — the only place `retryCount` resets, and where keepalive starts
- fatal-vs-retryable comes from the app's `failurePolicy` closure
- even the keepalive ping frame is app-supplied (the two apps send different shapes)

It moves `String` frames and nothing else. Message framing, auth handshakes,
request/response correlation and subscriptions all live above it, in the app.

An `actor`, so it serves both concurrency conventions in the app fleet without either
converting. `RAVETransportFailure` decomposes the error into domain/code/description rather
than carrying `any Error`, because `Error` is not `Sendable` and this crosses an actor
boundary.

The **stale-completion guard** after `await task.receive()` — checking `task === webSocketTask`
on *both* the success and error paths — is load-bearing. Only one of the two source
implementations had it on both.

`probeOrReconnect()` is what a scene-phase wake should call, not `forceReconnectNow()`:
visionOS flutters `scenePhase` on gaze shifts, and unconditionally reconnecting churns the
server. `forceReconnectNow()` deliberately does *not* reset `retryCount` — resetting it
there is a reconnect-storm generator.

### RAVEUI — the bar is shared, its contents are not

The tab-bar button was byte-identical in three apps. What is *not* shared is what the bar
contains: one app puts a slideshow launcher past a divider, one puts live broadcast
indicators, one puts nothing, and two gate tab visibility on their own settings. So
`RAVETabBar` takes the tabs plus a trailing `@ViewBuilder` accessory and the app keeps
deciding both.

`onSelect:` exists because a plain selection binding cannot observe re-selection of the
already-current tab, which one app uses as a pop-to-root gesture.

`RAVECodableSize` and `RAVEWindowSessionRegistry` are present but **not yet wired into any
app** — their call sites are entangled with per-app window-restoration machinery that
genuinely differs. Extracting the types without that surrounding logic buys little.

### RAVEConsole — separate from RAVEUI on purpose

Two of the five consuming apps want a log viewer and have **no tab bar at all** to hang one
off (Spatialcraft's main window is a singleton launcher; Lambda renders through
CompositorServices). Hence a separate target rather than a corner of `RAVEUI`.

Two details are easy to lose in a rewrite and will silently break the console:

- **Polling is reference-counted.** `addViewer()`/`removeViewer()` gate the `OSLogStore`
  poll, so a console tab merely *visible* in an ornament costs nothing. The buffer is
  released when the last viewer leaves.
- **`.debug` never reaches `OSLogStore`.** The unified log keeps it in a memory ring buffer
  only. A console set to "Debug" therefore shows nothing unless call sites log via
  `RAVELogStore.effectiveDebugLevel`, which promotes to `.info` while a viewer is open.
  Apps expose this as an `AppLog.detail(_:)`-style helper.

`OSLogMessage` is a compiler-special type that **cannot** pass through a wrapper function,
which is why app-side logging facades take an already-interpolated `String` and mark it
`.public` — without the privacy annotation os_log redacts interpolated values and every
line reads `<private>`.

## How consumers use this

Five visionOS apps under `~/Projects/`. During development each references this package as
a **local** Swift package (`XCLocalSwiftPackageReference`), so edits are immediate and need
no tag-and-push cycle. Once a target stabilises, tag it and switch that app to
`.package(url:)`.

| App | Links |
|---|---|
| `VisionProHomeAssistant` (SpatialHome) | `RAVENet`, `RAVEUI`, `RAVEConsole` |
| `spatialstash` | `RAVENet`, `RAVEUI`, `RAVEConsole`, + Engine's `RAVEDiagnostics` |
| `Longwave` | `RAVEUI`, `RAVEConsole`, + Engine's `RAVEInput`, `RAVEDiagnostics` |
| `Spatialcraft` | `RAVEConsole`, + Engine's `RAVEInput`, `RAVEDiagnostics` |
| `Lambda_VisionPro` | `RAVEConsole`, + Engine's `RAVEInput`, `RAVEDiagnostics` |

**A green `swift test` here proves very little.** Local package references mean the
consuming app builds are the real integration test — a signature change compiles fine here
and breaks four apps. After changing a public API, build the affected apps:

```bash
cd ~/Projects/spatialstash && xcodebuild -project SpatialStash/SpatialStash.xcodeproj \
  -scheme SpatialStash -sdk xros -destination 'generic/platform=visionOS' build CODE_SIGNING_ALLOWED=NO
```

Longwave additionally compiles the shared `Longwave/` sources into its **Mac** target, so
anything it links must be added to `LongwaveMac` too, and must build for macOS.

## Working on this codebase

Every target here is a **convergence of two or more existing implementations**, not a
greenfield design. The tuning constants, the ordering of operations and the guard clauses
were paid for on device, and the comments explaining *why* each is what it is are the most
valuable thing in the file. Preserve them when moving code; a constant with no explanation
is one someone will "simplify" back into the bug it fixed.

Corollary: when a behaviour differs between two source implementations, check whether the
difference is drift or a deliberate product decision before picking a winner. Sometimes the
right answer is to ship both and let the app choose.

**Wire-format compatibility.** Anything persisted by a consuming app —
`RAVEFingerBindingTable`'s JSON, `UserDefaults` keys — must keep decoding what is already
on users' devices. Existing blobs' field names and optionality are a constraint, not a
style choice.

**Commits are unsigned.** This is a personal (Ixion) repo, so its pre-push hook requires
signed commits and signing needs a physical key touch. Commit unsigned and leave signing
and pushing to the user.
