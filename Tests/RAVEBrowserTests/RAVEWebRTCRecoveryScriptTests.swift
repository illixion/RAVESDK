#if canImport(WebKit)
import Foundation
import Testing
import WebKit
@testable import RAVEBrowser

/// No JS runtime in this test target, so what is pinnable is the generated
/// source's shape — the bargain `KeyboardSuppressionScriptTests` documents.
/// The invariants below are the ones whose loss would be silent: this script
/// touches other people's pages, and every guard it has was paid for by a
/// call that broke without one.
@Suite("WebRTC recovery script")
@MainActor
struct WebRTCRecoveryScriptTests {
    private var source: String { RAVEWebRTCRecoveryScript.userScript().source }

    /// Meet's tiles live in iframes, and the `play()` and `srcObject` wrappers
    /// have to be installed before any page script reaches them.
    @Test func injectsIntoEveryFrameAtDocumentStart() {
        let script = RAVEWebRTCRecoveryScript.userScript()
        #expect(script.isForMainFrameOnly == false)
        #expect(script.injectionTime == .atDocumentStart)
    }

    /// The kill switch, and the two verdicts that are allowed to act on a
    /// paused element. `RETRY_DUD_CAMERA` must stay off: the probe measured
    /// the camera track producing frames, so stopping it is a no-op dressed
    /// as a fix.
    @Test func theLeversAreWhereTheyWereLeft() {
        #expect(source.contains("var ENABLED = true;"))
        #expect(source.contains("var RESUME_SUSPENDED = true;"))
        #expect(source.contains("var START_UNSTARTED = true;"))
        #expect(source.contains("var RESUME_AUDIO = true;"))
        #expect(source.contains("var RETRY_DUD_CAMERA = false;"))
    }

    /// A mark that outlives the stream it was earned on is how a recycled tile
    /// inherits the previous participant's history — and comes back
    /// `suspended`, on the six-second fuse, when for *this* stream the page
    /// has done nothing. Both marks carry the id, and `classify` reads them
    /// through the two helpers rather than truthily.
    @Test func thePlayMarksNameTheStreamTheyWereEarnedOn() {
        #expect(source.contains("function askedFor(el, id) { return !!id && el.__ravenAskedFor === id; }"))
        #expect(source.contains("function playedFor(el, id) { return !!id && el.__ravenPlayedFor === id; }"))
        // The page asking to play also withdraws any pause it made itself.
        #expect(source.contains("try { el.__ravenAskedFor = id; el.__ravenPausedFor = 0; } catch (e) {}"))
        #expect(source.contains("try { el.__ravenPlayedFor = id; } catch (e) {}"))
        #expect(source.contains("if (playedFor(el, id) || (el.readyState >= 2 && el.videoWidth > 0)) {"))
        #expect(source.contains("if (!askedFor(el, id) && el.isConnected && anyLive(tracks)) {"))
        // Not the stream itself: a mark holding one would keep an old
        // participant's tracks reachable from an element that has moved on.
        #expect(source.contains("stream.__ravenStreamId = ++streamSeq"))
    }

    /// Our own forced plays must not masquerade as the page's intent, or one
    /// attempt erases the evidence that made the element eligible.
    @Test func forcedPlaysDoNotCountAsPageIntent() {
        #expect(source.contains("if (streamBacked && !el.__ravenForcing) {"))
        #expect(source.contains("el.__ravenForcing = true;"))
    }

