# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**RAVE SDK** — *Robot-Assisted Vision Enhancements*, the **app-shaped** half of the RAVE
packages: general UI, app networking, on-device diagnostics viewing, the Persona camera,
and 2D/3D media conversion.

Its sibling is **RAVE Engine** (`../RAVEEngine`), the XR/game-shaped half — input, frame
diagnostics, RealityKit/CompositorServices scaffolding, PCVR.

**The two are siblings with no dependency between them, in either direction.** That is a
hard rule, not an accident: Engine's stated future is a Mac port, and it must be able to
get there on its own schedule without dragging visionOS-only SDK targets along. An app
that needs both simply links both. If you find yourself wanting to `import RAVEEngine`
here (or the reverse), the thing you want belongs in the app, or needs duplicating.

**The RAVE family is fixed at exactly these two packages.** Code shared across apps
becomes a **target inside SDK or Engine**, never a new third sibling package alongside
them — see `~/Projects/RAVEEngine/CLAUDE.md` → "About the planned `RAVEPCVR` target" for
the reasoning and the mistake it's guarding against.

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

### There is no XCUITest in this package, and there cannot be

SwiftPM has no UI-testing product type, and XCUITest attaches to a *host app* — so the
shared views cannot be driven from here at all. The split is:

- **`Tests/RAVEUITests`** (a plain unit-test target despite the name) covers what is
  testable without a window: `RAVEGridColumnLayout` arithmetic, the `RAVECodableSize`
  archive shape, `RAVEA11y`'s identifier spelling, `RAVEWindowSessionRegistry` counting.
- **Spatial Stash's `SpatialStashUITests`** drives `RAVETabBar` and
  `RAVEWindowManagerView` for real, matching on `RAVEA11y` identifiers, because it links
  RAVEUI and has an app to attach to. A failure there is a bug report against this
  package. See `~/Projects/Hypnos/CLAUDE.md` → UI Tests.

That is why `RAVEA11y` exists and why its exact strings are treated as API: another
repository's tests compute them without linking anything of this app's. `RAVETabItem`
and both tab-bar buttons take an overridable `identifier` so an app whose display copy
is expected to change can pin something stable (Spatial Stash passes its enum case
names).

## Platform declaration

