/*
 RAVEBrowser — restarting a WebRTC video that never started.

 On the visionOS 27 developer beta, joining a Google Meet call leaves the video
 tiles black. The tracks arrive and are `live`, the page believes it is showing
 video, and nothing errors — but no frame is ever painted. The workaround users
 found is to open Meet's own quality menu, pick Audio only, and switch back to
 Auto, which makes the element re-attach to its stream. That is a lot to ask of
 someone every time they join a call, and it is undiscoverable.

 So this does the same thing without the menu: when a `<video>` fed by a
 `MediaStream` still has no picture after a grace period, re-assign `srcObject`
 to the same stream. That is the part of the manual dance that actually matters
 — the quality menu is just a roundabout way of reaching it.

 **Why this is not in `PageDiagnosticsScript`.** That file reports and never
 acts, deliberately, and mixing a workaround into it would make every future
 reader wonder which of its observations have side effects. This one changes the
 page. Its reports go to whichever handler the app names (`reportHandler`):
 Raven's `PageDiagnostics`, a pure formatter with no state to confuse, or
 `RAVEPageReports` for an app with nothing like it.

 **The guards are the whole design, and the first version got them wrong.** It
 checked only that `videoWidth` was zero, which fired twice on Meet against an
 element the page had deliberately left *paused* — a hidden source or a
 pre-allocated tile — forced it to play, and re-bound its stream three times.
 Meet answered with "there was a problem with an effect, so video is off" and
 stopped publishing camera entirely. A paused element is not a stalled one; it
 is an element doing what it was told.

 So an element has to look like a tile a person is waiting on before it is
 touched at all: playing, laid out, connected, fed by a live and unmuted track
 that is not the local camera. Every one of those excludes a class of element
 that a page keeps around on purpose, and the page always has a better reason
 for its own state than this script does.

 It also no longer cycles `track.enabled`. That was the most invasive step and
 the least justified — on a local track it is indistinguishable from the user
 switching their camera off.

 **One paused case is acted on after all, and it took a live Web Inspector to
 earn it.** The join-page stall was finally caught in Safari on the same OS
 build, over remote inspection: one video element, paused, readyState NOTHING,
 never laid out, holding a live camera track. The track had been `muted` — a
 capture source delivering no frames, another face of the same OS bug — and by
 the time it recovered, Meet had given up: it never calls play() on that
 element again. Frames were confirmed flowing (a scratch sink painted 720×1280
 with real luma), and a single console play() on Meet's own element resolved
 with ENOUGH_DATA and made the self-view tile appear. So "the page never asked
 this element to play" is distinguishable from "the page paused it on purpose"
 — the play() wrapper below records *calls*, not just resolutions — and an
 element the page attached a stream to but never started is finished, not
 overridden, by playing it. The camera breakage that made this file paranoid
 came from the `track.enabled` cycling and triple re-binds, not from play().

 Keyed on the *symptom*, not on `meet.google.com`: "a live track with no frames"
 is a state no correct page reaches, and the same OS bug will strand any other
 WebRTC site the same way. A hostname check would fix Meet and quietly leave
 Jitsi, Discord, and Whereby broken.

 **The poll is the backstop, not the mechanism, and for a while it was both.**
 Reported from a real call: tiles do not flicker, but there is a visible delay
 whenever Meet re-initializes one — which it does constantly, moving people
 between cards as they speak. That delay was ours by construction. Meet
 recycles elements, so a shuffle assigns an existing `<video>` a *different*
 participant's stream; the state here is keyed on stream identity, so the
 element started a fresh `GRACE_MS` and waited six seconds before anything
 looked at it. Every one of the fifteen events in that call's log read `6s`,
 which is not a coincidence — it is the constant.

 Two changes, and neither loosens a guard:

 - **The play() marks name the stream they were earned on.** They lived on the
   element, so a recycled tile inherited the previous participant's history and
   came back classified `suspended` — the long fuse — when for *this* stream
   the page had done nothing at all and `unstarted` is the honest verdict. See
   `streamId`.
 - **The attach itself is the trigger.** The `srcObject` setter is wrapped, and
   a quarter of a second later an element the page has attached a live stream
   to and not started gets the same bare `play()` the poll would have given it
   seconds afterwards. It only ever *opens*: retries, the give-up budget and
   every other verdict stay with the tick.

 **There is no WebKit switch for the cause — measured, so nobody spends a
 build on it.** `WKWebViewConfiguration._setInvisibleAutoplayNotPermitted:`
 reads like the rule that suspends media in a zero-sized element, and it is
 not. On visionOS it already defaults to **false**, both on a fresh
 configuration and on the copy a built `WKWebView` carries, so setting it is a
 no-op. Nor does forcing it *true* suspend anything: a playing,
 `srcObject`-backed `<video>` shrunk to 0×0 kept playing for four seconds in
 both positions (canvas `captureStream`, so no camera is needed to re-run it).
 The flag governs whether autoplay may *start* while invisible, not whether
 ongoing playback is stopped. The preferences-side
 `_setInvisibleMediaAutoplayNotPermitted:` exists on macOS and **does not
 exist on visionOS at all** — `WKPreferences` has no autoplay selector here.

 So the workaround stays a workaround, and the `rtcSuspended` / `rtcStalled`
 lines remain the only evidence the OS bug is present. When a future OS stops
 producing them, delete the script.

 Raven's `WebRTCRecoveryScript`, lifted 2026-10-17 with the call layer. Its
 Safari port is Raven's `extras/webrtc-unstick.user.js`; keep the two in sync
 when the verdict logic changes. The `__raven…` marks keep their names:
 Raven's `CallAudioScript` chains through the same `srcObject` descriptor and
 reads them.
 */