    /// The attach hook chains through the descriptor installed before it —
    /// `CallAudioScript` patches the same property — and re-declares the
    /// property configurable so whatever is injected after it can do the same.
    @Test func theAttachHookChainsRatherThanReplacing() {
        #expect(source.contains(
            "var srcObjectDesc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'srcObject');"
        ))
        #expect(source.contains("srcObjectDesc.set.call(this, stream);"))
        #expect(source.contains("configurable: true, enumerable: srcObjectDesc.enumerable,"))
    }

    /// It only ever *opens*. Retries, the give-up budget and every other
    /// verdict stay with the poll — an attach hook that could also retry would
    /// be a second, untested copy of the state machine.
    @Test func theAttachHookOnlyEverMakesTheFirstAttempt() {
        #expect(source.contains("if (state.settled || state.attempts > 0) { return; }"))
        #expect(source.contains("if (classify(el, tracks, state.id) !== 'unstarted') { return; }"))
        #expect(source.contains("act(el, stream, state, tracks, 'unstarted', now, 'attach');"))
        // Long enough that the page's own play() always gets there first.
        #expect(source.contains("var ATTACH_GRACE_MS = 250;"))
    }

    /// Both paths report through `act`, so a resume reached either way is one
    /// log line with a `via` naming which caught it. Without that the two are
    /// indistinguishable after the fact, which is the whole reason the poll's
    /// `6s` was readable as the constant it is.
    @Test func bothPathsReportIdenticallyAndSayWhichFired() {
        #expect(source.contains("act(el, stream, state, tracks, verdict, now, 'poll');"))
        #expect(source.contains("via: via,"))
        #expect(source.contains(
            "post(suspended ? 'rtcSuspended' : unstarted ? 'rtcUnstarted' : 'rtcStalled', {"
        ))
    }

    /// The guards that cost Meet its camera the first time. A re-bind may only
    /// touch an element that looks like a tile someone is waiting on, and the
    /// local camera is reported and never acted on.
    @Test func reBindingStillRequiresARemoteLaidOutLiveTile() {
        #expect(source.contains("if (!el.isConnected) { return 'ineligible'; }"))
        #expect(source.contains("if (el.getClientRects().length === 0) { return 'ineligible'; }"))
        #expect(source.contains("if (el.videoWidth > 0) { return 'ineligible'; }"))
        #expect(source.contains("if (track.muted) { continue; }"))
        #expect(source.contains("if (isLocalDevice(track)) { verdict = 'local'; continue; }"))
        // `local` never reaches an action: `acting` is false for it, which
        // settles the element after one report.
        #expect(source.contains(": verdict === 'remote');"))
    }

    /// `track.enabled` cycling is what turned Meet's camera off, and the only
    /// thing done to a paused element is a bare `play()`.
    @Test func nothingEverTouchesATrack() {
        #expect(!source.contains(".enabled = false"))
        #expect(!source.contains(".enabled = true"))
    }

    /// With a fail-closed camera proxy the watchdog must not probe the real
    /// camera: it would keep it running in an element in the page's DOM for
    /// nothing.
    @Test func theCameraProbeCanBeSkipped() {
        #expect(RAVEWebRTCRecoveryScript.userScript(probeCamera: false).source
            .hasPrefix("window.__ravenRTCRecoveryConfig={probeCamera:false,"))
        #expect(RAVEWebRTCRecoveryScript.userScript().source
            .hasPrefix("window.__ravenRTCRecoveryConfig={probeCamera:true,"))
        #expect(RAVECameraProxy.Mode.avatar.allowsRealCameraProbe == false)
        #expect(RAVECameraProxy.Mode.virtualDevice(.init(label: "Avatar")).allowsRealCameraProbe == false)
        #expect(RAVECameraProxy.Mode.persona(nativeCapture: true).allowsRealCameraProbe)
    }

    /// Reports go wherever the app says — Raven's diagnostics, or
    /// `RAVEPageReports` — escaped, and the script reads that, not a fixed name.
    @Test func reportsGoToTheHandlerTheAppNames() {
        let raven = RAVEWebRTCRecoveryScript.userScript(reportHandler: "ravenDiagnostics").source
        #expect(raven.contains(#"reportHandler:"ravenDiagnostics"}"#))
        #expect(raven.contains("window.webkit.messageHandlers[REPORT_HANDLER].postMessage(fields);"))
        #expect(!raven.contains("messageHandlers.ravenDiagnostics"))
        #expect(RAVEWebRTCRecoveryScript.userScript().source
            .contains(#"reportHandler:"\#(RAVEPageReports.messageHandler)"}"#))
        let hostile = RAVEWebRTCRecoveryScript.userScript(reportHandler: "x\"};alert(1);//").source
        #expect(!hostile.contains(#"x"};alert"#))
    }
}
#endif