`Package.swift` declares `[.visionOS(.v26), .macOS(.v14), .iOS(.v26), .tvOS(.v26)]`. visionOS is the
product; macOS exists so `swift test` has a host to build for, and because `RAVEConsole`
genuinely runs there (Longwave's Mac app uses it); iOS is declared because an omitted
platform is not an excluded one — see the comment in `Package.swift`.

**tvOS is declared** (2026-09-24) for Hypnos on Apple TV, and every target builds there.
What tvOS lacks is fenced with `#if !os(tvOS)`: pointer-driven views (`EQEditorView`), the
pasteboard, and the open-a-window half of the window-session registry (openWindow capture) and its App Intent. Check a tvOS build
(`xcodebuild -scheme RAVESDK-Package -destination 'generic/platform=tvOS'`) after UI changes.
**watchOS is not declared**, which blocks `worldcast/Worldcast`.

**The macOS floor stays at 14** because Longwave's Mac app deploys to 14.2. Code needing a
newer macOS marks its types `@available(macOS 15.0, *)` instead of raising the floor, as
`RAVEFilm` does for `Synchronization.Atomic`.

Guard visionOS-only code with **`#if os(visionOS)`**, not `#if canImport(SwiftUI)`.
SwiftUI imports fine on macOS — it is `CustomHoverEffect`, `glassBackgroundEffect` and
ornaments that do not exist there. Getting this wrong fails only under `swift test`, which
is easy to skip.

## Targets

| Target | Purpose |
|---|---|
| `RAVENet` | WebSocket transport: reconnect, keepalive, path gating, wake probing. Also builds on Linux (see below) |
| `RAVEUI` | Ornament tab bar, the Home ornament for pop-out windows (`raveHomeOrnament`), hover effects, grid column layout, window-session registry, window manager, shared player controls, `textFieldTapTarget()` (focus a text field from its row padding), `raveScreenTitle(_:)` + `RAVEScreenHeading` (a screen title that scrolls with the content on tvOS, where the bar's large title stays put over it; use them instead of a bare `navigationTitle` on any screen tvOS shows), subtitles (`RAVESubtitleTrack` parses WebVTT/SRT; `RAVESubtitleOverlay` draws a track on a host clock, for players that own their picture) |
| `RAVEMediaCore` | Portable Foundation-only subtitle parsing, Jellyfin HTTP request construction, stream-quality/stall rules, Up Next ordering and skip-segment models/policy. RAVEUI re-exports it to preserve Apple call sites. Bitmap subtitle bindings are guarded by CoreGraphics availability. |
| `RAVEQuestCore` | Dynamic Swift library with a UTF-8 JSON C ABI for Hypnos's Android shell: Jellyfin login, paged catalog/search/home shelves, playback/watch reports, subtitles, skip discovery, download authorization, offline progress and stall decisions. Build only this product with the matching Swift Android SDK; the rest of the package retains Apple framework bindings. Build/deploy details live in `Hypnos/Quest/README.md`. |
| `RAVEConsole` | On-device log viewer over DebugTrace's log buffer, plus a GPU/process/thermal memory monitor |
| `RAVEMedia` | Core ML depth, the offline depth converter, and the windowed-stereo warp. Now a thin RealityKit/SwiftUI player over `~/Projects/vergence` (public, cross-platform), which holds the pipeline: the Apple engine in `VergenceApple`, and the Foundation-only half in `VergenceCore` (`PackedStereoLayout`, `Pseudo3DSettings`, `DepthRefinement`/anchoring/budget/shot mapping, `DepthHistogram`), which RAVEMedia re-exports (`VergenceExports.swift`) so `import RAVEMedia` still reaches them; their tests run there. Vergence is optional for the package: without a `../vergence` checkout, Package.swift leaves out RAVEMedia, RAVESlideshow, RAVEFilm and RAVEFilmLab (`needsVergence`), so apps that use none of them resolve without it; add a target that imports RAVEMedia to that set |
| `RAVECamera` | The Persona camera through `AVCaptureSession`, a realtime H.264 encoder, AVCC helpers, the loopback video framing, a virtual camera one app publishes and another subscribes to, and the camera feeds a page's camera proxy relays (`RAVECameraFeed`: the Persona, a loopback subscription, `RAVEInProcessCamera`) |
| `RAVESlideshowCore` | Source-agnostic slideshow lifecycle (`RAVESlideshowEngine`), local sync payloads, display settings. Foundation + Observation only, builds on Linux |
| `RAVESlideshow` | The SwiftUI render surfaces and RAVEMedia adapters over `RAVESlideshowCore`, which it re-exports so `import RAVESlideshow` reaches the engine |
| `RAVEFilm` | The film player: HEVC/Dolby Vision picture on a host-clock timebase plus Atmos objects as spatial sources, fed by a `FilmAudioSource`: Hypnos's Jellyfin Atmos Objects plugin (`FilmServerClient`), or any source that can describe its sound as a scene, such as Hypnos's `DiscAudioSource`, which serves a disc's 5.1 as five pinned objects plus an LFE bed. Pictures come from the plugin's segments or a `FilmPictureSource`. A `FilmServerClient` built with a `FilmOfflineStore` answers every plugin request from a copy on the device (Hypnos's Library downloads), so offline playback runs the streamed code path. `FilmServerClient.encoding` fetches either the lossless FLAC groups or the plugin's compressed per-segment bundle (`FilmAudioBundle`: a mono AAC/Opus stream per channel, decoded in memory in parallel, loudest first, quietest dropped past a deadline); with a `governor` (`FilmAudioGovernor`, "Auto") each segment's encoding follows what the link has carried (every large transfer, the picture's included, is timed from first byte to last), capped by the path (the app supplies cost and an interface generation), stepping down at once and up after a quiet spell, and sending a total `budget` when even the lowest tier won't fit; the streamer fetches compressed segments up to 8 ahead of its decoded slots (`FilmStreamingAudioSource`, 48 MB of bytes), so a link that drops for a tunnel doesn't reach the sound. `AtmosObjectAudio` sizes its slot count to a 256 MB budget so large scenes don't balloon memory. `RAVEFilmLab` is its Mac bench (`scripts/run-film-lab.sh`) |
| `RAVESpatialAudio` | A PHASE sound stage fed by pull streams: positioned sources, head-locked beds, head-tracked listener, live room reverb; `RAVEChannelFeed` (live multichannel PCM → host-aligned per-channel pull streams), `RAVEHostClockAligner`, `RAVESpeakerLayout` (2.0/5.1/7.1). RAVEFilm re-exports it (tvOS film audio); Longwave's Moonlight surround feeds it |
| `RAVEDeviceSetup` | Hand an app's configuration, secrets included, to the same app on another device: the receiver shows a QR code carrying a fresh public key, the sender seals its payload to it (HPKE) and sends it over Bonjour |
| `RAVEBrowser` | The browser tab core lifted from Raven: `RAVEBrowserTab` (owns its `WKWebView`, the WebKit quirk handling, hibernation), the `RAVEPageFeature` seam, `RAVETabHibernation`, `RAVEBrowserProfile`, `RAVEAddressInput`, and the opt-in call layer (`RAVECallFeatures`: identity, keyboard guard, WebRTC recovery, `RAVECameraProxy`). Plus a tool surface over a web view for a language model: navigate, read (bundled Readability), numbered elements, marked snapshots, click/type/keys/hover/drag/select/check/upload/scroll/find/wait, dismiss overlays, tiered JavaScript (`RAVEScriptPolicy`), real input on the Mac (`RAVENativeInput`, `RAVEBackgroundWindow`); `RAVEWebViewHost` (show and pause an app-owned web view); `RAVEPageAgent` (the model-driven loop); `RAVEBrowserLab` is its Mac bench |
| `RAVELLM` | A language model as the apps use one: `RAVEChatModel` (messages in, text out, JSON schema, streaming) and `RAVEOllama` behind it (`Host: localhost` for `tailscale serve`). Foundation only. PCC or the on-device model become further implementations; `RAVEBrowser`'s `RAVEChatPageModel` runs the page agent on any of them |

### Linux: the portable targets

`RAVENet`, `RAVEMediaCore` and `RAVESlideshowCore` build and test on Linux,
for RoboFrame's Pi kiosk (`RoboFrame/swift-kiosk`, whose protocol client is
RoboFrame's own `RoboFrameKit`, built on `RAVENet`). When the
manifest is evaluated on Linux it drops every other target and product (the
`#if os(Linux)` block at the end of `Package.swift`), so a plain `swift build` /
`swift test` there works; add a target to that list only once it builds there.

- DebugTrace is Apple-only, so `RAVENet` links it on Apple platforms only.
  `RAVENetLogMessage` is `DebugLogMessage` there; on Linux it is a stand-in
  with the same interpolation spellings that withholds every non-`.public`
  value, and `RAVENetOSLogger` writes to stderr, info and up unless
  `RAVE_LOG_DEBUG=1`.
- `ws://` on Linux goes through `RAVEPOSIXWebSocket`, RAVENet's own RFC 6455
  client on a plain TCP socket: FoundationNetworking's `URLSessionWebSocketTask`
  (libcurl) keeps most of a core busy while a socket is open, even an idle
  one. `wss://` still uses the task (no TLS in the POSIX client).
  `RAVEWebSocketConnection` picks one; the transport sees the same shape either
  way. There is no `NWPathMonitor`, so the path counts as always satisfied.
- Test with the `swift:6.2.4-noble` Docker image (arm64, matching the Pi). The
  RoboFrame worktree's packages have to be copied under `~` first: Colima
  doesn't share `/private/tmp`.

### Quest portable-core handoff (2026-10-08)

The Quest core and Hypnos shell are merged into the primary repos. Future work
starts from current `main`, not the earlier `wt/Hypnos-quest-player` branch.
Read `../Hypnos/docs/plans/quest-parity-roadmap.md` for the review and ordered
milestones, `../Hypnos/Quest/README.md` for Android builds and
`../Hypnos/.claude/rules/hypnos-quest-port.md` for the app/device constraints.

**Next shared work:** share the full chapter-to-segment derivation (Quest
currently filters away ordinary chapter boundaries), fix server stream/job
identity and cleanup during quality switches, and converge Jellyfin DTOs,
PlaybackInfo/source selection and capability-driven playback/download plans.
`RAVEQuestCore` should become a thin boundary over shared services, not a second
Jellyfin backend. Android also needs scoped offline ownership and typed state;
coordinate those fixes with Hypnos. All remain open after this merge.

Keep framework-free code in portable targets inside this package. Do not pull
SwiftUI, AVFoundation, PHASE, Metal, Core ML or platform-only logging imports
into them. Native views/decoders/audio output stay in adapters. RAVEUI's current
re-export lets Apple call sites share core models. Public API changes need
Android and Apple consumer builds, not just a host package check.

The boundary is C/UTF-8 JSON with explicit buffer release; its current response
version/error/cancellation contract needs hardening. Low-frequency commands
may use JSON; frames, PCM and realtime poses must not. Preserve pause/playhead
through switches while keeping logical session, server job and account IDs
distinct. Build `RAVEQuestCore` with the open-source Swift/Android SDK matching
Hypnos's recipe; Apple's Xcode toolchain cannot cross-compile it.

Object audio is later roadmap work, not an existing Quest feature. Preserve
the current compressed bundle/governor/fetch-ahead behavior when extracting
scene/bundle formats and scheduling policy from RAVEFilm. Today their files
still mix portable code with Apple decoding/logging imports; do not link the
whole Apple film/audio target into Android or duplicate those policies in Kotlin.

### RAVEBrowser — a model uses pages the way Chrome MCP does, with nothing per site

`RAVEPageDriver` borrows a `WKWebView` and claims nothing on it — no navigation or UI
delegate, no user scripts — so it can sit on top of any host's view (spatial-ai-character's
`ScreenPanel`, Raven's assistant over its tabs). The rules that keep it site-agnostic and safe:

- **Everything runs in its own `WKContentWorld`.** The page can't see or redefine the
  helpers, and element refs live in that world's global, so a navigation (fresh document,
  fresh global) makes an old ref throw `stale ref N` rather than hit something else.
- **Running the caller's JavaScript is tiered, and the app decides** (`RAVEScriptPolicy`,
  fixed when it makes the driver, default `never`). Page text reaches the model, and a model
  talked into running script can do anything the page can, so: `never` for
  spatial-ai-character (unattended ambient browsing), `ask` for Raven's assistant
  (`RAVEScriptSessionConsent`: asked once per chat), `always` for Raven for Mac's agent
  harness. `evaluate` runs in the page world; JavaScriptCore parses the source first to tell an
  expression from statements, so nothing runs twice. An agent is offered the action only when
  the policy allows it.
- **Refs, not coordinates.** `elements()` numbers what is visible *and not covered* (it
  hit-tests each centre, walking open shadow roots), `snapshot(marks:)` draws those numbers
  in Core Graphics — never into the page, so nothing flashes on the user's screen — and a
  vision model answers "click 12". `click(x:y:)` exists only as a fallback.
