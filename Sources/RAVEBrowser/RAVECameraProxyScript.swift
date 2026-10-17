/*
 RAVEBrowser — the page half of the camera proxy.

 Raven's `CameraReplayScript`, lifted 2026-10-17 with `RAVECameraProxy` so a
 second app can put its own camera into a page's call (spatial-ai-character's
 avatar in a Meet window). "Raven" below is where each finding was measured;
 the code is the app's, whichever app links it. The page-side names
 (`__ravenReplay`, the `ravenReplay` handler) are kept: tests and the app's
 other scripts key on them, and renaming a global is a silent break.

 The page's job here is deliberately small: put the app in the camera path,
 crop what arrives to the configured framing, and publish it. Everything that used
 to make this file large — the encoded ring, bounce playback, the alignment
 ghost hunting for the page's self-view tile — has moved to Swift, and for one
 reason: **the app already holds every encoded frame the page ever paints.** With
 the native source (`nativeCapture`, on by default) the sensor's frames reach
 this script as HEVC access units from `RAVEPersonaCameraFeed`, so Raven's ring
 is those units kept in Swift (on the proxy's tap), a replay is Swift re-sending
 them, and the page cannot tell live from loop. That removed a second full encode of every published
 frame (the page used to re-encode its own canvas into H.264 forever), a
 decode-and-cache bounce player, and a heuristic that guessed which `<video>`
 on Meet was the wearer's own — replaced by a native preview window that shows
 the live picture with the loop over it at half opacity.

 What stays is the framing, and the reason it exists:

 1. **Framing.** A call's send tier is a *pixel budget*. Meet's own ask
    (`1280×720`, `aspectRatio 1.778`) gets it a **720×1280 portrait** feed whose
    top and bottom Center Stage leaves empty by design, so a third of that budget
    goes on the ceiling.

    **What reclaims it is dropping `aspectRatio`, not the crop.** Asking for 1080
    on the short edge with no ratio constraint returns a **true 1080×1080** — the
    camera composes a square itself (measured; the same request *with* a ratio is
    what got Meet 720×1280). So the request never changes with the target shape,
    and the aspect is taken in the canvas afterwards, which keeps the pixels and
    makes the choice free.

    The published shape is then whatever aspect the app passes (Raven:
    `RavenSettings.cameraFraming(for:)`) — 3:4, square or 16:9, each a centred
    crop of whatever the source gave.

 **What the crop does not do is lift the 720p send tier.** That tier is
 Chromium-only and was measured twice (see "Raven identifies as Safari" in
 Raven's CLAUDE.md). What it changes is how much of the tier's budget lands on the
 subject.

 **The camera is proxied from the moment it is granted, and the object the page
 holds never changes.** Swapping a track mid-call is the documented Meet-killer —
 forcing tracks under Meet produced "there was a problem with an effect, so video
 is off" and it stopped publishing camera altogether. Replay changes only what is
 painted, and it does so upstream of this script.

 ### Where the pixels come from: the app's own capture session, WebKit's as the fallback

 **WebKit never offers a page the frame the sensor produces.** Its capture layer
 reframes the Persona around the wearer before the page sees a pixel — measured:
 a 16:9 ask returns 720×1280 portrait, an unconstrained ask returns 1080×1080 —
 and the camera's native **1920×1080 landscape** frame, the one an
 `AVCaptureSession` returns and Longwave's Broadcast tab streams, is not on the
 menu at all. So with `nativeCapture` on the proxy is painted from the app's
 *own* session: `RAVEPersonaCameraFeed` (AVCapture → HEVC) → `nativeChunk` → a
 WebCodecs `VideoDecoder` → the canvas.

 The real `getUserMedia` is still called first, and deliberately: it is where
 WebKit's per-site permission prompt lives, and its track is the identity the
 proxy mirrors (`deviceId` above all — the WebRTC watchdog classifies the
 self-view by it). Its video track is then stopped *before* Swift is asked to
 capture, because the camera is device-exclusive and WebKit captures from
 another process; and its settings are snapshotted at grant, since a stopped
 track cannot be trusted to keep answering.

 **Every native failure degrades to the WebKit source, never to a black tile,
 and the track the page holds is untouched throughout.** No frame within
 `FIRST_PAINT_MS`, a `nativeEnd` from Swift (access denied, another tab holds
 the camera, the session died), a decoder fault — each runs `fallBackToElement`,
 which re-requests the real camera with the same upgraded constraints the
 pure-WebKit path asks for and paints from the element instead. Only if *that*
 never paints does the page get the real stream, exactly as before. On the
 WebKit path there is no replay and no preview — Swift never sees those frames —
 and the framing still applies.

 ### The avatar source fails closed

 With `.avatar` (and `.virtualDevice`, below) the canvas is painted from a feed
 that is not the wearer's camera — the avatar spatial-ai-character publishes —
 relayed by Swift exactly like the app's own (`nativeConfig`/`nativeChunk`). Choosing it means the site must not see
 the wearer's face, so **every path above that degrades to WebKit's camera is
 closed**, and the one function they all go through, `fallBackToElement`,
 refuses first thing: no frame within `FIRST_PAINT_MS`, a `nativeEnd`, a
 decoder fault, a `captureStream` with no track — each paints the offline card
 (`goOffline`) on the same proxy track instead, and asks Swift to reconnect
 (`avatarFault`). Swift's own outages arrive as `nativeOffline` and do the
 same. The track stays live, the card is repainted every second so a far end
 that joins late still gets a frame, and painting resumes on the next decoded
 frame, which is always a keyframe after a reconnect. `degradeToRealStream`
 and the element loop refuse too, as a second line.

 The real `getUserMedia` still runs first, for WebKit's per-site prompt and the
 track's identity, and its video track is stopped before Swift is asked for
 anything; in this mode the element is never bound to it, and the WebRTC
 watchdog does not probe it (`WebRTCRecoveryScript(probeCamera:)`). A combined
 audio+video request is proxied too — the microphone tracks are handed through
 untouched on the proxy stream — because returning it whole would hand over the
 real camera with it. The legacy `navigator.getUserMedia` and
 `MediaDevices.prototype.getUserMedia` are routed through the proxy for the same
 reason: WebKit's legacy call reaches the internal method directly.

 What this cannot promise is a page *working against it*: the proxy lives in
 the page's own world, so a site that hooks prototypes before the grant or
 calls `getUserMedia` from a fresh frame this script has not reached can still
 get WebKit's camera, which the site's own permission covers. The rule is that
 nothing this script does falls back to the real camera.

 ### The virtual device never opens the real camera at all

 `.virtualDevice` is the avatar's fail-closed proxy with one more thing taken
 away: the real `getUserMedia` for video is never called, so there is no
 WebKit camera prompt, no grant-time identity and no track to stop. The page
 sees a camera that exists only here — listed by `enumerateDevices`, granted
 by `permissions.query`, named consistently by every getter on its track (see
 "the virtual device" below). A request with audio sends WebKit the audio
 half alone and hands both back as one stream; an audio-only request passes
 through untouched.

 `enabled = false` on the proxy track paints black rather than relying on a
 disabled real track to go black underneath, because in native mode there is
 no real track underneath. The same switch is reported to Swift (`enabled`), so
 frames from a deliberately-off camera never enter the ring — a privacy
 property, not an optimisation.

 Must be in `pageWorld` at document start, and it is injected **only when the
 app wants a proxy** — off means absent, not passive: a wrapper that merely
 forwards still perturbs `getUserMedia.toString()`, function identity and
 timing on every site that has nothing to do with this.
 */

#if canImport(WebKit)
import Foundation
import WebKit

public enum RAVECameraProxyScript {
    /// The handler name this script and `RAVECameraProxy` agree on.
    public static let messageHandler = "ravenReplay"