#if canImport(WebKit)
import Foundation
import WebKit

public enum RAVEWebRTCRecoveryScript {
    /// - Parameters:
    ///   - probeCamera: whether a granted video-only camera stream is probed
    ///     (played into a hidden element until it paints) before the page gets
    ///     it. Off whenever a camera proxy's source is not the wearer's camera
    ///     (the avatar, a virtual device): the proxy stops that track unseen a
    ///     moment later, or never asks for one, so probing would only keep the
    ///     real camera running, in an element in the page's own DOM, for no
    ///     reader. The probe only ever reported (`RETRY_DUD_CAMERA` is off), so
    ///     nothing else is lost.
    ///   - reportHandler: where its lines go — see the header.
    @MainActor
    public static func feature(probeCamera: Bool = true,
                               reportHandler: String = RAVEPageReports.messageHandler) -> RAVEUserScriptFeature {
        RAVEUserScriptFeature(userScript(probeCamera: probeCamera, reportHandler: reportHandler))
    }

    @MainActor
    public static func userScript(probeCamera: Bool = true,
                                  reportHandler: String = RAVEPageReports.messageHandler) -> WKUserScript {
        // A Bool and an escaped string, so safe to interpolate.
        WKUserScript(
            source: "window.__ravenRTCRecoveryConfig={probeCamera:\(probeCamera),reportHandler:"
                + RAVEJavaScript.string(reportHandler) + "};\n" + source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    private static let source = #"""
(function () {
  'use strict';
  if (window.__ravenRTCRecovery) { return; }
  window.__ravenRTCRecovery = true;

  // Where reports go: Swift picks the handler (`userScript(reportHandler:)`).
  var REPORT_HANDLER = (window.__ravenRTCRecoveryConfig &&
                        window.__ravenRTCRecoveryConfig.reportHandler) || 'ravePageReports';

  // One-line kill switch. Set false to make this observe and report without
  // ever touching the page — the log still says whether the OS bug is present,
  // which is the question that decides whether the script is needed at all.
  var ENABLED = true;

  // Long enough that a merely slow connection is never touched: a call that is
  // going to show a picture normally shows one within a second or two of the
  // track going live.
  var GRACE_MS = 6000;
  // The 'unstarted' verdict gets a shorter fuse than the re-bind does, because
  // its action is a bare play(): harmless to an element the page was about to
  // start anyway, invisible on one it never lays out. Two consecutive ticks in
  // the state — a page that means to play a freshly attached stream does it
  // within milliseconds, not seconds. Timed from entering the state, not from
  // first sight, so a track that goes live late still gets its full window.
  var START_GRACE_MS = 2000;
  // The attach path's own fuse, and the reason it exists: a tile Meet has just
  // handed a different participant's stream is judged the moment that
  // assignment lands, not on the next tick. Long enough that the page's own
  // play() — which follows a normal attach within a task or two — always gets
  // there first, short enough that a shuffled card is not visibly dead.
  var ATTACH_GRACE_MS = 250;
  var RETRY_MS = 4000;
  var MAX_ATTEMPTS = 2;
  var TICK_MS = 2000;
  // A page that has gone this long without a single MediaStream-backed video is
  // not a call, so stop polling it. The observer below restarts the timer if one
  // ever appears.
  var IDLE_STOP_MS = 300000;
  var URL_CAP = 300;
  var MAX_ELEMENTS = 32;

  // How long an element may sit ineligible before it is worth a line. A page
  // that keeps a paused tile around is normal; one whose only tile stays paused
  // is the explanation for an empty call.
  var IDLE_REPORT_MS = 12000;
  // Meet lays out a tile per participant, and one line each would bury the
  // three that matter.
  var REPORT_CAP = 8;

  var timer = null;
  var idleSince = Date.now();
  var sawStream = false;
  var reports = 0;

  function post(kind, fields) {
    try {
      fields.kind = kind;
      fields.where = String(location.href || '').slice(0, URL_CAP);
      fields.top = (window === window.top);
      fields.ready = document.readyState;
      window.webkit.messageHandlers[REPORT_HANDLER].postMessage(fields);
    } catch (e) {}
  }

  function videoTracks(stream) {
    try { return stream.getVideoTracks ? stream.getVideoTracks() : []; }
    catch (e) { return []; }
  }

  // ---- which stream a mark belongs to -----------------------------------
  //
  // Meet recycles its `<video>` elements: as people talk and move it hands an
  // existing tile a *different* participant's stream rather than building a new
  // element. Everything this script knows about an element's history is stored
  // on the element, so without a stamp those marks outlive the stream that
  // earned them — and a recycled tile would be judged on what the page did for
  // somebody else's video. Concretely, a tile that had played would come back
  // classified `suspended` (the six-second re-bind fuse) when for *this* stream
  // the page has done nothing at all and `unstarted`'s short fuse is right.
  //
  // A number rather than the stream itself, deliberately: a mark holding a
  // MediaStream would keep an old participant's tracks reachable from an
  // element that has already moved on.
  var streamSeq = 0;
  function streamId(stream) {
    try {
      if (!stream.__ravenStreamId) { stream.__ravenStreamId = ++streamSeq; }
      return stream.__ravenStreamId;
    } catch (e) { return 0; }
  }

  // Did the page ask this element to play *this* stream, and did that play
  // resolve? The marks are written by the `play()` wrapper further down.
  function askedFor(el, id) { return !!id && el.__ravenAskedFor === id; }
  function playedFor(el, id) { return !!id && el.__ravenPlayedFor === id; }

  // `live`/`muted`/`enabled` separate the three ways a black tile happens: the
  // track ended, the sender is not sending, or the page turned it off. Only the
  // first of those is worth acting on, and only the log can tell them apart
  // afterwards.
  function describeTracks(tracks) {
    var out = [];
    for (var i = 0; i < tracks.length && i < 4; i++) {
      var t = tracks[i];
      out.push(t.readyState + (t.muted ? '/muted' : '') + (t.enabled ? '' : '/disabled'));
    }
    return out.join(' ') || 'none';
  }

  // A local device track is the page's own camera, and the camera feeds the
  // effects pipeline. `deviceId` in the settings is what marks one: a track
  // arriving over the wire has no device behind it.
  function isLocalDevice(track) {
    try {
      var settings = track.getSettings ? track.getSettings() : null;
      return !!(settings && settings.deviceId);
    } catch (e) { return false; }
  }

  // Reporting and touching are separate questions, and conflating them cost a
  // debugging round: the local-camera exclusion below is right for *acting* —
  // that stream feeds the effects pipeline — but it also made the self-view
  // invisible in the log at the exact moment the self-view was the symptom.
  // So classify, and let the caller decide what each verdict earns.
  //
  //   'ineligible' — the page is not trying to show this; leave it entirely
  //   'local'      — a tile that should be painting, fed by this device's
  //                  camera. Report it. Never touch it.
  //   'remote'     — the same, arriving over the wire. Safe to re-bind.
  // What the frames actually contain.
  //
  // An element reporting a non-zero `videoWidth` while the wearer sees nothing
  // has two very different explanations, and they were indistinguishable from
  // outside: the frames carry a picture that is not reaching the display, or
  // the frames are genuinely black because the platform handed this WebView a
  // running-but-empty camera rather than refusing it. Reading one downscaled
  // frame answers it outright — all-zero luma is an empty feed, any variation
  // at all is a real picture that is not being composited.
  //
  // `drawImage` is a read; it does not disturb the element. A camera stream is
  // origin-clean, so `getImageData` is allowed — but a SecurityError is caught
  // and reported rather than assumed away.
  function sampleLuma(el) {
    try {
      var size = 32;
      var canvas = document.createElement('canvas');
      canvas.width = size;
      canvas.height = size;
      var ctx = canvas.getContext('2d', { willReadFrequently: true });
      if (!ctx) { return 'no 2d context'; }
      ctx.drawImage(el, 0, 0, size, size);
      var data = ctx.getImageData(0, 0, size, size).data;
      var min = 255, max = 0, sum = 0, count = 0;
      for (var i = 0; i < data.length; i += 4) {
        var luma = (data[i] * 299 + data[i + 1] * 587 + data[i + 2] * 114) / 1000;
        if (luma < min) { min = luma; }
        if (luma > max) { max = luma; }
        sum += luma;
        count++;
      }
      if (!count) { return { text: 'empty', black: false }; }
      return {
        text: 'mean ' + Math.round(sum / count) +
              ' min ' + Math.round(min) + ' max ' + Math.round(max) +
              (max === min ? ' (flat)' : ''),
        // Every pixel zero. Not "dark" — a covered lens still varies by a few
        // counts of sensor noise, so a genuinely flat zero means no picture was
        // ever written into the frame.
        black: (max === 0)
      };
    } catch (e) {
      return { text: 'unreadable: ' + String((e && e.name) || e), black: false };
    }
  }

  // Which side a stream came from, asked independently of whether the element
  // is eligible for anything — the painting and idle reports need it too.
  function hasLiveTrack(tracks) {
    for (var i = 0; i < tracks.length; i++) {
      if (tracks[i].readyState === 'live' && !tracks[i].muted) { return true; }
    }
    return false;
  }

  // Live even if muted. A muted live track is a source that has not produced a
  // frame yet — the state the visionOS 27 capture bug leaves a fresh camera
  // track in — which is precisely the case 'unstarted' exists for.
  function anyLive(tracks) {
    for (var i = 0; i < tracks.length; i++) {
      if (tracks[i].readyState === 'live') { return true; }
    }
    return false;
  }

  function side(tracks) {
    for (var i = 0; i < tracks.length; i++) {
      if (tracks[i].readyState !== 'live') { continue; }
      return isLocalDevice(tracks[i]) ? 'local' : 'remote';
    }
    return 'none';
  }

  // Every MediaStream-backed element reports exactly one of painting / stalled
  // / idle, once. Silence used to mean three different things — healthy, never
  // eligible, or the script not running — and telling them apart cost a round
  // trip to the device each time.
  function reportOnce(state, kind, fields) {
    if (state.reported || reports >= REPORT_CAP) { return; }
    state.reported = true;
    reports++;
    post(kind, fields);
  }

  function classify(el, tracks, id) {
    if (el.paused) {
      // A paused element is three different animals, and the play() wrapper's
      // two marks tell them apart:
      //
      //   played and undone   → 'suspended'. Decoded data and a frame size say
      //                         the same thing but do not survive the WebKit
      //                         suspension that destroys them; a resolved
      //                         play() does. Resume it.
      //   asked and pending   → the page called play() and it has not resolved
      //                         — usually a track that is not producing yet.
      //                         Our play() would join the same queue and add
      //                         nothing. Leave it.
      //   never asked         → 'unstarted'. The page attached a live stream
      //                         and never called play(). Meet reaches this on
      //                         the visionOS 27 beta when the camera track was
      //                         `muted` at attach: it gives up and never
      //                         retries, even after the track recovers.
      //                         Playing it finishes the page's own gesture —
      //                         measured in Safari before it was trusted here.
      //
      // The live-track requirement is what keeps all of this off a camera the
      // user switched off on purpose: Meet stops the track for that, leaving
      // it `ended`, and an element holding an ended track must stay exactly
      // as the page left it. For 'unstarted' a muted live track is accepted —
      // play() on it simply stays pending until frames arrive, which is the
      // recovery arming itself.
      //
      // Both marks are read *for this stream* — see `streamId`. A recycled tile
      // carries the previous participant's history, and inheriting it is how a
      // shuffled card ends up on the long fuse instead of the short one.
      if (playedFor(el, id) || (el.readyState >= 2 && el.videoWidth > 0)) {
        return hasLiveTrack(tracks) ? 'suspended' : 'ineligible';
      }
      if (!askedFor(el, id) && el.isConnected && anyLive(tracks)) {
        return 'unstarted';
      }
      return 'ineligible';
    }
    // Never laid out: a processing element, not a picture.
    if (!el.isConnected) { return 'ineligible'; }
    try {
      if (el.getClientRects().length === 0) { return 'ineligible'; }
    } catch (e) { return 'ineligible'; }
    // A frame arrived, so whatever else is wrong is not this.
    if (el.videoWidth > 0) { return 'ineligible'; }

    var verdict = 'ineligible';
    for (var i = 0; i < tracks.length; i++) {
      var track = tracks[i];
      if (track.readyState !== 'live') { continue; }
      // Muted means nothing is being sent. There is nothing to re-attach to,
      // and re-binding would only interrupt the moment it starts.
      if (track.muted) { continue; }
      if (isLocalDevice(track)) { verdict = 'local'; continue; }
      return 'remote';
    }
    return verdict;
  }

  // Resuming is deliberately not `unstick`: no re-binding, no touching tracks,
  // nothing but the one call that undoes a suspension. The element keeps its
  // stream, so the page's pipeline sees a pause and a resume rather than a
  // stream it has to re-attach to.
  function resume(el) {
    try {
      el.__ravenForcing = true;
      var played = el.play();
      if (played && played.catch) { played.catch(function () {}); }
    } catch (e) {}
    try { el.__ravenForcing = false; } catch (e) {}
  }

  function unstick(el, stream) {
    try {
      el.srcObject = null;
      el.srcObject = stream;
    } catch (e) { return; }
    // Re-binding resets the element to paused, and it was playing a moment ago
    // — `recoverable` guarantees that — so this restores the state the page
    // chose rather than imposing one.
    try {
      el.__ravenForcing = true;
      var played = el.play();
      if (played && played.catch) { played.catch(function () {}); }
    } catch (e) {}
    try { el.__ravenForcing = false; } catch (e) {}
  }

  // ---- did the page ask this element to play, and did it work? ----------
  //
  // This lives here rather than with the diagnostics because it is no longer
  // only a diagnostic: a resolved `play()` is the soundest evidence that an
  // element found paused later was *running* and was stopped from underneath
  // the page. readyState looked like that evidence and is not — WebKit tears
  // the decoder down when it suspends, resetting `readyState` and `videoWidth`
  // to zero, so the proof is destroyed by the very event it was meant to prove.
  //
  // Pass-through, and only for MediaStream-backed elements: a browser logging
  // every `play()` on a video site would drown its own log.
  try {
    var mediaProto = window.HTMLMediaElement && HTMLMediaElement.prototype;
    if (mediaProto && typeof mediaProto.play === 'function') {
      var nativePlay = mediaProto.play;
      mediaProto.play = function () {
        var el = this;
        var streamBacked = false;
        var id = 0;
        try {
          streamBacked = !!(el.srcObject && typeof el.srcObject.getVideoTracks === 'function');
          if (streamBacked) { id = streamId(el.srcObject); }
        } catch (e) {}

        // Calls and resolutions are separate marks because they answer
        // separate questions: "did the page ever ask" is what separates a
        // deliberate pause from a tile Meet forgot to start. Our own forced
        // plays are flagged so they do not masquerade as page intent —
        // otherwise one attempt would erase the very evidence that made the
        // element eligible.
        //
        // Each mark names the stream it was for, read at the moment of the
        // call. The element may be handed a different stream before the
        // promise settles, and a resolution then belongs to the stream that
        // was actually playing, not to whatever arrived since.
        if (streamBacked && !el.__ravenForcing) {
          try { el.__ravenAskedFor = id; } catch (e) {}
        }

        var result;
        try {
          result = nativePlay.apply(el, arguments);
        } catch (error) {
          if (streamBacked) { post('play', { phase: 'threw', text: String((error && error.name) || error) }); }
          throw error;
        }

        if (streamBacked && result && typeof result.then === 'function') {
          result.then(function () {
            // The mark `classify` reads. Set on the element itself so it
            // survives everything except the element being discarded — and
            // stamped, so it does not survive into the next stream's life.
            try { el.__ravenPlayedFor = id; } catch (e) {}
            post('play', {
              phase: 'resolved',
              width: el.videoWidth,
              readyState: el.readyState,
              box: el.clientWidth + 'x' + el.clientHeight
            });
          }, function (error) {
            post('play', { phase: 'rejected', text: String((error && error.name) || error) });
          });
        }
        return result;
      };
    }
  } catch (e) {}

  // ---- is the granted camera track actually producing frames? -----------
  //
  // Meet can sit on a `live` camera track with the tile unlaid-out and never
  // played, which looks identical from outside to a track that produces
  // nothing: in both cases no element ever paints. Toggling the camera off and
  // on fixes it, and that is consistent with either story — a fresh track, or
  // Meet's own state machine restarted.
  //
  // So ask the track directly, in a sink of our own: bind it to an inert
  // element, play it muted, and see whether a frame lands. This reads the
  // stream and touches nothing the page owns. Adding a sink to a MediaStream is
  // ordinary — it is what every extra tile of the same speaker already is.
  var PROBE_MS = 1500;
  // Retrying — stop the dud tracks, request again, hand the page the second
  // stream — is the fix *if* the probe shows the first track is dead. Left off
  // until it does: stopping a camera track mid-join is exactly the class of
  // change that turned the camera off earlier in this file's history, and it is
  // worth nothing if the track was fine and Meet was the stuck part.
  var RETRY_DUD_CAMERA = false;

  // Resuming an element WebKit suspended out from under a page that had already
  // started it. On by measurement, not by hope: play() was observed resolving
  // on this element with ENOUGH_DATA and a 720px frame, and the element was
  // paused again twelve seconds later with the track still live and producing.
  var RESUME_SUSPENDED = true;

  // Starting an element the page attached a live stream to and never asked to
  // play. Also on by measurement: reproduced in Safari on the same OS build
  // over remote Web Inspector, where the join-page stall was one such element
  // (paused, readyState NOTHING, live camera track that had been muted at
  // attach). Frames were confirmed flowing into a scratch sink, and a single
  // external play() resolved with ENOUGH_DATA and made Meet lay out the
  // self-view tile. The same never-started state is what freshly added remote
  // streams — screen shares — land in when they stall mid-call.
  var START_UNSTARTED = true;

  function probeStream(stream) {
    return new Promise(function (resolve) {
      var el = document.createElement('video');
      el.muted = true;
      el.playsInline = true;
      el.setAttribute('playsinline', '');
      el.setAttribute('aria-hidden', 'true');
      el.style.cssText = 'position:fixed;left:-9999px;top:0;width:1px;height:1px;' +
                         'opacity:0;pointer-events:none';

      var finished = false;
      var poll = null;
      var deadline = null;

      function finish(painted) {
        if (finished) { return; }
        finished = true;
        if (poll) { clearInterval(poll); }
        if (deadline) { clearTimeout(deadline); }
        var luma = painted ? sampleLuma(el) : null;
        try { el.pause(); } catch (e) {}
        try { el.srcObject = null; } catch (e) {}
        try { if (el.parentNode) { el.parentNode.removeChild(el); } } catch (e) {}
        resolve({ painted: painted, luma: luma });
      }

      try {
        el.srcObject = stream;
        (document.body || document.documentElement).appendChild(el);
        var played = el.play();
        if (played && played.catch) { played.catch(function () {}); }
      } catch (e) { finish(false); return; }

      // First presented frame ends the probe — the sooner it ends, the sooner
      // the extra sink gets off a camera that is busy starting up. The poll
      // stays as the fallback for a WebKit without rVFC.
      try {
        if (typeof el.requestVideoFrameCallback === 'function') {
          el.requestVideoFrameCallback(function () { finish(true); });
        }
      } catch (e) {}
      poll = setInterval(function () {
        if (el.videoWidth > 0 && el.readyState >= 2) { finish(true); }
      }, 100);
      deadline = setTimeout(function () { finish(false); }, PROBE_MS);
    });
  }

  // See `userScript(probeCamera:)`: off, the camera path is not wrapped at all.
  var PROBE_CAMERA = !(window.__ravenRTCRecoveryConfig &&
                       window.__ravenRTCRecoveryConfig.probeCamera === false);

  try {
    var media = navigator.mediaDevices;
    if (PROBE_CAMERA && media && typeof media.getUserMedia === 'function' && typeof Promise === 'function') {
      var nativeGetUserMedia = media.getUserMedia.bind(media);
      media.getUserMedia = function (constraints) {
        return nativeGetUserMedia(constraints).then(function (stream) {
          var video = [], audio = [];
          try {
            video = stream.getVideoTracks();
            audio = stream.getAudioTracks();
          } catch (e) { return stream; }
          // Video-only, which is the shape a camera toggle takes. Leaving
          // combined audio+video requests alone keeps every microphone out of
          // the blast radius of a camera workaround.
          if (!video.length || audio.length) { return stream; }

          return probeStream(stream).then(function (result) {
            if (result.painted) {
              post('captureProbe', {
                phase: 'producing',
                luma: result.luma ? result.luma.text : '?'
              });
              return stream;
            }
            post('captureProbe', {
              phase: 'silent',
              ms: PROBE_MS,
              action: RETRY_DUD_CAMERA ? 'restarting' : 'observing only'
            });
            if (!RETRY_DUD_CAMERA) { return stream; }
            // The source has to be released before asking again: WebKit shares
            // one capture source per device, so a second request over a live
            // one would hand back the same silence.
            try {
              for (var i = 0; i < video.length; i++) { video[i].stop(); }
            } catch (e) {}
            return nativeGetUserMedia(constraints).then(function (second) {
              return probeStream(second).then(function (retried) {
                post('captureProbe', {
                  phase: retried.painted ? 'restarted' : 'still silent',
                  luma: retried.luma ? retried.luma.text : '?'
                });
                return second;
              });
            }, function () { return stream; });
          }, function () { return stream; });
        });
      };
    }
  } catch (e) {}

  // A renegotiation, or Meet moving a participant to a different card, hands
  // the element a different stream — and that is a fresh chance to be stuck. So
  // identity, not existence, decides whether the old verdict still applies.
  function stateFor(el, stream, now) {
    var state = el.__ravenRTC;
    if (!state || state.stream !== stream) {
      state = el.__ravenRTC = {
        stream: stream, id: streamId(stream), attempts: 0, since: now,
        nextAt: now + GRACE_MS, unstartedSince: 0, settled: false
      };
    }
    return state;
  }

  // Reporting and acting, shared by the tick and the attach hook so that a
  // resume reached either way is logged identically and counts against the same
  // attempt budget. `via` is the only difference, and it is worth a field: it
  // says whether the element was caught at the moment of attach or by the
  // backstop poll, which is how the two paths get told apart in a log.
  function act(el, stream, state, tracks, verdict, now, via) {
    var suspended = (verdict === 'suspended');
    var unstarted = (verdict === 'unstarted');
    var acting = ENABLED && (suspended ? RESUME_SUSPENDED
                                       : unstarted ? START_UNSTARTED
                                                   : verdict === 'remote');

    state.attempts++;
    if (state.attempts === 1) {
      post(suspended ? 'rtcSuspended' : unstarted ? 'rtcUnstarted' : 'rtcStalled', {
        seconds: Math.round((now - state.since) / 1000),
        via: via,
        tracks: describeTracks(tracks),
        readyState: el.readyState,
        source: (suspended || unstarted) ? side(tracks) : verdict,
        size: el.clientWidth + 'x' + el.clientHeight,
        action: acting ? (suspended ? 'resuming' : unstarted ? 'starting' : 're-binding')
                       : 'observing only'
      });
    }
    // A local tile, or the kill switch: say so once and stop. The log still
    // answers whether the OS bug is present, which is the only reason to keep
    // the script at all — and for the self-view that answer is the finding.
    if (!acting) { state.settled = true; return; }
    if (suspended || unstarted) { resume(el); } else { unstick(el, stream); }
    state.nextAt = now + RETRY_MS;
  }

  // ---- the attach hook --------------------------------------------------
  //
  // The tick below is a two-second poll behind a six-second grace, which is the
  // right shape for a backstop and the wrong one for the common case. Meet
  // shuffles its cards constantly — a participant who speaks or moves is given
  // a different tile — and each shuffle is a *new* stream assigned to a reused
  // element. If the page then fails to start it, the poll is the floor on how
  // long that tile stays dead, and the whole delay is ours.
  //
  // So watch the assignment itself. This is the same seam `CallAudioScript`
  // uses, and it chains the same way: each patch captures the descriptor
  // installed before it, so both run whichever order they are injected in.
  //
  // `loadedmetadata` was the other candidate and does not work here: for a
  // stream-backed element it fires when the first frame arrives, and the
  // element this exists for is one that never gets that far.
  try {
    var srcObjectDesc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'srcObject');
    if (srcObjectDesc && srcObjectDesc.set && srcObjectDesc.get) {
      Object.defineProperty(HTMLMediaElement.prototype, 'srcObject', {
        configurable: true, enumerable: srcObjectDesc.enumerable,
        get: function () { return srcObjectDesc.get.call(this); },
        set: function (stream) {
          srcObjectDesc.set.call(this, stream);
          var el = this;
          try {
            if (!stream || typeof stream.getVideoTracks !== 'function') { return; }
            sawStream = true;
            start();
            setTimeout(function () { attached(el, stream); }, ATTACH_GRACE_MS);
          } catch (e) {}
        }
      });
    }
  } catch (e) {}

  // One shot, a quarter of a second after an attach. Everything it will not
  // handle — an element not laid out yet, a track that goes live later, a
  // second attempt — is left to the tick, which is why this can afford to be
  // strict: it only ever acts on the one verdict whose action is a bare play()
  // on a stream the page has demonstrably not started.
  function attached(el, stream) {
    try {
      if (el.srcObject !== stream) { return; }
      var now = Date.now();
      var state = stateFor(el, stream, now);
      // The tick owns retries and the give-up budget; this only ever opens.
      if (state.settled || state.attempts > 0) { return; }
      if (!el.paused) { return; }
      var tracks = videoTracks(stream);
      if (classify(el, tracks, state.id) !== 'unstarted') { return; }
      act(el, stream, state, tracks, 'unstarted', now, 'attach');
    } catch (e) {}
  }

  function tick() {
    var videos;
    try { videos = document.querySelectorAll('video'); } catch (e) { return; }
    var now = Date.now();

    for (var i = 0; i < videos.length && i < MAX_ELEMENTS; i++) {
      var el = videos[i];
      var stream = null;
      try { stream = el.srcObject; } catch (e) {}
      if (!stream || typeof stream.getVideoTracks !== 'function') { continue; }

      sawStream = true;
      var state = stateFor(el, stream, now);
      if (state.settled) { continue; }

      var tracks = videoTracks(stream);

      // Playing *and* painting. Both halves matter: `videoWidth` survives a
      // pause — the element keeps its last frame's dimensions — so testing it
      // alone would classify a suspended element as healthy and skip the check
      // that catches this whole failure.
      //
      // And it no longer settles the element. Suspension happens *after* a
      // successful play, so an element written off as healthy is exactly the
      // one that goes on to fail.
      if (!el.paused && el.videoWidth > 0) {
        if (state.attempts > 0 && !state.recoveryReported) {
          state.recoveryReported = true;
          post('rtcRecovered', {
            attempts: state.attempts,
            width: el.videoWidth,
            height: el.videoHeight,
            seconds: Math.round((now - state.since) / 1000)
          });
        } else if (state.attempts === 0 && !state.reported && reports < REPORT_CAP) {
          // Frames are arriving. Said out loud because "black picture" and
          // "no frames" are different faults with different owners: an element
          // that paints and still shows nothing is a compositing problem, and
          // nothing in this script would ever fix it.
          //
          // The guards above mirror reportOnce's, and they are load-bearing:
          // sampleLuma is a canvas drawImage + getImageData — a GPU→CPU
          // readback on the main thread — and without them it ran on every
          // tick for every playing tile for the life of the call, because
          // reportOnce only suppressed the *message*. Measured as page-wide
          // lag whenever a camera was up. The luma exists for this one report
          // and must never be computed after the report is spent.
          var luma = sampleLuma(el);
          reportOnce(state, 'rtcPainting', {
            width: el.videoWidth,
            height: el.videoHeight,
            box: el.clientWidth + 'x' + el.clientHeight,
            source: side(tracks),
            luma: luma.text,
            blackFeed: luma.black && side(tracks) === 'local'
          });
        }
        // Keep the grace clock rolling forward so a suspension that happens
        // later is timed from when it happened, not from when the element
        // first appeared.
        state.nextAt = now + GRACE_MS;
        continue;
      }

      var verdict = classify(el, tracks, state.id);

      // See START_GRACE_MS: 'unstarted' is timed from when the element entered
      // the state, so an element whose track goes live a minute in is not acted
      // on the instant it becomes eligible.
      if (verdict === 'unstarted') {
        if (!state.unstartedSince) { state.unstartedSince = now; }
      } else {
        state.unstartedSince = 0;
      }

      if (verdict === 'ineligible') {
        // Not a tile anyone is waiting on — paused, unlaid-out, or muted. Hold
        // the retry clock instead of settling: this element may become a real
        // tile a minute from now, and it should get a full grace period then
        // rather than inheriting a stall it spent idle. `since` is deliberately
        // left alone; it is when the element was first seen, and the idle
        // report below is measured from it.
        if (now - state.since > IDLE_REPORT_MS) {
          reportOnce(state, 'rtcIdle', {
            seconds: Math.round((now - state.since) / 1000),
            tracks: describeTracks(tracks),
            paused: !!el.paused,
            connected: !!el.isConnected,
            // Both were missing when this line first mattered, and without them
            // "idle" and "suspended" could not be told apart after the fact.
            readyState: el.readyState,
            width: el.videoWidth,
            played: playedFor(el, state.id),
            asked: askedFor(el, state.id),
            box: el.clientWidth + 'x' + el.clientHeight,
            source: side(tracks)
          });
        }
        state.nextAt = now + GRACE_MS;
        continue;
      }

      // Only the *first* start attempt uses the short fuse — retries fall back
      // to the ordinary RETRY_MS pacing that `nextAt` carries, or an unstarted
      // element would be re-played every tick.
      var deadline = (verdict === 'unstarted' && state.attempts === 0)
        ? state.unstartedSince + START_GRACE_MS
        : state.nextAt;
      if (now < deadline) { continue; }

      if (state.attempts >= MAX_ATTEMPTS) {
        post('rtcGaveUp', {
          attempts: state.attempts,
          tracks: describeTracks(tracks),
          readyState: el.readyState,
          paused: !!el.paused
        });
        state.settled = true;
        continue;
      }

      act(el, stream, state, tracks, verdict, now, 'poll');
    }

    if (!sawStream && now - idleSince > IDLE_STOP_MS) { stop(); }
  }

  function start() {
    if (timer) { return; }
    idleSince = Date.now();
    timer = setInterval(tick, TICK_MS);
  }

  function stop() {
    if (timer) { clearInterval(timer); timer = null; }
  }

  // A call joined an hour into a session has to restart the poller the idle
  // timeout stopped. Watching for added elements is enough: a page cannot show
  // video without one.
  if (window.MutationObserver) {
    try {
      new MutationObserver(function (records) {
        for (var i = 0; i < records.length; i++) {
          var added = records[i].addedNodes;
          for (var j = 0; j < added.length; j++) {
            var node = added[j];
            if (node.nodeType !== 1) { continue; }
            if (node.tagName === 'VIDEO' || (node.querySelector && node.querySelector('video'))) {
              start();
              return;
            }
          }
        }
      }).observe(document.documentElement || document, { childList: true, subtree: true });
    } catch (e) {}
  }

  start();
})();
"""#
}
#endif