- **Input is real on the Mac, synthetic elsewhere.** A macOS web view in a window gets
  `NSEvent`s straight to its responder methods (`RAVENativeInput`): clicks, keys and
  `insertText` arrive `isTrusted`, measured in the tests, also in a background window that
  is not key. Two exceptions, both measured or forced: WebKit ignores a pointer *move* into a
  window that is not key, so hover checks the page saw it and falls back (with a `note`); and a
  right click or a press on a `<select>` is always synthetic, because AppKit answers both
  with a menu it tracks modally on the main thread. visionOS and iOS have no public way to
  inject a touch, so there typing goes through the prototype's `value` setter (React-style
  inputs notice) and events are `isTrusted == false`. Each action reports `via`.
- **Mac windows for pages never take focus** (`RAVEBackgroundWindow`): an accessory process
  (Oneiros's harness mode), the window ordered behind everything, and WebKit's occlusion check
  off for the view (SPI, guarded) so a covered page still renders. The tests and
  `RAVEBrowserLab` run this way; `--watch` puts the Lab's window in front, still never key.
- **New-window links are followed in place**, because a web view with no UI delegate
  silently drops them.
- **Iframes, cross-origin included, through `RAVEPageFrames`** (every `RAVEBrowserTab` has
  one: `tab.frames`, and `tab.driver(scripting:)` wires it in). Each frame announces its
  `WKFrameInfo` from the driver's isolated world — WebKit offers no public frame list — so
  `elements` numbers what is inside iframes after the page's own (`inFrame` names the host),
  moved into the page's viewport, and every ref action runs in its frame; a real click in an
  iframe is trusted like any other. Placement matches a frame to its parent's iframe by
  `src`; an unmatched frame is listed only for `scope: page` and pressed synthetically.
- **`RAVEPageSupport` is for agent tabs only**: console, exceptions, `fetch`/XHR/resource
  timing, dialogs answered without UI (OK for alerts, Cancel otherwise unless
  `answerNextDialog`, once), downloads to a folder, file choosers from staged files, and an
  event list an action's result can quote. It wraps `console`/`fetch` in the page world, where
  a page can see them, so "off means absent" for people's tabs. An opaque-origin document
  (`loadHTMLString` with no base URL) reports its own errors as "Script error.".
- **`RAVEBrowserTab` answers what WebKit asks**: dialogs, downloads, file choosers (Mac),
  responses and new windows go first to features conforming to `RAVEPageEventHandler`, in
  order; then the Mac shows a sheet on the tab's window, elsewhere WebKit's no-delegate
  default stands. Downloads happen only with `downloadDirectory` or a handler, so an app that
  sets neither behaves as before. The delegate methods are pinned by a `responds(to:)` test.
- **`read()` is Mozilla's Readability** (`Resources/Readability.js`, Apache 2.0, v0.6.0 —
  Safari's Reader has no API). It reads a *copy* of the DOM, so overlays don't matter to it;
  `dismissOverlays()` is the heuristic for when the page itself has to be usable.

`swift test` runs the scripts against a real `WKWebView` on macOS (local fixtures, no
network). The driver needs WebKit, so tvOS gets the model types only.

**`RAVEPageAgent` is the loop, and every consumer runs the same one.** A model reaches a
goal one action at a time (click, type, scroll, find, read, back, navigate, done) through
the driver; the instructions, the step's JSON schema and the turn format live here, and the
consumer supplies only a `RAVEPageAgentModel` (Ollama, the on-device model, anything). Turns
are **self-contained and bounded**: the current page (outline, optional marked snapshot),
one line per earlier step, and the previous result. That is the fix for the first version,
which re-sent the whole conversation each turn and grew a 12B model's step time from 6 s to
50 s within one task. Also load-bearing: `read` continues where the last read stopped
("part 2 of 9"), because re-reading from the top never reaches what is further down and a
small model will keep trying; an action that changed nothing is said so; the same step with
the same result three times ends the run; and a ref whose element a feed re-rendered is found
again by role and link (`R.meta`) instead of failing.

**`RAVEPageAgent` offers `script` only when the driver's policy allows it** (the turn's
`actions` drive both the instructions and the step schema), and stops offering it for the run
once the person declines, so a small model never loops on a tool it cannot have.

**`RAVEBrowserTools` is the catalog every host serves** (decided 2026-10-20): the page tools
as DebugTrace `DebugEndpoint`s, so validation, did-you-mean, the envelope, hints and MCP
(images as image content) come from DebugTrace's registry rather than another copy of them.
A host passes what differs: a name prefix (spatial-ai-character's `web…`; none for Raven for
Mac's harness), the context parameters every tool takes to find its page (`tab`; `page` and
`wake`), a `resolve` from arguments to `Target(driver, support)`, and whether `evaluate` and
`upload` are offered. An action's reply carries `events` (dialogs, downloads, new windows,
console errors) when the target has `RAVEPageSupport`. `tabEndpoints(host:)` adds tab tools
over a `TabHost` (`tabs`, `tabOpen` with a `throwaway` profile, `tabClose`, `tabSelect`,
`resize`).

**`RAVEBrowserLab` measures that loop on the Mac**, no headset: `swift run RAVEBrowserLab
--model gemma3:12b [--task id] [--text-only] [--watch] --verbose`. The page runs in a real
window — WebKit treats a page in no window as hidden and stops rendering it, the same fact
the pause relies on — kept behind everything unless `--watch`, and success is judged from
the URL a task ends on, not from what the model says. Fixed tasks on Wikipedia and Reddit; `--list` names them.

**The tab core and the seam** (decided 2026-09-28, built 2026-10-17 by splitting Raven's
`BrowserTab`). Three apps want a web view, and each wants a different shell around it: Raven is
the full browser, spatial-ai-character has a screen in the room and a call window, Longwave
plans web panels pinned to the hand. So this target holds the web view **with nothing
spatial**, and nothing unique to a site:

- **`RAVEBrowserTab`** owns its `WKWebView` for its whole life and handles what every
  WebKit app runs into: KVO on url/title/back/forward/progress (same-document navigations
  fire no delegate callback), reload-when-visible after a content-process death (owed, not
  done, while hidden), the Safari UA tail and `.desktop` mode, hibernation and lazy restore
  (about:blank before release, never `stopLoading()` after it), capture state, media
  permission (`.prompt` unless the app answers). Its header carries Raven's measurements;
  read it before changing any of that. Shown through `RAVEWebViewHost`.
- **`RAVEPageFeature`** is the seam. A tab's features install their scripts and handlers
  once, at birth, on the tab's one `WKUserContentController`, **in the order the app lists
  them**: that order is the script order, and the scripts that wrap `getUserMedia` chain in
  it. They get `attach(to:)` per web view, `pageWillNavigate()` at navigation and
  hibernation, may block hibernation with a reason, and `close()`.