    /// - Parameters:
    ///   - aspect: width ÷ height to crop the published frame to. A setting in
    ///     Raven rather than a constant because the framing is visible to
    ///     everyone else on the call, so being able to compare ratios without
    ///     a rebuild is what makes the choice judgeable.
    ///   - mode: whose picture it is, and how it fails — see
    ///     `RAVECameraProxy.Mode`. `.persona(nativeCapture:)` says whether the
    ///     proxy is painted from the app's own `AVCaptureSession` (the sensor's
    ///     native 1920×1080) or from the track WebKit grants (reframed to
    ///     portrait or square). `.avatar` and `.virtualDevice` take the native
    ///     path whatever, and fail closed (see the header).
    ///   - offlineCard: what the fail-closed modes paint while their feed is
    ///     away.
    @MainActor
    public static func userScript(
        aspect: Double, mode: RAVECameraProxy.Mode, offlineCard: RAVECameraProxy.OfflineCard
    ) -> WKUserScript {
        // Prepended rather than interpolated into the body, so the script
        // itself stays a raw string with no escaping to get wrong. Numbers and
        // Bools interpolate directly; every string goes through the escaper.
        var nativeCapture = true
        var avatar = false
        var virtual = "null"
        switch mode {
        case .persona(let native):
            nativeCapture = native
        case .avatar:
            avatar = true
        case .virtualDevice(let device):
            virtual = "{kind:\(RAVEJavaScript.string(device.kind.rawValue)),"
                + "deviceId:\(RAVEJavaScript.string(device.deviceId)),"
                + "groupId:\(RAVEJavaScript.string(device.groupId)),"
                + "label:\(RAVEJavaScript.string(device.label))}"
        }
        let config = "window.__ravenReplayConfig={aspect:\(aspect),nativeCapture:\(nativeCapture),"
            + "avatar:\(avatar),virtual:\(virtual),"
            + "offlineTitle:\(RAVEJavaScript.string(offlineCard.title)),"
            + "offlineHint:\(RAVEJavaScript.string(offlineCard.hint))};\n"
        return WKUserScript(
            source: config + source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }
    /// The `callAsyncJavaScript` body the proxy relays native chunks through,
    /// and the argument names it binds. The payload rides as an argument value
    /// so the page never parses it as source; the page-side `nativeChunk` takes
    /// exactly these five, in this order.
    public static let nativeChunkCall =
        "window.__ravenReplay && window.__ravenReplay.nativeChunk(b64, ts, key, capturedAt, sentAt);"

    /// Every argument goes through one JSON-based escaper. A device label is
    /// attacker-controlled text and hand-quoting it is how script injection
    /// happens.
    public static func command(_ name: String, arguments: [Any] = []) -> String {
        let encoded = arguments.map { RAVEJavaScript.literal($0) }.joined(separator: ",")
        return "window.__ravenReplay && window.__ravenReplay.\(name)(\(encoded));"
    }

    private static let source = #"""
(function () {
  'use strict';
  if (window.__ravenReplay) { return; }

  var CONFIG = window.__ravenReplayConfig || {};
  // Width ÷ height to publish at. Always a concrete ratio — every
  // `CameraFraming` case crops, because this camera has no native shape worth
  // passing through untouched (asking without a ratio already returns a
  // square).
  var TARGET_ASPECT = (typeof CONFIG.aspect === 'number' && CONFIG.aspect > 0)
    ? CONFIG.aspect : 1;
  // Whether the canvas is painted from Raven's own capture session (the
  // sensor's native frame) rather than from the WebKit-granted track. The real
  // getUserMedia is called either way — see the header for what each is for.
  // Decided once: the native source needs a WebCodecs decoder, and a WebKit
  // without one takes the element path from the start rather than failing
  // into it.
  //
  // The avatar source is native by definition — its frames only exist
  // encoded, in Swift — and it is never allowed to start, or end up, on the
  // element: see "The avatar source fails closed" in the header. A WebKit
  // without a decoder therefore gets the offline card, not the real camera.
  //
  // `AVATAR` means "not the wearer's camera, so fail closed", and the virtual
  // device is that too: every fail-closed branch below keys on this one flag.
  // `VIRTUAL` adds only what the virtual device does beyond it (never asking
  // WebKit for the camera, and the device it presents instead).
  var VIRTUAL = (CONFIG.virtual && typeof CONFIG.virtual === 'object' &&
                 typeof CONFIG.virtual.deviceId === 'string') ? CONFIG.virtual : null;
  var AVATAR = CONFIG.avatar === true || VIRTUAL !== null;
  var NATIVE_CAPTURE = AVATAR ||
    (CONFIG.nativeCapture === true && typeof VideoDecoder !== 'undefined');

  var FRAME_TOKEN = String(Math.random()).slice(2) + '-' + Date.now();

  // What to ask WebKit's camera for (the fallback source, and the only source
  // with NATIVE_CAPTURE off). The sensor's own ceiling is 1920×1080 and WebKit
  // hands back portrait regardless of the orientation requested, so this is
  // really "give me 1080 on the short edge".
  var WANT_LONG   = 1920;
  var WANT_SHORT  = 1080;
  // What Raven's own session delivers: the sensor's native format, as Longwave
  // streams it. Provisional geometry only — the first decoded frame corrects it.
  var NATIVE_WIDTH  = 1920;
  var NATIVE_HEIGHT = 1080;
  // Caps on the published frame.
  //
  // The old reasoning for MAX_LONG — "no point publishing above the send tier's
  // budget" — is retired: measured on a live Meet call 2026-09-16, the top
  // simulcast layer is `scale=1` of the source, so the published size *is* the
  // sent size and there is no separate budget to stay under.
  //
  // It was briefly raised to 1920 on the strength of that, and put back. 1920
  // works — Meet really does send 1920×1080 and the far end really does decode it
  // — but **Meet negotiates VP8, and VP8 has no hardware path on Apple silicon in
  // either direction** (VideoToolbox does not implement it; H.264 was tried and
  // Meet's SFU answers an empty codec list, rejecting the m-line outright). So
  // 2.07 MP × three simulcast layers is all software encode on the headset and
  // all software decode at the far end, and the receiver's jitter buffer inflates
  // to absorb the irregular delivery: measured 438 ms held against a 68 ms
  // minimum, with network jitter of 15 ms. That is a delay that grows the longer
  // a call runs, and it is the reason for this number.
  //
  // 1440 publishes 1440×810 for 16:9 — still landscape, still above 720p, 1.17 MP
  // against 3:4's 0.87 MP rather than 2.07. Only 16:9 is affected: 3:4 publishes
  // 810×1080 and square 1080×1080, both already under MAX_SHORT.
  var MAX_SHORT   = 1080;
  var MAX_LONG    = 1440;
  // Where the crop sits vertically in a frame taller than the target. 0.5 is
  // a true centre crop; Center Stage already keeps the wearer centred, so
  // there is no measured reason to bias it, and a guess here would crop
  // someone's forehead off.
  var CROP_BIAS_Y = 0.5;
  var FIRST_PAINT_MS = 4000;
  // The avatar's offline card. Repainted on a timer while shown: a canvas
  // stream only emits a frame when the canvas changes, and a far end that
  // joins (or asks for a keyframe) during an outage needs one to show.
  var OFFLINE_REPAINT_MS = 1000;
  // The app's words (Raven: "Avatar camera offline" / "Open Spatial
  // Character"). A hint may be empty.
  var OFFLINE_TITLE = typeof CONFIG.offlineTitle === 'string' ? CONFIG.offlineTitle : 'Camera offline';
  var OFFLINE_HINT = typeof CONFIG.offlineHint === 'string' ? CONFIG.offlineHint : '';
  // How often the native source reports per-stage latency to Swift. Every
  // millisecond between the sensor and the published canvas is A/V offset at
  // the far end — audio goes from WebKit's capture straight into WebRTC and
  // the video is timestamped only when it lands on the canvas — so this is
  // the number that says whether the camera proxy is causing lip desync, and
  // which stage is doing it.
  var LATENCY_REPORT_MS = 5000;
  // How deep the decoder's own input queue may get before this stops feeding
  // it. **Without this the pipeline has a latency ratchet**, which is what a
  // heavy moment turns into permanent lag: frames arrive at capture rate
  // whatever the decoder is doing, so once it falls behind, nothing ever lets
  // it catch up and the backlog is held for the rest of the call. Measured:
  // 40 ms climbing to 1.3 s over a minute and never recovering. Healthy is
  // 0–2, so 6 leaves room for a transient without letting a backlog form; it
  // also bounds how stale a painted frame can be.
  var MAX_DECODE_QUEUE = 6;

  // The `getSettings()` fields the proxy carries over from the real track, read
  // by name because they are not enumerable. `deviceId` is the load-bearing one —
  // it is how the WebRTC watchdog knows a tile is this device's own camera and
  // must never be re-bound — and `groupId`/`facingMode` are what a device menu
  // shows. Geometry is deliberately not in the list: it is overwritten with what
  // is actually on the wire.
  var SETTING_FIELDS = [
    'deviceId', 'groupId', 'facingMode', 'aspectRatio', 'frameRate', 'resizeMode'
  ];

  function post(message) {
    try {
      message.frame = FRAME_TOKEN;
      window.webkit.messageHandlers.ravenReplay.postMessage(message);
    } catch (e) {}
  }

  var media = navigator.mediaDevices;
  if (!media || typeof media.getUserMedia !== 'function') {
    post({ kind: 'unavailable', reason: 'navigator.mediaDevices.getUserMedia is undefined' });
    return;
  }

  function fromB64(str) {
    if (Uint8Array.fromBase64) { return Uint8Array.fromBase64(str); }
    var bin = atob(str);
    var u8 = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) { u8[i] = bin.charCodeAt(i); }
    return u8;
  }

  var session = null;

  // ---- constraints -------------------------------------------------------

  /// Ask for the largest feed the camera will give, keeping everything the page
  /// pinned. `deviceId: {exact: …}` in particular must survive — Meet names the
  /// device it wants and a different one would be the wrong camera entirely.
  ///
  /// `ideal`, never `exact`, so a camera that cannot do 1080 simply gives what it
  /// has instead of rejecting. `aspectRatio` is dropped when cropping: the page
  /// asks for 16:9 and visionOS hands back portrait anyway (measured — Meet asks
  /// 1280×720 and receives 720×1280), and honouring it would throw away the very
  /// bands the crop exists to reclaim.
  function upgradeVideo(video) {
    var out = {};
    if (video && typeof video === 'object') {
      for (var k in video) { out[k] = video[k]; }
    }
    // The ask is the same whatever the target aspect, and deliberately so: it is
    // *dropping* `aspectRatio` that gets 1080×1080 out of this camera, and the
    // shape is then taken in the canvas. Asking for the target ratio instead
    // would re-introduce exactly the constraint that produced a 720×1280 feed
    // for Meet.
    delete out.aspectRatio;
    out.width = { ideal: WANT_SHORT };
    out.height = { ideal: WANT_LONG };
    return out;
  }

  function upgradeConstraints(constraints) {
    try {
      var out = {};
      for (var k in constraints) { out[k] = constraints[k]; }
      out.video = upgradeVideo(constraints.video);
      return out;
    } catch (e) {
      return constraints;
    }
  }

  // ---- geometry ----------------------------------------------------------

  function even(n) { n = Math.round(n); return n - (n % 2); }

  /// The source rectangle to lift out of a frame of `w`×`h`, and the size to
  /// publish it at. Even dimensions throughout: some encoders reject odd ones.
  ///
  /// The crop is the largest rectangle of the target aspect that fits inside
  /// what the source gave, centred. Against the native 1920×1080 every framing
  /// keeps the full height — 3:4 is 810 wide, square 1080, 16:9 the whole frame
  /// (published at 1440×810 under the caps). Against the 1080×1080 the WebKit
  /// fallback returns, 3:4 trims the sides, square is the whole frame, and
  /// 16:9 is clamped to the source width, 1080×608.
  function computeGeometry(w, h) {
    if (!w || !h) { return null; }

    var ch = h;
    var cw = ch * TARGET_ASPECT;
    if (cw > w) { cw = w; ch = cw / TARGET_ASPECT; }
    cw = Math.round(cw);
    ch = Math.round(ch);
    var sx = Math.round((w - cw) / 2);
    var sy = Math.round((h - ch) * CROP_BIAS_Y);

    // Scale down to the caps, preserving the crop's aspect exactly — scaling the
    // axes independently is how a frame ends up subtly stretched.
    var long = Math.max(cw, ch), short = Math.min(cw, ch);
    var scale = Math.min(1, MAX_LONG / long, MAX_SHORT / short);
    return {
      sx: sx, sy: sy, sw: cw, sh: ch,
      outW: Math.max(2, even(cw * scale)), outH: Math.max(2, even(ch * scale))
    };
  }

  function sameGeometry(a, b) {
    return !!a && !!b && a.sx === b.sx && a.sy === b.sy && a.sw === b.sw &&
           a.sh === b.sh && a.outW === b.outW && a.outH === b.outH;
  }

  // ---- teardown ----------------------------------------------------------

  function teardown() {
    if (!session) { return; }
    var s = session;
    session = null;
    if (s.paintTimer) { clearTimeout(s.paintTimer); }
    clearOffline(s);
    closeNativeDecoder(s);
    // Swift's capture session must be released with the page's proxy — it is
    // what holds the camera (and the indicator) while the native source runs.
    if (s.nativeStarted) { s.nativeStarted = false; post({ kind: 'nativeStop' }); }
    try { s.sourceVideo.pause(); s.sourceVideo.srcObject = null; } catch (e) {}
    var nodes = [s.sourceVideo, s.canvas];
    for (var i = 0; i < nodes.length; i++) {
      try {
        if (nodes[i] && nodes[i].parentNode) { nodes[i].parentNode.removeChild(nodes[i]); }
      } catch (e) {}
    }
  }

  function stopRealTracks(s) {
    s.realTrackReleased = true;
    try {
      var tracks = s.realStream.getVideoTracks();
      for (var i = 0; i < tracks.length; i++) { tracks[i].stop(); }
    } catch (e) {}
  }

  // The `getSettings()` / `getCapabilities()` fields worth carrying, copied by
  // name because neither dictionary is enumerable on this WebKit (see
  // `patchTrack`). Geometry is included here only so the snapshot is complete;
  // the proxy overwrites it with what is actually on the wire.
  var CAPABILITY_FIELDS = [
    'deviceId', 'groupId', 'facingMode', 'width', 'height', 'aspectRatio', 'frameRate', 'resizeMode'
  ];

  function copyFields(source, names) {
    var out = {};
    if (!source) { return out; }
    for (var i = 0; i < names.length; i++) {
      try {
        if (source[names[i]] !== undefined) { out[names[i]] = source[names[i]]; }
      } catch (e) {}
    }
    return out;
  }

  /// Makes `stream`/`track` the session's real camera — at grant, and again
  /// when the native source falls back to WebKit's. The identity is snapshotted
  /// *now*: in native mode this track is stopped a moment later, and a stopped
  /// track cannot be trusted to keep answering `getSettings()`, while the proxy
  /// has to report `deviceId` for the whole call — it is what tells the WebRTC
  /// watchdog the self-view is local and must never be re-bound.
  function adoptRealStream(s, stream, track) {
    s.realStream = stream;
    s.realTrack = track;
    s.realTrackReleased = false;
    try { s.realSettings = copyFields(track.getSettings ? track.getSettings() : null, CAPABILITY_FIELDS); }
    catch (e) { s.realSettings = {}; }
    try { s.realCapabilities = copyFields(track.getCapabilities ? track.getCapabilities() : null, CAPABILITY_FIELDS); }
    catch (e) { s.realCapabilities = {}; }
    try { s.realLabel = track.label || ''; } catch (e) { s.realLabel = ''; }
    try {
      track.addEventListener('ended', function () {
        // A track this script stopped itself (native mode releases it on
        // purpose) is not the source dying; only the current, still-wanted
        // real track ending is.
        if (session !== s || s.realTrack !== track || s.realTrackReleased) { return; }
        try { if (s.proxyTrack) { s.proxyTrack.dispatchEvent(new Event('ended')); } } catch (e) {}
        post({ kind: 'stopped' });
        teardown();
      });
    } catch (e) {}
  }

  /// Live settings while the real track is live; the grant-time snapshot once
  /// it is not.
  function realSettings(s) {
    try {
      var track = s.realTrack;
      if (track && !s.realTrackReleased && track.readyState === 'live' && track.getSettings) {
        return track.getSettings() || {};
      }
    } catch (e) {}
    return s.realSettings || {};
  }

  // ---- the native source -------------------------------------------------

  function closeNativeDecoder(s) {
    try { if (s.nativeDecoder && s.nativeDecoder.state !== 'closed') { s.nativeDecoder.close(); } } catch (e) {}
    s.nativeDecoder = null;
    s.nativePending = null;
    s.nativeStats = null;
  }

  // ---- native latency accounting ----
  //
  // Swift stamps each chunk with the sensor's capture instant and the moment
  // it was handed to the bridge, both wall-clock epoch ms; the page stamps
  // arrival, decoder output and paint completion on the same clock. Chunks
  // and decoded frames are matched by `timestamp`, which `VideoDecoder`
  // preserves. Stages:
  //   upstream = sentAt   - capturedAt   (capture, encode, base64, main hop)
  //   bridge   = arrived  - sentAt       (the JS call reaching the page)
  //   decode   = output   - arrived      (VideoDecoder, incl. its queue)
  //   paint    = painted  - output       (the canvas draws)
  //   total    = painted  - capturedAt
  // What no side can observe is the canvas-capture tick after `painted` —
  // `captureStream` lifts the frame on the next rendering update. A replayed
  // chunk carries no capture instant (Swift sends -1), so it contributes to
  // the bridge, decode and paint stages and not to upstream or total.

  function newLatencyStats() {
    var mk = function () { return { n: 0, sum: 0, max: 0 }; };
    return { since: Date.now(), frames: 0, queueMax: 0,
             upstream: mk(), bridge: mk(), decode: mk(), paint: mk(), total: mk() };
  }

  function addStage(stage, ms) {
    if (!isFinite(ms)) { return; }
    stage.n++; stage.sum += ms; if (ms > stage.max) { stage.max = ms; }
  }

  function stagePair(stage) {
    return [stage.n ? Math.round(stage.sum / stage.n) : -1, Math.round(stage.max)];
  }

  function noteLatency(s, meta, output, painted) {
    if (!s.nativeStats) { s.nativeStats = newLatencyStats(); }
    var st = s.nativeStats;
    st.frames++;
    var hasCapture = meta.capturedAt > 0;
    if (hasCapture) { addStage(st.upstream, meta.sentAt - meta.capturedAt); }
    addStage(st.bridge, meta.arrived - meta.sentAt);
    addStage(st.decode, output - meta.arrived);
    addStage(st.paint, painted - output);
    if (hasCapture) { addStage(st.total, painted - meta.capturedAt); }
    if (painted - st.since >= LATENCY_REPORT_MS) {
      post({
        kind: 'nativeLatency', frames: st.frames, queueMax: st.queueMax,
        upstream: stagePair(st.upstream), bridge: stagePair(st.bridge),
        decode: stagePair(st.decode), paint: stagePair(st.paint), total: stagePair(st.total)
      });
      s.nativeStats = newLatencyStats();
    }
  }

  /// Parameter sets from Swift: once up front, again if the encoder changed
  /// them, and around a replay whose reversed half was encoded by a different
  /// session — in each case the decoder is replaced and the canvas, and the
  /// track the page holds, survive. The chunk after a configure is always a
  /// keyframe (Swift guarantees it), so `nativeNeedKey` costs nothing here.
  function configureNativeDecoder(s, codec, avcCB64) {
    closeNativeDecoder(s);
    var decoder = new VideoDecoder({
      output: function (frame) { onNativeFrame(s, frame); },
      error: function (e) {
        fallBackToElement(s, 'native decoder: ' + String((e && e.name) || e));
      }
    });
    decoder.configure({ codec: codec, description: fromB64(avcCB64), optimizeForLatency: true });
    s.nativeDecoder = decoder;
    s.nativeNeedKey = true;
  }

  /// `paintFrame`'s crop (`drawImage` with explicit `sx,sy,sw,sh`) is correct on
  /// paper — `computeGeometry` was checked by hand against the native
  /// 1920×1080 for 3:4 and square — but on this WebKit a `VideoFrame` source
  /// does not honour that source rectangle: it falls back to the whole-frame,
  /// stretched-into-`outW`×`outH` behaviour of the 4-argument form. 16:9 looks
  /// correct only because its crop already *is* the whole frame, so stretching
  /// the whole frame into a same-aspect destination is indistinguishable from
  /// cropping. A canvas source crops correctly on this WebKit — the WebKit
  /// fallback path has relied on exactly that, via `HTMLVideoElement`, since
  /// before the native source existed — so the decoded frame is painted
  /// uncropped onto an intermediate canvas first, and *that* canvas is what
  /// gets cropped.
  function onNativeFrame(s, frame) {
    var output = Date.now();
    var meta = null;
    if (s.nativePending) {
      meta = s.nativePending.get(frame.timestamp) || null;
      if (meta) { s.nativePending.delete(frame.timestamp); }
    }
    try {
      if (session === s && s.source === 'native') {
        var w = frame.displayWidth, h = frame.displayHeight;
        if (!s.nativeSourceCanvas) {
          s.nativeSourceCanvas = document.createElement('canvas');
          s.nativeSourceCtx = s.nativeSourceCanvas.getContext('2d', { alpha: false, desynchronized: true });
        }
        if (s.nativeSourceCanvas.width !== w || s.nativeSourceCanvas.height !== h) {
          s.nativeSourceCanvas.width = w;
          s.nativeSourceCanvas.height = h;
        }
        s.nativeSourceCtx.drawImage(frame, 0, 0, w, h);
        paintFrame(s, s.nativeSourceCanvas, w, h);
        // A decoded frame is the avatar back: the card stops here.
        if (s.offline) { clearOffline(s); }
        if (meta) { noteLatency(s, meta, output, Date.now()); }
      }
    } finally {
      try { frame.close(); } catch (e) {}
    }
  }

  /// Swift's frames form a delta chain, so joining — and rejoining after the
  /// relay had to drop — has to start on a keyframe. Deltas ahead of the first
  /// key are discarded rather than handed to a decoder that would only fault
  /// on them and take the whole source down with it.
  function nativeChunk(s, b64, timestamp, key, capturedAt, sentAt) {
    var arrived = Date.now();
    if (!s.nativeDecoder || s.nativeDecoder.state !== 'configured') { return; }
    // Behind: drop deltas rather than deepen the queue, and ask Swift for a
    // keyframe so rejoining costs one frame instead of the rest of the GOP.
    // Keyframes are never dropped here — one is the whole cure, and the
    // backlog ahead of it drains on its own once nothing is being added.
    if (!key && s.nativeDecoder.decodeQueueSize > MAX_DECODE_QUEUE) {
      if (!s.nativeNeedKey) {
        s.nativeNeedKey = true;
        post({ kind: 'decoderBehind', queue: s.nativeDecoder.decodeQueueSize });
      }
      return;
    }
    if (s.nativeNeedKey) {
      if (!key) { return; }
      s.nativeNeedKey = false;
    }
    try {
      s.nativeDecoder.decode(new EncodedVideoChunk({
        type: key ? 'key' : 'delta', timestamp: timestamp, data: fromB64(b64)
      }));
    } catch (e) {
      fallBackToElement(s, 'native decode: ' + String((e && e.name) || e));
      return;
    }
    if (!s.nativePending) { s.nativePending = new Map(); }
    s.nativePending.set(timestamp, { capturedAt: capturedAt, sentAt: sentAt, arrived: arrived });
    // A frame the decoder never emits (a fault, a reconfigure) would leak its
    // entry; bounded by dropping the oldest once the map is a few seconds deep.
    if (s.nativePending.size > 120) {
      s.nativePending.delete(s.nativePending.keys().next().value);
    }
    if (!s.nativeStats) { s.nativeStats = newLatencyStats(); }
    var depth = s.nativeDecoder.decodeQueueSize || 0;
    if (depth > s.nativeStats.queueMax) { s.nativeStats.queueMax = depth; }
  }

  /// The native source is gone — no frame in time, Swift reported the session
  /// ending, the decoder faulted. The proxy track the page holds is untouched;
  /// what changes is where its pixels come from. The real camera is requested
  /// again from WebKit, upgraded to 1080 on the short edge exactly as the
  /// pure-WebKit path asks, and the element becomes the source. One attempt:
  /// a fallback whose own camera never paints degrades exactly as that path
  /// does, to the real stream.
  function fallBackToElement(s, why) {
    if (session !== s || s.source !== 'native') { return; }
    // Fail closed. Every caller — no first frame, `nativeEnd`, a decoder
    // fault, a site calling the command itself — reaches this line, and with
    // the avatar as the source WebKit's camera is the one thing that must
    // never paint. The card goes up instead and Swift is asked to reconnect.
    if (AVATAR) { avatarFault(s, why); return; }
    s.source = 'element';
    // The native arming's paint timer must not fire into the gap while the
    // fresh camera request is in flight — it would degrade to a real stream
    // this script has already stopped. It is re-armed once the element plays.
    if (s.paintTimer) { clearTimeout(s.paintTimer); s.paintTimer = null; }
    closeNativeDecoder(s);
    if (s.nativeStarted) { s.nativeStarted = false; post({ kind: 'nativeStop' }); }
    post({ kind: 'error', scope: 'native', message: why + ' — falling back to WebKit capture' });

    nativeGetUserMedia(upgradeConstraints(s.constraints)).then(function (fresh) {
      if (session !== s) {
        try { fresh.getTracks().forEach(function (t) { t.stop(); }); } catch (e) {}
        return;
      }
      var video = [];
      try { video = fresh.getVideoTracks(); } catch (e) {}
      if (!video.length) { throw new DOMException('camera returned no video track', 'NotFoundError'); }
      adoptRealStream(s, fresh, video[0]);
      s.sourceVideo.srcObject = fresh;
      return s.sourceVideo.play().catch(function () {}).then(function () {
        if (session !== s) { return; }
        armPaintTimer(s);
        startElementLoop(s);
      });
    }).catch(function (e) {
      if (session !== s) { return; }
      var message = 'fallback camera request failed: ' + String((e && e.name) || e);
      if (s.settle) {
        // Nothing left to hand the page but the error — the grant-time stream
        // was released for the native session and cannot be revived.
        post({ kind: 'error', scope: 'setup', message: message });
        var settle = s.settle;
        teardown();
        settle(null, e);
      } else {
        post({ kind: 'error', scope: 'native', message: message + '; the published frame will not update' });
      }
    });
  }

  // ---- the avatar's offline card (fail closed) ---------------------------

  function viaLabel(s) { return VIRTUAL ? 'virtual' : AVATAR ? 'avatar' : s.source; }

  function clearOffline(s) {
    s.offline = false;
    if (s.offlineTimer) { clearInterval(s.offlineTimer); s.offlineTimer = null; }
  }

  /// The avatar is not coming (Swift's `nativeOffline`) or could not be shown
  /// (`avatarFault`). The decoder goes — Swift sends a fresh configuration
  /// with the next subscription, and the chunk after a configure is a
  /// keyframe — and the card is painted on the proxy canvas the page already
  /// holds, until a decoded frame replaces it. Never the real camera.
  function goOffline(s, why) {
    if (session !== s) { return; }
    closeNativeDecoder(s);
    s.nativeNeedKey = true;
    s.offline = true;
    paintPlaceholder(s);
    if (!s.offlineTimer) {
      s.offlineTimer = setInterval(function () {
        if (session !== s || !s.offline) { clearOffline(s); return; }
        paintPlaceholder(s);
      }, OFFLINE_REPAINT_MS);
    }
  }

  /// A failure the page found itself: Swift may think the avatar is live, so
  /// it is told, and resubscribes. It ignores this while already reconnecting.
  function avatarFault(s, why) {
    goOffline(s, why);
    post({ kind: 'avatarFault', reason: String(why) });
  }

  /// A dark frame and two short lines, sized to the published canvas. Black
  /// instead while the page has the track disabled, as any frame would be.
  /// Counts as the first paint, so a page waiting on `getUserMedia` gets its
  /// track with the card on it rather than an error: the call goes on, with
  /// the avatar, as soon as it is back.
  function paintPlaceholder(s) {
    if (session !== s || !s.geometry) { return; }
    var g = s.geometry;
    try {
      var ctx = s.ctx;
      ctx.fillStyle = s.enabled ? '#1c1c1e' : '#000';
      ctx.fillRect(0, 0, g.outW, g.outH);
      if (s.enabled) {
        var size = Math.max(14, Math.round(Math.min(g.outW, g.outH) / 18));
        var maxWidth = g.outW * 0.9;
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillStyle = '#ebebf0';
        ctx.font = '600 ' + size + 'px -apple-system, system-ui, sans-serif';
        ctx.fillText(OFFLINE_TITLE, g.outW / 2, g.outH / 2 - (OFFLINE_HINT ? size * 0.7 : 0), maxWidth);
        if (OFFLINE_HINT) {
          ctx.fillStyle = '#a1a1aa';
          ctx.font = '400 ' + Math.round(size * 0.8) + 'px -apple-system, system-ui, sans-serif';
          ctx.fillText(OFFLINE_HINT, g.outW / 2, g.outH / 2 + size * 0.7, maxWidth);
        }
      }
    } catch (e) {}
    if (!s.painted) {
      s.painted = true;
      post({
        kind: 'geometry', phase: 'offline', via: viaLabel(s), source: 'offline-card', crop: 'none',
        width: g.outW, height: g.outH, aspect: Math.round(TARGET_ASPECT * 1000) / 1000
      });
      onFirstPaint(s);
    }
  }

  // ---- first paint and the timer that bounds it --------------------------

  /// Hand the stream over only once the canvas has really painted. Resolving at
  /// setup gives the page a black rectangle with no error anywhere — the trap
  /// the screen-share shim documents — and Meet would publish it.
  function armPaintTimer(s) {
    if (s.paintTimer) { clearTimeout(s.paintTimer); }
    s.painted = false;
    s.paintTimer = setTimeout(function () { onPaintTimeout(s); }, FIRST_PAINT_MS);
  }

  function onPaintTimeout(s) {
    s.paintTimer = null;
    if (session !== s || s.painted) { return; }
    if (AVATAR) {
      avatarFault(s, 'no avatar frame within ' + FIRST_PAINT_MS + ' ms');
    } else if (s.source === 'native') {
      fallBackToElement(s, 'native camera produced no frame within ' + FIRST_PAINT_MS + ' ms');
    } else if (s.settle) {
      degradeToRealStream(s, 'canvas never painted');
    } else {
      // Already armed on the native source, and the fallback element never
      // painted: the page keeps its track and the frame stays where it was.
      post({ kind: 'error', scope: 'native', message: 'fallback camera never painted' });
    }
  }

  /// Degraded to the behaviour without this feature rather than a black tile:
  /// the page gets the real camera, uncropped, and Raven is out of the path.
  function degradeToRealStream(s, why) {
    // Fail closed, second line: unreachable with the avatar (its source is
    // never the element), and refused anyway.
    if (AVATAR) { avatarFault(s, why); return; }
    var settle = s.settle;
    var real = s.realStream;
    // A stream whose track this script stopped (the native path releases it)
    // is not a working camera to hand over; the honest answer is the error.
    var usable = !!real && !s.realTrackReleased;
    post({
      kind: 'error', scope: 'setup',
      message: why + (usable ? '; passing the real stream through' : '; no camera left to pass through')
    });
    s.settle = null;
    teardown();
    if (!settle) { return; }
    if (usable) { settle(real, null); }
    else { settle(null, new DOMException('The camera could not be started', 'NotReadableError')); }
  }

  /// `via` tells Swift which source painted. Only `native` can be replayed —
  /// Swift's ring holds its own feed's frames and nothing else — so the bridge
  /// arms the replay controls on this and on its own feed being live, never
  /// on the page's word alone.
  function onFirstPaint(s) {
    if (s.paintTimer) { clearTimeout(s.paintTimer); s.paintTimer = null; }
    if (!s.settle) { return; }
    post({ kind: 'armed', width: s.outW, height: s.outH, via: viaLabel(s) });
    s.settle(s.proxyStream, null);
  }

  function startElementLoop(s) {
    if (AVATAR) { return; }
    try {
      s.sourceVideo.requestVideoFrameCallback(function () { onElementFrame(s); });
    } catch (e) {
      if (s.settle) { degradeToRealStream(s, 'requestVideoFrameCallback unavailable'); }
    }
  }

  // ---- the frame loop ----------------------------------------------------

  function onElementFrame(s) {
    if (AVATAR || session !== s || s.source !== 'element') { return; }
    var el = s.sourceVideo;
    paintFrame(s, el, el.videoWidth, el.videoHeight);
    try { el.requestVideoFrameCallback(function () { onElementFrame(s); }); } catch (e) {}
  }

  /// One frame from whichever source is current — the element (WebKit's
  /// track) or a decoded `VideoFrame` (Raven's session, via the intermediate
  /// canvas). Both are valid `drawImage` sources, so everything from the crop
  /// onward is shared. The canvas this draws into is the one `captureStream`
  /// publishes; a replay arrives as ordinary chunks and lands here like any
  /// other frame.
  function paintFrame(s, image, w, h) {
    // The camera can reconfigure mid-stream (a constraint change, the source
    // switching). Recompute rather than assume. Assigning a canvas dimension
    // clears it even when the value is unchanged, so only a real change
    // touches the size — a resize of the published canvas also renegotiates
    // the far end's tile, which is worth doing exactly when the geometry
    // really moved and never otherwise.
    var geometry = computeGeometry(w, h);
    if (geometry && !sameGeometry(geometry, s.geometry)) {
      s.geometry = geometry;
      if (s.canvas.width !== geometry.outW || s.canvas.height !== geometry.outH) {
        s.canvas.width = geometry.outW;
        s.canvas.height = geometry.outH;
      }
      s.outW = geometry.outW;
      s.outH = geometry.outH;
    }
    if (!s.geometry) { return; }

    try {
      var g = s.geometry;
      if (s.enabled) {
        s.ctx.drawImage(image, g.sx, g.sy, g.sw, g.sh, 0, 0, g.outW, g.outH);
      } else {
        // `enabled = false` is the page's own camera-off switch, and a
        // disabled track sends black. The WebKit source went black on its
        // own (the element renders a disabled track black); the native
        // source has no track underneath to do that, so paint it here for
        // both.
        s.ctx.fillStyle = '#000';
        s.ctx.fillRect(0, 0, g.outW, g.outH);
      }
      if (!s.painted) {
        s.painted = true;
        post({
          kind: 'geometry', phase: 'live', via: viaLabel(s),
          source: w + 'x' + h,
          crop: g.sw + 'x' + g.sh + '+' + g.sx + '+' + g.sy,
          width: g.outW, height: g.outH,
          aspect: Math.round(TARGET_ASPECT * 1000) / 1000
        });
        onFirstPaint(s);
      }
    } catch (e) {}
  }

  // ---- track patching ----------------------------------------------------

  // Instance-level, so the page sees a camera track rather than a canvas one.
  // `getSettings` is what a site fingerprints to decide it has a real device and
  // `label` is what it shows in a device menu; the canvas supplies the geometry
  // because that is what is genuinely being sent. `deviceId` in particular has to
  // survive — the WebRTC watchdog reads it to tell a local tile from a remote one,
  // and a self-view misread as remote becomes eligible for stream re-binding.
  function patchTrack(s) {
    var proxy = s.proxyTrack;
    // A virtual device has no real track at all; its identity is the snapshot
    // `adoptVirtualIdentity` wrote, served by the same getters.
    if (!proxy || (!s.realTrack && !s.virtual)) { return; }
    // `s.realTrack` is read at call time throughout, never captured: a native
    // session falling back to WebKit's camera adopts a fresh real track, and
    // the proxy — which the page keeps — has to mirror the current one.

    try {
      var canvasSettings = proxy.getSettings ? proxy.getSettings.bind(proxy) : null;
      proxy.getSettings = function () {
        var out = {};
        try {
          var current = realSettings(s);
          // **Copied by name, not by `for...in`.** The first version enumerated,
          // and on this WebKit `MediaTrackSettings` properties are not
          // enumerable, so it silently copied *nothing* — measured: the proxy
          // track reported no `deviceId`, the WebRTC watchdog reads exactly that
          // field to tell a local tile from a remote one, and the self-view was
          // logged as `remote`. Harmless while it paints, but a remote-classified
          // element is eligible for stream re-binding, which is the action that
          // broke Meet's camera earlier in this project.
          for (var i = 0; i < SETTING_FIELDS.length; i++) {
            var k = SETTING_FIELDS[i];
            try {
              if (current[k] !== undefined) { out[k] = current[k]; }
            } catch (e) {}
          }
        } catch (e) {}
        try {
          var mine = canvasSettings ? canvasSettings() : {};
          if (mine.frameRate) { out.frameRate = mine.frameRate; }
        } catch (e) {}
        // The published geometry, not the sensor's — this is what is on the wire.
        out.width = s.canvas.width;
        out.height = s.canvas.height;
        if (out.aspectRatio) { out.aspectRatio = out.width / out.height; }
        if (!out.frameRate) { out.frameRate = 30; }
        return out;
      };
    } catch (e) {}

    try {
      proxy.getCapabilities = function () {
        try {
          var track = s.realTrack;
          if (track && !s.realTrackReleased && track.readyState === 'live' && track.getCapabilities) {
            return track.getCapabilities() || {};
          }
        } catch (e) {}
        return s.realCapabilities || {};
      };
    } catch (e) {}

    try {
      Object.defineProperty(proxy, 'label', {
        get: function () {
          try { if (s.realTrack && s.realTrack.label) { return s.realTrack.label; } } catch (e) {}
          return s.realLabel || '';
        },
        configurable: true
      });
    } catch (e) {}

    try {
      proxy.applyConstraints = function (constraints) {
        // The virtual device takes any constraint and reads it back naming
        // itself; the crop follows the canvas regardless.
        if (s.virtual) {
          s.virtualConstraints = virtualConstraints(constraints, s.virtual);
          return Promise.resolve();
        }
        // Forwarded so a page narrowing its request still reaches the sensor;
        // the crop follows whatever geometry comes back on the next frame. With
        // the native source there is no live WebKit track to narrow, and the
        // published geometry is the crop's regardless.
        try {
          var track = s.realTrack;
          if (track && !s.realTrackReleased && track.applyConstraints) {
            return track.applyConstraints(constraints);
          }
        } catch (e) {}
        return Promise.resolve();
      };
    } catch (e) {}

    if (s.virtual) {
      try {
        proxy.getConstraints = function () { return copyConstraints(s.virtualConstraints); };
      } catch (e) {}
    }

    try {
      var originalStop = proxy.stop.bind(proxy);
      proxy.stop = function () {
        // The real sensor must be released or the OS capture indicator stays lit
        // after the page thinks it stopped — Meet's camera-off *is* a `stop()`,
        // so this is the common path, not an edge case.
        stopRealTracks(s);
        originalStop();
        post({ kind: 'stopped' });
        teardown();
      };
    } catch (e) {}

    try {
      // `enabled` is the page's own switch. Mirroring it means camera-off really
      // turns the sensor off, and telling Swift keeps frames from a
      // deliberately-off camera out of the ring — a privacy property, not an
      // optimisation.
      Object.defineProperty(proxy, 'enabled', {
        get: function () { return s.enabled; },
        set: function (value) {
          s.enabled = !!value;
          try { if (s.realTrack && !s.realTrackReleased) { s.realTrack.enabled = !!value; } } catch (e) {}
          post({ kind: 'enabled', value: s.enabled });
        },
        configurable: true
      });
    } catch (e) {}
  }

  // ---- getUserMedia ------------------------------------------------------

  var nativeGetUserMedia = media.getUserMedia.bind(media);

  // ---- the virtual device ------------------------------------------------
  //
  // `RAVECameraProxy.Mode.virtualDevice`: the page's camera is a device that
  // exists only in this script, painted from a feed the app supplies, and
  // WebKit is never asked for a camera at all — not for consent, not for
  // identity, not as a fallback. So everything a page can look at to decide
  // which camera it holds has to agree with itself, because Meet checks: it
  // stopped a synthesized *microphone* 24 ms after receiving it (Raven,
  // "Relocation has two halves"), having matched the track's `deviceId`
  // against its own `enumerateDevices` list, found nothing, and decided there
  // was no microphone. The list was empty because WebKit lists real ids only
  // after a grant. A virtual device owes the page the whole picture:
  //
  // - `enumerateDevices` lists it — stable id, group id, label — before and
  //   after any permission, in place of every real entry of its kind (in this
  //   mode there is no other camera to pick). Other kinds pass through as
  //   WebKit reports them.
  // - The track's `getSettings()`, `getCapabilities()`, `getConstraints()` and
  //   `label` name the same device.
  // - A request naming any camera — `deviceId` exact or ideal, its own id or
  //   someone else's — gets this one, and the constraints read back with its
  //   id. There is nothing else to give, and the real camera must never start.
  // - `permissions.query({ name: 'camera' })` answers `granted`, with a
  //   `change` event that never fires because nothing ever changes.
  // - It is listed from document start, so it never "appears" and no
  //   `devicechange` is owed.
  //
  // Generic over the kind (`DEVICE_KINDS`): video is the only kind Swift
  // configures today; a microphone answered from an app's own audio engine
  // would be another entry, with its own track plumbing.
  var DEVICE_KINDS = {
    videoinput: { track: 'video', constraint: 'video', permission: 'camera' },
    audioinput: { track: 'audio', constraint: 'audio', permission: 'microphone' }
  };
  var VIRTUAL_DEVICES = (VIRTUAL && DEVICE_KINDS[VIRTUAL.kind]) ? [VIRTUAL] : [];

  function virtualDevice(kind) {
    for (var i = 0; i < VIRTUAL_DEVICES.length; i++) {
      if (VIRTUAL_DEVICES[i].kind === kind) { return VIRTUAL_DEVICES[i]; }
    }
    return null;
  }

  function virtualDeviceForPermission(name) {
    for (var i = 0; i < VIRTUAL_DEVICES.length; i++) {
      if (DEVICE_KINDS[VIRTUAL_DEVICES[i].kind].permission === name) { return VIRTUAL_DEVICES[i]; }
    }
    return null;
  }

  var VIRTUAL_VIDEO = virtualDevice('videoinput');

  function defineValue(object, name, value, enumerable) {
    try {
      Object.defineProperty(object, name, {
        value: value, enumerable: enumerable, configurable: true, writable: false
      });
    } catch (e) {
      try { object[name] = value; } catch (e2) {}
    }
  }

  function virtualSettings(device) {
    return { deviceId: device.deviceId, groupId: device.groupId, frameRate: 30 };
  }

  function virtualCapabilities(device) {
    return {
      deviceId: device.deviceId, groupId: device.groupId,
      width: { min: 1, max: MAX_LONG }, height: { min: 1, max: MAX_LONG },
      frameRate: { min: 1, max: 30 }, facingMode: [], resizeMode: ['none', 'crop-and-scale']
    };
  }

  /// Whatever form the page named a device in — exact, ideal, bare, a list —
  /// the answer names this one, in the same form where there is one.
  function sameIdForm(value, id) {
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      if (value.exact !== undefined) { return { exact: id }; }
      if (value.ideal !== undefined) { return { ideal: id }; }
    }
    return id;
  }

  /// The page's video constraints as `getConstraints()` reports them: what it
  /// asked for, with any device naming the virtual one.
  function virtualConstraints(asked, device) {
    var out = {};
    if (asked && typeof asked === 'object') {
      for (var k in asked) { out[k] = asked[k]; }
    }
    if (out.deviceId !== undefined) { out.deviceId = sameIdForm(out.deviceId, device.deviceId); }
    if (out.groupId !== undefined) { out.groupId = sameIdForm(out.groupId, device.groupId); }
    return out;
  }

  function copyConstraints(constraints) {
    var out = {};
    for (var k in (constraints || {})) { out[k] = constraints[k]; }
    return out;
  }

  /// The session's identity is the virtual device's, in the fields the proxy
  /// track already serves from a real track's grant-time snapshot.
  function adoptVirtualIdentity(s, device, constraints) {
    s.virtual = device;
    s.realStream = null;
    s.realTrack = null;
    s.realTrackReleased = true;
    s.realSettings = virtualSettings(device);
    s.realCapabilities = virtualCapabilities(device);
    s.realLabel = device.label;
    var video = null;
    try { video = constraints && constraints.video; } catch (e) {}
    s.virtualConstraints = virtualConstraints(video, device);
  }

  /// An `InputDeviceInfo` where the engine has one, so `instanceof` checks
  /// pass; own data properties, which shadow the prototype's getters.
  function makeDeviceInfo(device) {
    var proto = null;
    try {
      if (typeof InputDeviceInfo === 'function') { proto = InputDeviceInfo.prototype; }
      else if (typeof MediaDeviceInfo === 'function') { proto = MediaDeviceInfo.prototype; }
    } catch (e) {}
    var info = proto ? Object.create(proto) : {};
    defineValue(info, 'deviceId', device.deviceId, true);
    defineValue(info, 'kind', device.kind, true);
    defineValue(info, 'label', device.label, true);
    defineValue(info, 'groupId', device.groupId, true);
    defineValue(info, 'getCapabilities', function () { return virtualCapabilities(device); }, false);
    defineValue(info, 'toJSON', function () {
      return { deviceId: device.deviceId, kind: device.kind, label: device.label, groupId: device.groupId };
    }, false);
    return info;
  }

  function withVirtualDevices(list) {
    var items = [];
    try { items = Array.prototype.slice.call(list || []); } catch (e) {}
    var out = [], placed = {};
    for (var i = 0; i < items.length; i++) {
      var kind = '';
      try { kind = items[i].kind; } catch (e) {}
      var device = virtualDevice(kind);
      if (!device) { out.push(items[i]); continue; }
      if (!placed[kind]) { placed[kind] = true; out.push(makeDeviceInfo(device)); }
    }
    for (var j = 0; j < VIRTUAL_DEVICES.length; j++) {
      var missing = VIRTUAL_DEVICES[j];
      if (placed[missing.kind]) { continue; }
      // WebKit lists inputs before outputs; keep the device among the inputs.
      var at = out.length;
      for (var n = 0; n < out.length; n++) {
        var outKind = '';
        try { outKind = out[n].kind; } catch (e) {}
        if (outKind === 'audiooutput') { at = n; break; }
      }
      out.splice(at, 0, makeDeviceInfo(missing));
    }
    return out;
  }

  function makePermissionStatus(name) {
    var proto = null;
    try { if (typeof PermissionStatus === 'function') { proto = PermissionStatus.prototype; } } catch (e) {}
    var status = proto ? Object.create(proto) : {};
    defineValue(status, 'name', name, true);
    defineValue(status, 'state', 'granted', true);
    try {
      Object.defineProperty(status, 'onchange', {
        value: null, writable: true, enumerable: true, configurable: true
      });
    } catch (e) {}
    defineValue(status, 'addEventListener', function () {}, false);
    defineValue(status, 'removeEventListener', function () {}, false);
    defineValue(status, 'dispatchEvent', function () { return true; }, false);
    return status;
  }

  if (VIRTUAL_DEVICES.length) {
    if (typeof media.enumerateDevices === 'function') {
      var nativeEnumerateDevices = media.enumerateDevices.bind(media);
      var virtualEnumerateDevices = function () {
        return nativeEnumerateDevices().then(withVirtualDevices, function () {
          return withVirtualDevices([]);
        });
      };
      try { media.enumerateDevices = virtualEnumerateDevices; } catch (e) {}
      try {
        if (typeof MediaDevices !== 'undefined' &&
            typeof MediaDevices.prototype.enumerateDevices === 'function') {
          MediaDevices.prototype.enumerateDevices = virtualEnumerateDevices;
        }
      } catch (e) {}
    }
    var permissions = null;
    try { permissions = navigator.permissions; } catch (e) {}
    if (permissions && typeof permissions.query === 'function') {
      var nativeQuery = permissions.query.bind(permissions);
      var virtualQuery = function (descriptor) {
        var name = '';
        try { name = String(descriptor && descriptor.name); } catch (e) {}
        if (virtualDeviceForPermission(name)) { return Promise.resolve(makePermissionStatus(name)); }
        return nativeQuery(descriptor);
      };
      try { permissions.query = virtualQuery; } catch (e) {}
      try {
        if (typeof Permissions !== 'undefined' && typeof Permissions.prototype.query === 'function') {
          Permissions.prototype.query = virtualQuery;
        }
      } catch (e) {}
    }
  }

  /// A camera request in virtual-device mode. Only the microphone ever
  /// reaches WebKit, and only when the page asked for one; the two halves
  /// come back as one stream, the camera the proxy's.
  function virtualGetUserMedia(constraints, wantsAudio) {
    var pending = wantsAudio
      ? nativeGetUserMedia({ audio: constraints.audio })
      : Promise.resolve(null);
    return pending.then(function (audioStream) {
      var audio = [];
      try { if (audioStream) { audio = audioStream.getAudioTracks(); } } catch (e) {}
      return startSession(audioStream, null, audio, constraints);
    });
  }


  media.getUserMedia = function (constraints) {
    var wantsVideo = false;
    try { wantsVideo = !!(constraints && constraints.video); } catch (e) {}
    var wantsAudio = false;
    try { wantsAudio = !!(constraints && constraints.audio); } catch (e) {}
    // The virtual device: WebKit is never asked for a camera. Whatever camera
    // the page named, it gets this one; only a microphone goes to WebKit.
    if (VIRTUAL_VIDEO && wantsVideo) { return virtualGetUserMedia(constraints, wantsAudio); }
    // Video-only, exactly as the WebRTC watchdog guards itself: the microphone is
    // never in this feature's blast radius, and a combined stream cannot be
    // proxied without taking the audio apart. Asking the sensor for more pixels
    // is equally out of scope for a request we are not going to proxy.
    //
    // Except with the avatar: a combined stream returned whole would carry the
    // real camera, so it *is* taken apart — the video proxied, the microphone
    // handed through on the proxy stream untouched.
    var eligible = wantsVideo && (AVATAR || !wantsAudio);
    // With the native source the page's own ask is left alone: this grant is
    // for WebKit's permission prompt and the track's identity, and the track is
    // stopped a moment later — configuring the sensor for 1080 first would only
    // delay releasing it.
    var asked = eligible && !NATIVE_CAPTURE ? upgradeConstraints(constraints) : constraints;

    return nativeGetUserMedia(asked).then(function (stream) {
      var video = [], audio = [];
      try {
        video = stream.getVideoTracks();
        audio = stream.getAudioTracks();
      } catch (e) {}
      if (!eligible || !video.length || (audio.length && !AVATAR)) { return stream; }
      return startSession(stream, video[0], audio, constraints);
    });
  };

  /// Builds the proxy for a granted camera (`realVideo`, WebKit's track) or,
  /// with `realVideo` null, for the virtual device. `stream` is what WebKit
  /// granted — the camera's stream, or the virtual device's audio half (or
  /// nothing) — and `audio` the microphone tracks to hand back with it.
  function startSession(stream, realVideo, audio, constraints) {
      // One session per frame. A second video grant means the page restarted its
      // camera (Meet's camera toggle is stop-then-fresh-gUM), so the old one goes.
      teardown();

      var s = {
        realStream: null, realTrack: null, realTrackReleased: false,
        realSettings: null, realCapabilities: null, realLabel: '',
        constraints: constraints,
        source: NATIVE_CAPTURE ? 'native' : 'element',
        nativeDecoder: null, nativeNeedKey: true, nativeStarted: false,
        nativeSourceCanvas: null, nativeSourceCtx: null,
        nativePending: null, nativeStats: null,
        sourceVideo: null, canvas: null, ctx: null,
        proxyStream: null, proxyTrack: null,
        geometry: null, outW: 0, outH: 0,
        enabled: true, painted: false,
        settle: null, paintTimer: null,
        offline: false, offlineTimer: null,
        virtual: null, virtualConstraints: null
      };
      if (realVideo) { adoptRealStream(s, stream, realVideo); }
      else { adoptVirtualIdentity(s, VIRTUAL_VIDEO, constraints); }

      // Attached but off-viewport. WebKit suspends media in an element that is
      // not in the document, and will not capture a canvas that is not either —
      // the constraint the screen-share shim already works under.
      var hidden = 'position:fixed;left:-99999px;top:0;pointer-events:none';

      var el = document.createElement('video');
      el.muted = true;
      el.defaultMuted = true;
      el.playsInline = true;
      el.setAttribute('muted', '');
      el.setAttribute('playsinline', '');
      el.style.cssText = hidden + ';width:2px;height:2px';
      (document.body || document.documentElement).appendChild(el);
      // The element is the source only on the WebKit path; on the native path
      // it stays empty unless a fallback binds a fresh camera to it later.
      if (s.source === 'element' && !AVATAR) { el.srcObject = stream; }
      s.sourceVideo = el;

      s.canvas = document.createElement('canvas');
      s.canvas.style.cssText = hidden;
      (document.body || document.documentElement).appendChild(s.canvas);
      s.ctx = s.canvas.getContext('2d', { alpha: false, desynchronized: true });

      session = s;

      var ready = (s.source === 'element')
        ? el.play().catch(function () {}).then(function () { return computeGeometry(el.videoWidth, el.videoHeight); })
        : Promise.resolve(null);

      return ready.then(function (measured) {
        // Provisional geometry; the frame loop corrects it on the first frame.
        // Native: the sensor's own 1920×1080. WebKit: `videoWidth` can still be
        // 0 here — for a MediaStream element `play()` may resolve before
        // metadata — so it is sized from the *portrait* default rather than a
        // landscape guess, because guessing landscape is how the published
        // track ends up the wrong way round for a frame or two.
        var geometry = measured ||
          (s.source === 'native'
            ? computeGeometry(NATIVE_WIDTH, NATIVE_HEIGHT)
            : { sx: 0, sy: 0, sw: WANT_SHORT, sh: WANT_SHORT,
                outW: Math.min(WANT_SHORT, MAX_SHORT), outH: Math.min(WANT_SHORT, MAX_SHORT) });
        s.geometry = geometry;
        s.outW = geometry.outW;
        s.outH = geometry.outH;
        s.canvas.width = geometry.outW;
        s.canvas.height = geometry.outH;

        // No frame rate: a frame goes out each time the canvas changes, so
        // every paint is sent once. `captureStream(30)` samples on WebKit's
        // own 30 Hz timer instead, which beats against a 30 fps source: a
        // paint just after a tick waited for the next one or was lost, and
        // the far end got ~26 fps with a hitch every sixth frame (measured on
        // the avatar camera, 2026-10-17). Every source here paints once per
        // frame it has, so nothing needs the cap.
        s.proxyStream = s.canvas.captureStream();
        s.proxyTrack = s.proxyStream.getVideoTracks()[0];
        if (!s.proxyTrack) {
          post({ kind: 'error', scope: 'setup', message: 'captureStream produced no track' });
          teardown();
          if (AVATAR) {
            // Fail closed: with no proxy to give, the real stream is still not
            // the answer. Nothing of it reaches the page, so all of it stops
            // (for the virtual device, the microphone half it asked for).
            try { stream.getTracks().forEach(function (t) { t.stop(); }); } catch (e) {}
            throw new DOMException('The camera could not be started', 'NotReadableError');
          }
          return stream;
        }
        patchTrack(s);
        // Only ever non-empty with the avatar or the virtual device (see
        // `eligible`): the page's own microphone, on the stream it gets back.
        for (var a = 0; a < audio.length; a++) {
          try { s.proxyStream.addTrack(audio[a]); } catch (e) {}
        }

        // Hand the stream over only once the canvas has really painted (see
        // `onFirstPaint` / `armPaintTimer`); `settle` is the one-shot that does
        // it, and stays callable through a native-to-WebKit fallback.
        return new Promise(function (resolve, reject) {
          s.settle = function (result, error) {
            s.settle = null;
            if (result) { resolve(result); } else { reject(error); }
          };
          armPaintTimer(s);
          if (s.source === 'native') {
            // The camera is device-exclusive and WebKit captures from another
            // process: release the page's track *before* Raven's own session
            // asks for the device, or that session is interrupted on arrival.
            stopRealTracks(s);
            s.nativeStarted = true;
            post({ kind: 'nativeStart' });
          } else {
            startElementLoop(s);
          }
        });
      });
  }

  // ---- the avatar: no side doors to the real camera ---------------------
  //
  // WebKit's legacy `navigator.getUserMedia` calls the internal method, not
  // the `getUserMedia` property this script replaced, and the prototype's
  // original is one `.call` away. With the avatar both are pointed at the
  // proxy. Assigned after every capture of the original above, so the chain
  // underneath still bottoms out in WebKit's own call; with the Persona both
  // are left alone ("off means not injected" applies to what it can). The
  // virtual device is fail-closed too, so its side doors are closed the same
  // way, `enumerateDevices` included (above).
  if (AVATAR) {
    var viaProxy = function (constraints) { return media.getUserMedia(constraints); };
    var legacyViaProxy = function (constraints, onSuccess, onError) {
      media.getUserMedia(constraints).then(onSuccess, onError);
    };
    try {
      if (typeof MediaDevices !== 'undefined' &&
          typeof MediaDevices.prototype.getUserMedia === 'function') {
        MediaDevices.prototype.getUserMedia = viaProxy;
      }
    } catch (e) {}
    var legacyNames = ['getUserMedia', 'webkitGetUserMedia'];
    for (var ln = 0; ln < legacyNames.length; ln++) {
      try {
        if (typeof Navigator !== 'undefined' &&
            typeof Navigator.prototype[legacyNames[ln]] === 'function') {
          Navigator.prototype[legacyNames[ln]] = legacyViaProxy;
        }
      } catch (e) {}
      try {
        if (Object.prototype.hasOwnProperty.call(navigator, legacyNames[ln])) {
          navigator[legacyNames[ln]] = legacyViaProxy;
        }
      } catch (e) {}
    }
  }

  // ---- commands from Swift ----------------------------------------------

  window.__ravenReplay = {
    // ---- the native source, fed from Swift ----
    nativeConfig: function (codec, avcCB64) {
      var s = session;
      if (!s || s.source !== 'native') { return; }
      try {
        configureNativeDecoder(s, codec, avcCB64);
      } catch (e) {
        fallBackToElement(s, 'native decoder configure: ' + String((e && e.name) || e));
      }
    },

    // Called through `callAsyncJavaScript` with the payload as an argument —
    // never with the base64 embedded in the script source. `capturedAt` and
    // `sentAt` are wall-clock epoch ms from Swift; `capturedAt` is -1 when the
    // feed could not place the capture instant, and for every replayed chunk.
    nativeChunk: function (b64, timestamp, key, capturedAt, sentAt) {
      var s = session;
      if (!s || s.source !== 'native') { return; }
      nativeChunk(s, b64, timestamp, key, capturedAt, sentAt);
    },

    /// Swift's session ended underneath the page — access refused, another
    /// tab holds the camera, the capture session failed. The page keeps its
    /// track; the pixels come from WebKit's camera from here on. Never with
    /// the avatar: Swift does not send it then, and `fallBackToElement`
    /// refuses it if anything else does.
    nativeEnd: function (reason) {
      var s = session;
      if (!s || s.source !== 'native') { return; }
      fallBackToElement(s, 'native camera ended: ' + reason);
    },

    /// Avatar only: the publisher went away and Swift is reconnecting. The
    /// track the page holds is untouched; it shows the offline card until
    /// the avatar's frames return.
    nativeOffline: function () {
      var s = session;
      if (!s || s.source !== 'native' || !AVATAR) { return; }
      goOffline(s, 'avatar camera offline');
    }
  };

  window.addEventListener('pagehide', function () {
    if (session) { stopRealTracks(session); }
    teardown();
  });
})();
"""#
}
#endif
