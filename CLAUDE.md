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
| `RAVEMedia` | Core ML depth, the offline depth converter, and the windowed-stereo warp |

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

`RAVEWindowSessionRegistry` and `RAVECodableSize` are both wired into Spatial Stash and
Spatial Home; both apps deleted their local twins. The size type was the one that needed
thinking about, because window *values* persist through scene restoration — swapping it is
a compatibility decision, not a rename. It was safe here only because both twins were
byte-identical to this one: same `width`/`height` property names, so the archived
`{"width", "height"}` payload is unchanged and `Codable` never records the type's name.
Anything with different property names would need a migrating `init(from:)`, not a swap.

**`RAVEOpenMainWindowIntent`** is the workaround for a visionOS gap: an icon tap with any
window alive anywhere skips the launch-scene machinery and *summons the nearest window to
the user* (dragging pinned windows out of their rooms) — no public API redirects that
(forums 748187/789355). The intent lets Siri/Shortcuts open a fresh main window instead.
Design points that will look like bugs if lost:

- It **always opens a new main window** — a registered main may be parked in another room
  (registration tracks scene existence, not visibility), so no-op-when-one-exists would
  fail exactly the case the intent exists for. The single exception: a main window that
  registered within the last few seconds means *this activation* already presented one
  (restoration / `defaultLaunchBehavior(.presented)` / an app-delegate fallback), so it
  skips. Its settle delay is deliberately longer than typical app-side "ensure main
  window" delays so it observes their result instead of racing them.
- Hosts must capture actions with `captureOpenWindowAction()` on every scene root, count
  mains with `registerAsMainWindow()`, and add two app-target pieces a package cannot
  provide: an `AppIntentsPackage` conformer listing `RAVEUIAppIntentsPackage` (a
  **standalone struct** — the `App` struct is MainActor-isolated and can't satisfy the
  nonisolated protocol under Swift 6) and an `AppShortcutsProvider` with Siri phrases.

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

### RAVEMedia — the pump pulls frames through a seam, not from AVPlayer

This is Spatial Stash's fake-3D pipeline, moved wholesale: monocular depth (Depth
Anything V2) drives a per-eye warp that turns mono video into windowed stereo in an
ordinary Shared-Space window. Unlike the other targets it is **not** a convergence of
two implementations — it has one consumer today and a second (Raven, the browser)
being built against it, which is why the seams below exist before their second caller
does.

**`PumpFrameSource` is the reason this is a package.** `StereoPump` used to hold an
`AVPlayerItemVideoOutput` and pull `copyPixelBuffer(forItemTime:)` directly. It now
asks a `PumpFrameSource` for "the newest frame you have not given me yet".
`AVPlayerFrameSource` is that pull, unchanged; a browser pushes decoded WebCodecs
frames into a single-slot buffer instead, with no AVPlayer anywhere. Sources must
return nil rather than repeat a frame — a tick that re-warps the same frame costs a
full GPU pass and enqueues a duplicate.

`attach(frameSource:)` is the entry point for that second case, and it is not a
variant of `load(url:…)` — it opens no player at all. The consequence is worth
stating because it looks like a bug from the outside: an engine driven this way
publishes **no** transport. `play()`/`pause()`/`seek(to:)` act on a nil player and do
nothing, `currentTime` reads 0, and `onPlaybackUpdate` never fires. That is correct —
whatever produced the frames owns the clock, and in Raven's case it is a `<video>`
inside a web page that also owns the audio. It is realtime-depth only for the same
reason: cached depth needs a stable per-video identity and a conversion pass up
front, and arbitrary browsing has neither.

**All per-frame GPU work is off-main, and that is not a style choice.** An earlier
version pumped on the main actor and blocked it with `waitUntilCompleted` ~90×/s,
which starved Core Animation commits (backboardd render-watchdog SIGKILL) and the
main-queue AVPlayer prepare callbacks. The pump owns its own `MTLCommandQueue` for
the same reason: warp work must never queue behind the host's image uploads.

**The shaders are a target source, not a declared resource.** `RAVEStereoShaders.metal`
sits under `Sources/RAVEMedia/Stereo/` so Xcode compiles it into the target's own
`default.metallib`; nothing here ever calls a bare `device.makeDefaultLibrary()`,
which would search the *app* bundle and silently find no kernels. Two consequences
worth knowing before touching it:

- The SwiftPM CLI ignores `.metal` entirely, so it synthesises no `Bundle.module`.
  `RAVEMediaMetal` therefore locates `RAVESDK_RAVEMedia.bundle` by hand. Under
  `swift build` it finds nothing and every caller degrades to "fake-3D unavailable",
  which on a Mac test host is the truth. Do not "fix" this by declaring the metal
  file as a resource — that copies it instead of compiling it.
- `stereoQuadVertex` is a verbatim copy of the app's `imageVertexShader`. A Metal
  library cannot span module boundaries, so the duplication is structural; both must
  keep producing a top-left-origin fullscreen quad.

**`RAVEDepthModelSetupView` is shared; the preference it writes is not.** The variant
catalogue, the Hugging Face download and the progress UI are one view now, because two
apps had written the same twenty lines of SwiftUI in front of the same
`DepthModelManager`. What stayed app-side is what a choice *means*: Spatial Stash sets
both roles and adds a note about its own push script, Raven sets the realtime role only
and has no settings screen at all. `onSelect` fires only once the model is genuinely
installed — a failed download leaves the sheet up with its error rather than dismissing
into a conversion that cannot run.

**Two things the host must supply.** `RAVEMediaPolicy.depthCacheCap` gives the depth
cache its byte budget — unset means *never evict*, so a host that forgets it grows the
cache without bound. Spatial Stash wires it to `CacheBudget.cap(for: .depth,)` in
`AppModel.init`. `RAVEMediaLog` keeps `Bundle.main.bundleIdentifier` as its subsystem
so `RAVEConsole` still sees these lines; only the categories are the package's own.

**What deliberately stayed in the app:** the SwiftUI view (window-chrome constants,
gestures), the binding of transport to a per-app playback model (the engine publishes
`RAVEPlaybackState` and knows nothing about what consumes it), and the audio *session*
category — `AudioSessionConfig.configureMixedPlayback` is a whole-app decision about
stealing audio focus, while the per-player spatial-audio policy moved here with the
engine that applies it.

**Wire-format constraint:** `DepthCacheStore.pipelineVersion` keys every cache entry.
Changing the converter's output — including the histogram percentile, which is
interpolating rather than the nearest-rank one `RAVEDiagnostics` uses — invalidates
every conversion on every device. `Pseudo3DSettings.init(from:)` has the same
constraint for persisted JSON, including its normalisation of the retired `0.45`
convergence default.

## How consumers use this

Five visionOS apps under `~/Projects/`. During development each references this package as
a **local** Swift package (`XCLocalSwiftPackageReference`), so edits are immediate and need
no tag-and-push cycle. Once a target stabilises, tag it and switch that app to
`.package(url:)`.

| App | Links |
|---|---|
| `VisionProHomeAssistant` (SpatialHome) | `RAVENet`, `RAVEUI`, `RAVEConsole` |
| `spatialstash` | `RAVENet`, `RAVEUI`, `RAVEConsole`, `RAVEMedia`, + Engine's `RAVEDiagnostics` |
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