- **`RAVETabHibernation`** (opt-in per tab, `hibernation: .shared`; only for an app that
  reports `setVisible`), **`RAVEBrowserProfile`** (the data-store half of a profile; the
  default id is persisted by apps and fixed), **`RAVEAddressInput`** (the address bar's
  security boundary; the search template is the app's).
- **The call layer**, opt-in features (decided 2026-10-17, when spatial-ai-character needed a
  Meet call inside its own app, since an open immersive space hides other apps' windows):
  `RAVEPlatformIdentityScript`, `RAVEKeyboardSuppressionScript`, `RAVEWebRTCRecoveryScript`
  and `RAVECameraProxy`, in that order (`RAVECallFeatures.make`). The reporting scripts post
  to a handler the app names; `RAVEPageReports` logs them for an app with no diagnostics.
  The `__raven…` page globals and the `ravenReplay` handler keep Raven's names on purpose:
  the app's other scripts and the moved tests key on them.

**`RAVECameraProxy` paints a page's camera from a `RAVECameraFeed`.** Three modes: the
Persona (device-exclusive, retries, and every failure falls back to WebKit's camera), the
avatar (fails closed: an offline card on the same track and a resubscribe every 2 s, never
the real camera), and **`.virtualDevice`**, which never asks WebKit for a camera at all. A
combined request sends WebKit the audio half only, and the page sees a device that exists
only in the script: listed by `enumerateDevices` (stable id, before and after permission, in
place of the real camera entries), `granted` by `permissions.query`, and named the same by
`getSettings`/`getCapabilities`/`getConstraints`/`label`, whatever `deviceId` the page asks
for. Meet rejects a track whose `deviceId` matches nothing in its device list (measured on a
synthesized microphone in Raven), which is why all of it has to agree. The relay is tuned
for lip sync (3 in flight, keyframe on drop, `callAsyncJavaScript` arguments). Raven's
instant replay rides on it through the extension point: `RAVECameraProxyTap` sees every
unit, configuration and feed start/stop, and `beginSubstitution`/`sendSubstitute`/
`endSubstitution` replace what the page receives. `RAVECameraProxyFailClosedTests` drives
the real script in JavaScriptCore, all three modes.

Still planned here, not built: **transparent pages** (a non-opaque view plus a page feature
that clears the page's own background, for overlays) and the **pausing** container below.

**Not here:** Raven's ad blocker (its filter-list converter, AdGuard's SafariConverterLib, is
GPL-3.0 and would carry GPL into every app linking this target), the native player, call
audio (EQ, leveler, relocation), camera replay, screen share and the broadcast extension,
page diagnostics, or anything else written for particular websites. Those stay Raven's,
attached through the seam. The panel that shows a page in the room is **not** here either.
It is RAVEEngine's `RAVEPanel`, content-agnostic, and the app puts a browser view into it;
neither package imports the other. Raven's UI shell (tab strip, toolbar, window model) has
not moved; it is still optional.

**Pausing: WebKit will not do it for us** (measured on the AVP, 2026-09-28, a page counting
its own `requestAnimationFrame` calls and 100 ms timer ticks). A page in a RealityKit
attachment runs at the full ~120 animation frames/s and reports `visibilityState ==
"visible"` while the screen is 2 m behind the user, while its entity is `isEnabled = false`,
and even after the entity is removed from the scene. `isHidden = true` on the `WKWebView`
changes nothing either. **Taking the web view out of its superview** is what WebKit honours:
animation frames drop to 0/s, timers throttle to ~0.4/s, the page gets a real
`visibilitychange` to hidden (which video and chat sites act on), and the page's JS can still
be read. Putting it back resumes at once (~130 frames in the next half second) and it draws
normally. So the pause API will be a container view this target owns: the representable
returns the container, pausing moves the `WKWebView` out of it and back, and SwiftUI never
sees a change. It also calls `setAllMediaPlaybackSuspended`, since whether a hidden page's
media keeps playing is not measured yet. Deciding *when* nobody can see the page is the
panel's job, not this target's.

### RAVENet — the transport never decides it is ready

This merges two independently-hardened clients (Spatial Stash's `RemoteWebSocketClient`,
Spatial Home's `HAConnection`). The seam that makes it work: **readiness is app-declared.**
Stash promotes on the first inbound frame; Home promotes on a parsed `auth_ok`. Neither
rule generalises, so:

- the app calls `markReady()` — the only place `retryCount` resets, and where keepalive starts
- every app call about a socket (`send`, `markHandshaking`, `markReady`, `halt`) takes
  `seenFrames:`, the count of `.frame` events the app has handled; a call decided before the
  current socket's first frame is dropped. The app hears events late, so without it a
  decision about a replaced socket lands on its replacement (Spatial Home's overnight
  `auth_invalid` halt: a stale `markReady` promoted an unauthenticated socket, which then pinged)
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

**`raveHomeOrnament`** puts a Home button under a pop-out window, because visionOS brings back
whichever windows were last open and a pop-out can return alone with no way to the main one.
The ornament is shared and the action is the app's: Longwave opens a value-keyed main window,
Spatial Home goes through its app model, spatial-ai-character dismisses and reopens a main
window that is still open (the summon rule below). Longwave's `HomeOrnament` and Spatial
Home's console/system ornaments are the copies it was lifted from and can move onto it.

**`RAVEWindowRegistry` / `RAVEWindowManagerView`** are the user-facing window inventory —
distinct from `RAVEWindowSessionRegistry`, which answers the narrow lifecycle question
("is a main window up, how do I open one?"). Longwave's Sessions tab and Spatial Stash's
Windows tab converge here.

**Summon is a recycle, not a recall, and that is the whole point.** Longwave's original
summon called `openWindow(id:)` against the live scene to drag it to the user. On
visionOS 27 that exact call can activate a parked scene *without re-attaching it to a
compositor placement*: the window is then permanently invisible and non-interactable while
the scene keeps reporting itself active, `isHidden == false`, `alpha == 1`. Nothing
app-side recovers it — geometry round-trips do nothing and views added afterwards never
get a layout pass. So `summon` dismisses and reopens instead, which serves both the
other-room case and the orphaned-scene case. Reproduces with the stock Clock app; Spatial
Stash keeps the Feedback write-up at `internal_docs/visionos27-invisible-window-feedback.md`.

Design points that will look like over-engineering until they bite:

- **`recreate:` is what makes the recycle race-free.** A fresh value carrying a new
  instance id cannot match the scene being torn down, so dismiss and open can be issued in
  the same turn. Without one, `reopenRequiresTeardown` makes the reopen *wait* for the old
  scene to unregister — otherwise the open just recalls the dying scene. Value windows with
  a UUID id want `recreate:`; `.singleton` (plain `Window`, addressed by id alone) and
  identity-is-the-content values cannot have it.
- **The factories are `@MainActor`** so they can capture non-`Sendable` app window values
  into the `@MainActor` action closures. Making them nonisolated forces every consuming
  app's window value to be `Sendable`, which they are not.
- **The registration token is not the window value's id**, because a recycled window comes
  back under a new value and must not inherit the dead scene's row.
- **`RAVEWindowScenes.destroyAll(except:)` goes underneath SwiftUI on purpose.** A scene
  that never ran `onAppear` never registered — which is exactly what the launch-time
  variant of the same bug produces — so the bulk escape hatch walks UIKit's
  `connectedScenes` rather than the registry.
- **A manager hosted inside a managed window leaves itself off the list** via
  `EnvironmentValues.raveWindowToken`, which the modifier publishes into its subtree. That
  is what lets an app register its *main* windows too, so a second main parked in another
  room is recoverable — Longwave's version had to exclude "main" wholesale.

Labels are re-pushed on change (`RAVEWindowLabel` is `Equatable`) so a row can carry a live
subtitle — Longwave's connection names, Stash's media titles. The action closures are taken
once, which is correct: a window's identity never changes after it opens.

**Longwave has not been migrated yet** — it still runs its own `WindowSessionRegistry` +
`SessionsView`. The API here was shaped against both apps, but its migration is not
mechanical: Longwave's registry does double duty, since `sessions` is also read for
*functional* decisions (the Native window hides its inline audio UI while the popped-out
audio window is alive). That consumer needs a home before the local copy can go, and the
Mac target compiles the same sources.

**Player controls are shared; playback clocks are not.** `RAVEPlayerControls`
accepts `RAVEPlayerControlState`, commands and a feature accessory row. Hypnos's
FilmPlayer, its general video transport and Raven's browser-driven stereo bar
use it. Native SwiftUI scrubbing seeks only on release. Scrub and accessory
scroll lifecycles must hold the host's auto-hide timer; labels need the explicit
`ravePlayerControlLabel()` hit area. RealityKit pictures put these controls in
an ornament, not a 2D overlay inside the picture's depth region.
The control sizes itself, so hosts need no width: an ornament proposes none and
takes the ideal, which once collapsed the bar to ~237pt (`PlayerControlsWidth`
answers natural width on visionOS, a compact one elsewhere so measure-then-fit
hosts such as Hypnos's iOS ornament shim lay it at full width).

### RAVEConsole — separate from RAVEUI on purpose

Two of the five consuming apps want a log viewer and have **no tab bar at all** to hang one
off (Spatialcraft; Lambda renders through CompositorServices). Hence a
separate target rather than a corner of `RAVEUI`.

**The console tails DebugTrace's `DebugLogBuffer`, not `OSLogStore`.** Every RAVE target
that logs, and every app, logs through `DebugLogger`, a drop-in for `os.Logger` with the same
methods and `privacy:` spelling. It keeps each line in an in-memory ring and forwards it to
the unified log. Don't go back to `OSLogStore` for the live view, for two reasons measured
on 2026-09-29:
- Every read makes `logd` scan the whole system archive (~1.9 s flat on macOS 27, charged to
  `logd`). A 1 s poll slowed visionOS apps to a crawl.
- The OS keeps no `.debug` lines and drops `.info` ones within minutes, so a console opened
  late showed almost nothing.

Lines from code still on plain `os.Logger` (Apple frameworks, anything unmigrated) don't
appear in the console. Debug traces carry them in `system-log.txt`, in development builds.

- **Polling is reference-counted.** `addViewer()`/`removeViewer()` gate the twice-a-second
  pull from the buffer. The store's copy is released when the last viewer leaves; the shared
  buffer is not, because traces read it.
- **The screen and the clipboard differ.** Rows show `message` (private values in full in
  development mode). Copy exports `exportMessage` (private values withheld, redactor
  applied), because a clipboard usually ends up in an LLM chat.

The toolbar carries DebugTrace's `DebugTraceButton`. The logging targets (`RAVENet`,
`RAVEMedia`, `RAVECamera`, `RAVESpatialAudio`, `RAVEFilm`, `RAVEDeviceSetup`, `RAVEConsole`,
`RAVEBrowser`) depend on `../DebugTrace`. DebugTrace links neither RAVE package, so this adds no cycle.

**`RAVESystemMonitor`/`RAVESystemMonitorView` are Spatial Stash's GPU memory monitor,
generalised.** That app built it to compare lossy against lossless texture storage — a
question only `MTLDevice.currentAllocatedSize` answers — and it lived there as an
app-specific window. It moved here, not into Engine's `RAVEDiagnostics` (which stays
scoped to frame timing), because "how much memory does this feature actually cost" is a
question every app with a log viewer eventually asks, and every app that wants this
already links `RAVEConsole`. `RAVESystemReading` adds two facts the original monitor did
not read: `physicalMemory` (so a gauge is sized to what is actually installed rather than
a hardcoded per-model constant) and `thermalState` (so a decode/encode-heavy feature that
looks like a memory problem is not mistaken for one when it is actually throttling). Raven
is the first consumer without its own Metal renderer to hand over — it passes a fresh
`MTLCreateSystemDefaultDevice()` rather than nil, since on a single-GPU platform that still
reads the same process-wide allocation everything else is charged against.

`RAVESystemMonitorScreen` takes `onPopOut` as well as `onClose`, in that order, so it is
called exactly like `RAVEConsoleScreen`: a tab passes `onPopOut`, the pop-out window
passes neither, a section switcher passes `onClose`. Spatial Home added it — it had bound
a pop-out action to `onClose` and got a button labelled "Close" that opened a window. A
monitor is most useful *beside* the thing it measures, so the pop-out belongs here as much
as it does on the console.

### RAVEMedia — the pump pulls frames through a seam, not from AVPlayer

**Where the code is now (2026-10-10):** the pipeline described below moved to
`~/Projects/vergence` (`VergenceApple`: depth providers, converter, cache, model
store, pump, frame sources, subtitles, Metal warp and shaders, decoder recovery;
`VergenceCore`: the portable maths). RAVEMedia keeps the RealityKit/SwiftUI player
(`Pseudo3DStereoEngine`, `RAVEExternalStereoVideoView`), the audio policy and EQ,
and re-exports Vergence, so the type names below still resolve through
`import RAVEMedia`. Vergence logs through `VergenceLog`; `RAVEMediaLog.routeVergenceLogs()`
(called by the engine's init and by Hypnos at launch) sends those lines to DebugTrace
with each value's privacy intact. The depth cache's cap is `VergencePolicy.depthCacheCap`.

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

**Packed stereo is the same pump with a crop for a warp.** A video that already holds
both eyes (side by side or over/under, each at full or half resolution) passes
`packedStereo: PackedStereoLayout` to `load(url:…)` or `attach(frameSource:…)`.
The pump then cuts each eye out of the decoded frame (`videoPackedEyeFragmentShader`,
which also stretches a half-resolution eye back out) instead of warping, needs no depth
model, and reports one eye's display size so the plane fits the picture, not the packed
frame. Everything after the eye targets (420f pool, colour tags, tagged-buffer enqueue)
is shared with fake-3D, so it streams like any video and never converts to MV-HEVC.
Mirroring a stereo pair swaps the eyes as well as flipping (`eyeRegion(_:mirrored:)`);
a flip alone inverts the depth. The layout is read at load/attach, so changing it
means loading again (for an external source, a new source; re-attaching invalidates
the old one). This is the portfolio's live 3D path, Hypnos's video window first.

**Subtitles are drawn into the eyes, not over the plane** (`StereoSubtitles.swift`).
SwiftUI over the stereo plane never shows in front of it, and a panel beside it sits at
the window's depth while the content reads nearer. The host hands the engine a
`StereoSubtitleFrame` (`setSubtitles`, or `subtitles:` on
`RAVEExternalStereoVideoView`) whose `render` closure returns images sized for the eye;
the pump draws them into both eyes with crossed disparity after the warp/crop. Depth:
fake-3D's warp bounds every pixel's shift at `(1 - convergence) × strength`, so the text
sits a margin in front of that; a packed pair is block-matched behind the text
(`stereoSubtitleMatch`, 90th-percentile nearest patch). A cue holds its depth, moving
only forward. The text's white is written in the frame's transfer function: PQ/HLG get
`hdrWhiteNits` (default 203, BT.2408), SDR plain white. Both margins are untuned on device.

**Decoding can be taken away; every renderer and decoder must recover.** While another
app has an immersive space open (and on other occasions), visionOS withdraws video
decoding: `AVSampleBufferVideoRenderer` goes `.failed` with
`requiresFlushToResumeDecoding`, and a `VTDecompressionSession` returns
`kVTInvalidSessionErr`. Neither recovers on its own; unflushed, the picture froze on its
last frame for good with audio and transport running (device, 2026-10-07).
**`DecoderRecovery`** (RAVEMedia) is the shared answer, also used by Longwave's
desktop stream. The client supplies only `recover` (flush or drop its session, then get a
key frame: re-seek, re-show, or ask the sender). The helper owns everything else:
- noticing the loss even with no frames flowing: the renderer's
  `requiresFlushToResumeDecodingDidChangeNotification`, and app/scene return;
- waiting while the app is backgrounded;
- retrying about once a second, since a flush while still locked out fails again;
- the key-frame gate (`admit`), which asks again if only delta frames arrive;
- an attempt limit that only counts unexplained failures, because withdrawn resources
  must never end playback.

`recover` always runs asynchronously on the helper's queue: the renderer posts its
notification from inside `flush`/`enqueue`, which clients run under their own locks.
Users: `StereoPump` (flush and re-show the last frame), `FilmVideoPlayer` (flush and
re-seek through `onDecodingInterrupted`, so `FilmPlayer` re-anchors the Atmos clock).
`SampleBufferFrameSource` restarts its own session at the next keyframe. Any new player
here needs the same; RAVEFilm depends on RAVEMedia for it.

**Plane fit details.** The plane is positioned in scene space (`setPosition(_,
relativeTo: nil)`), refits on any scale change above 0.001 (a 0.02 threshold left it ~4 %
oversized after a window resize), and with `setSquareCorners(true)` overscans by
`squareCornerOverscan` so the window edge squares the screen mesh's rounded corners; that
needs the window to be the picture alone. `PackedStereoLayout.correctingResolution`
overrules a wrong half/full tag from the frame's shape (Jellyfin calls a plain `.3D.SBS.`
file half side by side).

**The pump stops ticking while the app is backgrounded.** visionOS refuses GPU
submission from a background app, so every command buffer a tick builds is aborted with
`kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`. An `AVPlayer`-driven
pump never revealed this, because backgrounding pauses the player and a paused player
yields no new frames — the failure needs a source that keeps producing while the app is
away, which is exactly what a web page's `<video>` does (it keeps decoding and playing
audio). Measured on device before the guard: ~6,800 aborted command buffers in 20 seconds,
each preceded by a depth inference. `StereoPump` watches `VergenceAppLifecycle`'s two
notifications and returns early from `tick()`; the timer keeps running rather than being
cancelled, so `stop()` never has to be ordered against a notification.

**All per-frame GPU work is off-main, and that is not a style choice.** An earlier
version pumped on the main actor and blocked it with `waitUntilCompleted` ~90×/s,
which starved Core Animation commits (backboardd render-watchdog SIGKILL) and the
main-queue AVPlayer prepare callbacks. The pump owns its own `MTLCommandQueue` for
the same reason: warp work must never queue behind the host's image uploads.

**The shaders are a target source, not a declared resource.** `StereoShaders.metal`
sits under Vergence's `Sources/VergenceApple/Stereo/` so Xcode compiles it into the target's own
`default.metallib`; nothing here ever calls a bare `device.makeDefaultLibrary()`,
which would search the *app* bundle and silently find no kernels. Two consequences
worth knowing before touching it:

- The SwiftPM CLI ignores `.metal` entirely, so it synthesises no `Bundle.module`.
  `VergenceMetal` therefore locates `Vergence_VergenceApple.bundle` by hand. Under
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

**Stills: `CoreMLDepthProvider.stillDepth(for: CGImage)`** returns a CPU
`StillDepthMap` (8-bit, near = 255, p2…p98-normalized, cropped to the image's own
region of Vision's `.scaleFit` letterbox). It deliberately bypasses the video
stabilizer: its temporal EMA would blend one image's depth into the next. Same
one-caller-at-a-time rule as the video entry points, which is why apps go through
**`RAVEStillDepthEstimator.shared`** (`Stills/`) rather than a provider of their own:
one inference at a time, newest request first, cancelled requests dropped before
they reach the model, model released after 20 s idle.

**AI 3D for stills: `RAVEAIDepthPhotoView`** (visionOS, `Stills/`) shows a picture as a
mesh displaced by its `StillDepthMap` (`RAVEDepthMesh`): one inference and one
RealityKit mesh, the cheap alternative to `ImagePresentationComponent`. The host lays
it over its flat picture (same rect; the mesh floats 1 pt off the plane), puts an
input layer at `inputTargetZ` in front because the RealityView swallows taps even
with hit testing off, and lifts any overlay above that. Opacity fades are stepped
on `OpacityComponent` (SwiftUI's don't reach it); adjustments are baked into the
texture and re-baked once the sliders settle. Consumers: Hypnos (photo viewer,
slideshows, and through `RAVEDepthMesh` its 3D Depth thumbnails) and RoboFrame's
slideshows.

**Depth is anchored, not normalized per frame** (`DepthRefinement.swift` in Vergence's `VergenceCore`,
`DepthAnchorGPU.swift`). Apple's Core ML Depth Anything V2 normalizes each map to
its own min…max, so a subject walking up to the camera used to push the unchanged
room back ("depth breathing"; measured with the real model on a composited clip:
a background patch fell from 0.59 to 0.18 in 0.4 s). Studio conversion holds the
environment across a shot; the pipeline now does the same, realtime and cached:
- **Anchor fit.** Pixels whose luma didn't change since the last inference, and
  that the previous frame put farther than 0.9 in shot space in *both* frames
  (`anchorCeiling`), are the same surfaces at the same depth. A reduced-major-axis
  fit over them (`DepthAlignmentSums.fit`, not least squares: an OLS slope is
  diluted by jitter in x, and chained frame to frame that bias collapses depth)
  measures the model's renormalization. The ceiling matters: without it a near
  subject's pixels — and pixels it has just covered whose luma happened to match
  — pinned the frame's maximum and dragged the slope below 1.
- **Locked scale/shift** (`DepthScaleShiftTracker`): carried through the fits and
  relaxed toward the frame's own p2–p98 range — slowly (3 s) while the frame
  overflows the budget (subject close: hold the room), faster (0.6 s) while it
  underfills (subject gone), 0.5 s when nothing anchored. Cuts (`DepthCutDetector`,
  shared with the converter, plus a mean-luma jump) and seeks reset it.
- **Depth budget** (`DepthBudget.studio`, knees 0.08/0.7): the warp shows depth
  through a tanh toe/shoulder S-curve instead of `saturate` (`pseudo3DDepthBudget`,
  `VideoStereoUniforms.depthBudget`, carried per frame on `PumpFrameDepth.budget`).
  Content past the near end plateaus just short of the glass, so convergence 1.0
  still means nothing crosses the window. `.legacy` (0, 1) is the old clamp.
- **Static-pixel hold** (realtime `depthAnchorApply`): the global affine can't undo
  the model reshuffling the background non-affinely when a subject enters, so a
  pixel whose image didn't change blends toward the new estimate at α 0.03
  (τ ≈ 1.3 s); moving pixels keep the old motion-adaptive EMA. This is what took
  the background's largest frame-to-frame step from 0.164 to 0.009.
- **Edge refinement live.** Realtime now uses the joint bilateral (r8, σ4, luma
  σ 0.06) instead of the plain gaussian, so it takes the dense warp grid like
  cached depth (edge-snapped depth stairsteps on the moderate grid).
  The dense grid is not enough on its own: at model resolution the depth texel
  lattice (~3.7 px at 1080p) quantizes the warped silhouette just as the
  converter's v3 note describes, and near subjects stairstepped once this shipped
  (the gaussian had hidden the lattice by ramping every edge over several texels).
  So the refiner ends, as the converter does, with a guided ×2 joint-bilateral
  upsample (r6, σ3) against a 2× luma guide and hands the warp the 2× map;
  anchoring and the EMA stay at model res. `RealtimeDepthEdgeTests` measures the
  bilinear crossing against a disc's true edge: 1080p row-to-row wobble 0.43 →
  0.22 px, worst 3.23 → 1.80 px. An area-filtered guide (for 4K's 7× decimation)
  was tried and measured no better, so the single-tap guide stays.

Realtime runs two waited command buffers per inference (guide + bilateral +
anchor reduce + range fold + histogram; then apply) — on an M-series Mac the
whole call measured 34.7 ms vs 33.5 ms for the old stabilized one, i.e. ~1 ms of
added work; device cost is unmeasured. `DepthRefinement.isEnabled`
(`depthRefinementEnabled`, default on; Hypnos → Settings → Stable Depth) is read
when a `RealtimeDepthSource` is built. The converter always refines (v5): it fits
consecutive refined maps in stage B, aligns each temporal-window neighbour into the
center frame's units (`slotScale/slotBias` in `depthTemporalEncode`), and its
post-pass (`DepthShotMapping`) runs one tracker per half-rate lattice, then smooths
the shot-space range with a centered [1, 2, 1] that also ties the lattices together.
Measurement harness: `DepthRefinementHarnessTests` (needs `xcodebuild test` for the
metallib, a model and a frame directory; see its header). Untuned on device: the
knees, the hold/recover times, the static α, the anchor ceiling, and whether the
dense grid's cost fits the live tick.

**Convergence stays fixed at 1.0.** A midground (tracked-median) convergence was
considered again and left out: clamped so the nearest content never crosses the
window, it reduces to tracking the frame's nearest depth, which slides the whole
scene back whenever a subject approaches — the breathing the anchor removes,
reintroduced as a convergence pull.

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

**Clocked compressed-picture taps.** `SampleBufferFrameSource` takes samples
from RAVEFilm's `FilmVideoPlayer.onSampleBuffer` hook and its timebase. It
prefetches compressed samples, decodes in DTS order on the pump queue with
100ms lookahead for B frames, and presents the latest decoded PTS due on the
host clock. It never seeks or owns audio. `onFlush` resets its generation so
old-seek callbacks cannot paint new playback. `PumpFrameSource`'s BGRA contract
is enforced by VideoToolbox output attributes. macOS tests use a synthetic
H.264 B-frame fixture to verify timing, reset and duplicate suppression.
A sample that already holds a pixel buffer skips decoding and is converted
to BGRA with a `VTPixelTransferSession`.

**Pictures the platform can't decode.** `FilmVideoPlayer.load(_: FilmPictureSource)`
replaces the plugin's segments with frames an app decodes itself (Hypnos's
`MVCPictureSource`: Blu-ray MVC 3D via the local `vergence` package, formerly mvc3d). Frames are
uncompressed sample buffers in film time, starting exactly at the seek
target, fed to the same display layer and timebase, so `FilmPlayer`'s audio
anchoring is unchanged; only `pictureAheadSeconds` (0.75 s) is queued, as
each is megabytes. Audio tracks: `FilmServerClient.audioTracks(languages:)` (the plugin's `Tracks`,
empty from an older plugin) and `audioStream`, sent on every audio request;
`FilmPlayer.load` starts on the plugin's default for `FilmServerClient.deviceLanguages`,
and `selectAudioTrack(_:)` swaps only the audio at the playhead (the stages rebuild
because `player.audio` changes). `FilmPictureFrame.stereo` carries the frame-packed picture
for the stereo tap. `FilmVideoPlayer.isLoaded` replaces `index != nil` as the
"a picture is loaded" test.

**Picture tiers.** The plugin's index lists lower tiers by height
(`FilmVideoIndex.pictureHeights`, e.g. `[1440, 1080]`; empty from an older
plugin and always empty for a download, whose client never sends `height`).
They are HEVC transcodes cut on the same index, so `FilmVideoPlayer` can change
tier at any segment: `load(_:startAt:pictureHeight:)` opens at one, and
`setPictureHeight(_:)` fetches the new tier's segment at the playhead and its
init (segment first, so the plugin's run there writes the init) while the old
picture plays, then flushes (`onFlush` too) and feeds from the playhead's
keyframe interval with the frames before it hidden. It never parks or
re-anchors the timebase, so the audio clock is untouched; a seek still priming
is repeated in the new tier instead, so `FilmPlayer`'s wait on `isPrimed` holds.

`RAVEExternalStereoVideoView` mounts a host-owned frame source in visionOS
using the measured 90pt video recess. The host must reserve ornament space and
keep its transport attached to its own clock. A compressed tap currently adds
a second decode session while the original HDR layer remains mounted; changing
this or claiming HDR fidelity/performance requires device measurements.

### RAVESpatialAudio — PHASE, because of what the system gives it

RealityKit's spatial audio exists on tvOS 26, but the system applies AirPods
head tracking and the personalized spatial audio profile only to
AVAudioEngine, AUSpatialMixer and PHASE, each behind an entitlement
(`com.apple.developer.coremotion.head-pose`,
`com.apple.developer.spatial-audio.profile-access`). Without them the head
tracking flag is accepted and silently does nothing. PHASE won over
AVAudioEnvironmentNode for its built-in room reverb, which the send
meta-parameter changes live.

Things measured on an Apple TV (2026-09-27) that the stage's defaults
encode:

- **Output is forced binaural.** Left automatic, PHASE chose plain panning
  on an AirPlay HomePod pair.
- **Each pull stream has its own sample timeline and can stall at start.**
  Timestamps carry a valid sample and host time. A caller keeping streams
  sample-locked aligns by host time and must survive a stall:
  `RAVEHostClockAligner` does both (re-anchors past 50 ms of drift). It was
  RAVEFilm's `AtmosObjectAudio`'s own code until Longwave became the second
  consumer (2026-10-04); both use it now.
- **Calibration is `.relativeSpl` at 0 dB, distance rolloff 0.** The caller
  owns levels. LambdaVision's PHASE attempt on visionOS was deafening, but
  that was the visionOS system spatializer, which is why visionOS doesn't
  use this stage.

A game can feed it the same way: one pull-stream source per mixer channel.
**`RAVEChannelFeed` is that path for a live source** (Longwave's Moonlight
surround, decoded Opus pushed from moonlight-common-c's thread): the producer
pushes interleaved frames, each channel pulls through its own handler, and a
`RAVEStreamTimeline` primes a jitter cushion, re-primes when it runs dry and
skips forward past a ceiling. It adds the cushion and no other buffering;
the render quantum must fit inside the cushion. `addSpeakers(_:feed:)` lays
a `RAVESpeakerLayout` out as sources in WAVE channel order (fronts ±30°, 5.1
surrounds ±110°, 7.1 sides ±90° and backs ±135°, LFE as a dry bed).
LambdaVision's parked `PhaseAudioEngine` is sample-asset based and would
need its channels turned into streams first.

**visionOS** gets `systemRendering: true` (`PHASEEngine.RenderingMode.client`,
visionOS 26+: rendered in the system audio server, with its head tracking and
personalized profile). Longwave is the first visionOS consumer and uses it;
unheard on a headset as of 2026-10-04, so whatever it measures belongs here.

### RAVEDeviceSetup — the QR code is the only channel the key travels on

Written so Hypnos could provision an Apple TV (no AirDrop, no Files app, a Siri Remote
for typing API keys); the app on both ends is the same app, and the payload is any
`Codable` the app defines. The protocol is in `RAVESetupCode.swift`'s header. What
matters when touching it:

- **The receiver's public key is only ever in the QR code**, never in the Bonjour
  record. That is the whole authentication story: a sender that didn't see the screen
  can't seal a payload the receiver opens, and the receiver drops such a connection
  without replying and keeps waiting. Every `start()` makes a new key pair; `stop()`
  discards it.
- **HPKE, not TLS-PSK.** A short code as a TLS pre-shared key can be brute-forced
  offline from one recorded handshake; a QR code has room for a whole X25519 key. The
  reply is sealed under a secret both sides export from the HPKE context, so the
  sender's "sent" means the receiver really opened it.
- **No permissions on the sender.** The system Camera opens the app's own URL scheme
  (`<scheme>://setup?...`) on iPhone/iPad; everywhere else `RAVESetupScanPhotoButton`
  reads a picked photo through the out-of-process `PhotosPicker` and Vision. No camera
  or photo-library prompt either way.
- **The sender connects to the named Bonjour instance directly**, with no browse, so it
  enumerates nothing else on the network.
- **Each consumer declares its `bonjourType` under `NSBonjourServices`** and has an
  `NSLocalNetworkUsageDescription`. Without the first, the receiver can't advertise and
  the sender can't resolve.
- `swift test` runs real transfers over Bonjour on the host, including a forged key
  being dropped while the receiver keeps waiting.

### RAVECamera — the frame WebKit never gives you

A convergence of Longwave's Broadcast tab (`BroadcastCaptureSession` +
`BroadcastVideoEncoder`) and Raven's screen-share extension (`ScreenBroadcastEncoder` +
`AVCCBuilder`). The trigger was a measurement, and it is the reason to keep the capture
half here rather than treating it as Longwave's: **on visionOS, `AVCaptureSession`
delivers the Persona as a landscape 1920×1080 frame, and WebKit's `getUserMedia` delivers
the same sensor reframed** — 720×1280 portrait for a 16:9 ask, 1080×1080 for an
unconstrained one, never the native frame. Raven's camera proxy therefore captures with
`RAVEPersonaCamera` itself and feeds the page H.264, which made the capture session and
the encoder shared code by definition.

Design points worth keeping:

- **Its own product, not a corner of RAVEMedia.** Two consumers are ReplayKit broadcast
  extensions (Longwave's `LongwaveBroadcast`, Raven's `RavenBroadcast`) that want the
  encoder and nothing else; linking Core ML and Metal shaders into an extension to encode
  a screen would be the wrong shape.
- **`RAVEH264Encoder` emits AVCC access units verbatim and leaves the RTP shaping to the
  caller.** That is the one thing the two original encoders genuinely disagreed on: a
  WebCodecs decoder wants the buffer exactly as VideoToolbox produced it, RTP wants it
  split into NAL units with SPS/PPS prepended to each IDR. Longwave's
  `BroadcastVideoEncoder` is now a thin wrapper doing the latter with `RAVEAVCC.nalUnits`.
  The tuning — realtime, no B-frames, 1 s GOP, lazy session from the first frame — was
  identical in both and paid for on device.
- **`RAVEAVCC` is `AVCCConfig`'s inverse**, and Raven's `AVCCRoundTripTests` pins them
  together because the parser stayed in Raven (it belongs to the page→app decode side).
  The builder's own layout tests are here in `RAVECameraTests`.
- **Builds on macOS so `swift test` reaches the container arithmetic.** AVFoundation and
  VideoToolbox exist there; only `AVCaptureSession`'s interruption notifications are
  iOS-family and are guarded `#if os(iOS) || os(visionOS)`.
- **The camera is device-exclusive across processes.** WebKit's capture runs in another
  process, so a page holding the camera and this session cannot both have it — whichever
  starts second is interrupted with `videoDeviceInUseByAnotherClient`. Raven's page script
  stops the WebKit track *before* asking for this session; the type documents the rule,
  the caller has to honour it.

- **`RAVEVideoFraming` is the one wire format for encoded video between two processes on a
  device**, lifted from Raven's `BroadcastFraming` (2026-10-17) when the virtual camera needed
  the same thing. Each stream opens with its own magic (`RVN1` screen share, `RVC1` camera), so
  a client on the wrong port fails on the first bytes. The config carries the frame size
  (trailing, read as 0×0 when absent) and there is a `keyframeRequest` for the control
  direction.
- **`RAVEVirtualCamera` exists because visionOS has no virtual capture device.**
  spatial-ai-character publishes its performed avatar (`RAVEVirtualCameraPublisher`, loopback
  port 46415) and Raven's camera proxy subscribes (`RAVEVirtualCameraSubscriber`) instead of
  starting the Persona. The publisher listens and the subscriber dials, because a camera exists
  before anyone opens it; `onSubscribersChanged` is the owner's cue to render only while
  someone watches. Anything local can dial loopback, so the owner must show when it is being
  watched. Flow control is Raven's relay rule: never drop a lone delta, drop to the next
  keyframe and ask for it at once. `swift test` runs it over real sockets.
- **`RAVEInProcessCamera` is the same camera without the socket**, for a proxy in the
  publishing app itself (spatial-ai-character's call window). Same API as the publisher, and
  `makeFeed()` hands out `RAVECameraFeed`s, so the proxy cannot tell it from loopback. A late
  joiner gets the config and waits for the keyframe the owner is asked for. `publish` comes
  from the encoder's thread: all state is behind one lock, and deliveries are enqueued on each
  feed's serial queue while holding it, which is what keeps each stream in publish order. Its
  tests also pass under `--sanitize=thread`.
- **The feeds** (`RAVECameraFeed`, lifted from Raven 2026-10-17): `RAVEPersonaCameraFeed`
  (capture → HEVC, chosen for decode latency in WebKit's `VideoDecoder`, not bitrate; 2 s
  GOP), `RAVEVirtualCameraFeed` (a loopback subscription). Buffer-owning classes count
  themselves in `RAVELiveObjects`, which an app's memory heartbeat prints: a count that only
  goes up is a leak named outright.

## How consumers use this

Nine apps under `~/Projects/`. During development each references this package as a
**local** Swift package (`XCLocalSwiftPackageReference`), so edits are immediate and need no
tag-and-push cycle. Once a target stabilises, tag it and switch that app to `.package(url:)`.

What each app is and where new code goes lives in `~/Projects/CLAUDE.md`; this table is only
the link list.

| App (directory) | Links |
|---|---|
| `Hypnos` (visionOS + iOS + tvOS + macOS; tvOS bench `Hypnos/TVLab`) | `RAVEUI`, `RAVEConsole`, `RAVEMedia`, `RAVESlideshow`, `RAVEFilm` (and through it `RAVESpatialAudio`), `RAVEDeviceSetup`, + Engine's `RAVEDiagnostics` |
| `Longwave` (visionOS + iOS + macOS) | `RAVEUI`, `RAVEConsole`, `RAVEMedia`, `RAVESpatialAudio`, `RAVECamera` (app + broadcast extension), + Engine's `RAVEInput`, `RAVEDiagnostics` |
| `Raven` | `RAVENet`, `RAVEUI`, `RAVEConsole`, `RAVEMedia`, `RAVECamera` (app + broadcast extension), `RAVEBrowser`, `RAVELLM` |
| `RoboFrame/NativeClient` (visionOS + iOS) | `RAVENet`, `RAVEUI`, `RAVEConsole`, `RAVEMedia` (incl. AI 3D stills), `RAVESlideshow` |
| `VisionProHomeAssistant` (SpatialHome) | `RAVENet`, `RAVEUI`, `RAVEConsole` |
| `xrTimer` | `RAVEUI`, `RAVEConsole` |
| `Oneiros` (visionOS + macOS) | `RAVEConsole`, + Engine's `RAVEInput`, `RAVEDiagnostics` |
| `halflife-visionos/LambdaVision` | `RAVEConsole`, + Engine's `RAVEInput`, `RAVEDiagnostics`, `RAVERig` |
| `spatial-ai-character` | `RAVEUI`, `RAVEConsole`, `RAVEBrowser`, `RAVECamera`, + Engine's `RAVEDiagnostics`, `RAVEPanel`, and `RAVERig` transitively through its own `CharacterKit` |

Read this from `productName = RAVE…` in each `project.pbxproj`, not from `import RAVE…` —
re-exports and typealiases hide a dependency from the import list.

**A green `swift test` here proves very little.** Local package references mean the
consuming app builds are the real integration test — a signature change compiles fine here
and breaks four apps. After changing a public API, build the affected apps:

```bash
cd ~/Projects/spatialstash && xcodebuild -project SpatialStash/SpatialStash.xcodeproj \
  -scheme SpatialStash -sdk xros -destination 'generic/platform=visionOS' build CODE_SIGNING_ALLOWED=NO
```

Three consumers are not visionOS-only, and they are the ones a new API breaks: Hypnos builds
for **iOS**, Longwave for **iOS and macOS** (it compiles the shared `Longwave/` sources into
`LongwaveMac`, so anything it links must be added there too), and Oneiros has a macOS target.
Anything they link must build for those platforms.

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
