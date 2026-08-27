# RAVE SDK

**R**obot-**A**ssisted **V**ision **E**nhancements — the app-shaped half of the
RAVE packages. General UI, camera, 2D/3D photo & video viewing and conversion,
and app networking, shared across the visionOS apps.

Its sibling, **RAVE Engine**, covers the XR/game-shaped half — input, frame
diagnostics, RealityKit and CompositorServices scaffolding, PCVR. The two are
siblings with **no dependency between them**, so Engine can add macOS support
on its own schedule. An app that is both simply links both.

## Platforms

visionOS 26 is the product focus. macOS 14 is also declared because nothing in
`RAVENet` is visionOS-specific and `swift test` needs a host platform to build
for; visionOS-only targets added later guard with `#if os(visionOS)` rather
than forcing the whole package to one platform.

## Targets

| Target | Status | Purpose |
|---|---|---|
| `RAVENet` | shipping | WebSocket transport with reconnect, keepalive, path gating, wake probing |
| `RAVEUI` | shipping | Tab-ornament shell, hover effects, shared window manager, small shared types |
| `RAVEConsole` | shipping | On-device log viewer, GPU/system monitor, depth-model setup UI |
| `RAVEMedia` | shipping | Core ML depth, windowed-stereo warp, shared graphic EQ |
| `RAVECamera` | planned | Persona camera |

`RAVEConsole` is separate from `RAVEUI` on purpose: two of the consuming apps
want the log viewer and have no tab bar at all to hang it off.

## RAVENet

Extracted from two independently-hardened clients — Spatial Stash's
`RemoteWebSocketClient` and Spatial Home's `HAConnection` — which had converged
on the same ~20 concerns (several byte-identical) while drifting apart on the
details. The merge takes each side's stronger half:

- **from Spatial Stash** — stale-completion guards on *both* the success and
  error paths after `await receive()`, deliberate socket suspend/revive, deep
  `URLError`/peer-trust/close-reason diagnostics
- **from Spatial Home** — an explicit state enum with a distinct handshake step

### The seam

**The transport never decides it is ready.** Stash promotes on the first
inbound frame; Home promotes on an `auth_ok` frame it has to parse. Neither
rule generalises, so:

- readiness is declared by the app via `markReady()`
- fatal-vs-retryable is decided by the app's `failurePolicy`
- even the keepalive ping is app-supplied, because Stash pings with
  `{"action":"ping"}` and Home with `{"id":N,"type":"ping"}`

Protocol framing — message shapes, auth handshakes, request/response
correlation, subscriptions — lives entirely above this type. It moves `String`
frames and nothing else.

### Usage

```swift
let transport = RAVEWebSocketTransport(
    configuration: .init(url: endpoint),
    logger: MyAppLogAdapter(),
    pingFrameProvider: { #"{"action":"ping"}"# },
    failurePolicy: { failure in
        // The broker closes unauthenticated upgrades with 1008; retrying
        // cannot fix a bad token.
        failure.closeCode == .policyViolation
            ? .halt("Server rejected WebSocket: \(failure.closeReason ?? "invalid token")")
            : .reconnect
    }
)

Task {
    for await event in transport.events {
        switch event {
        case .frame(let text):     handle(text)          // call markReady() when appropriate
        case .stateChanged(let s): publish(s)
        case .failure(let f):      log(f.diagnostic)
        }
    }
}

await transport.start()
```

Call `probeOrReconnect()` — not `forceReconnectNow()` — on a scene-phase wake.
visionOS flutters `scenePhase` on gaze shifts, and unconditionally reconnecting
there churns the server; a healthy socket answers the ping and is left alone.

## Consuming this package

The visionOS apps link this package as a **local** Swift package — an Xcode
`XCLocalSwiftPackageReference` with a relative path, not a versioned remote
dependency. There are no tags and no `Package.resolved` entry; a build always
compiles the working copy you have checked out.

That is deliberate. The packages and the apps co-evolve continuously — a target
usually arrives here by being lifted out of an app that already shipped it — and
a path reference makes "move this code into the package and update its callers"
one atomic edit instead of a commit, a tag, and a pin bump in every app.

The cost is a layout convention. Clone this package as a **sibling** of any app
that uses it:

```
some-parent/
├── RAVESDK/          <- this package
├── RAVEEngine/       <- its sibling package
├── Spatialcraft/
└── Longwave/
```

Each app's project points at `../RAVESDK` or `../../RAVESDK` depending on how
deeply its `.xcodeproj` is nested; both resolve to the same parent directory, so
the only requirement is that the app repo's parent also contains `RAVESDK` (and
`RAVEEngine`, for an app that links it) under exactly those directory names. The
app repo's own directory name does not matter. Get it wrong and Xcode fails at
package resolution rather than at compile time.

## Testing

```bash
swift test                                                              # pure-logic targets, on the host
xcodebuild -scheme RAVESDK -sdk xros -destination 'generic/platform=visionOS' build
```

The UI here is not tested from this package, and cannot be: SwiftPM has no UI-testing
product type and XCUITest attaches to a host app. `Tests/RAVEUITests` covers RAVEUI's
arithmetic and bookkeeping; the views themselves are driven by a host app's UI test
target matching on `RAVEA11y` identifiers (Spatial Stash's `SpatialStashUITests`).
`RAVEA11y`'s exact strings are therefore API — another repository's tests compute them
without linking anything here.
