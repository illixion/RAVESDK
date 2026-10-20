#if canImport(WebKit)
import Foundation
import JavaScriptCore
import Testing
@testable import RAVEBrowser

/// `RAVEWebRTCRecoveryScript` run for real in JavaScriptCore, for the two
/// behaviours a source-shape test cannot pin: remote audio that WebKit pauses
/// under a call, and a tile that is suspended again on every tracking loss.
/// "WebKit suspends" is `el.paused = true` written directly, which is what the
/// page sees: no `pause()` call, just a paused element.
@Suite("WebRTC recovery, run")
@MainActor
struct WebRTCRecoveryBehaviourTests {
    // MARK: - Remote audio

    /// The Meet call of 2026-10-20: three autoplaying `<audio>` elements,
    /// paused by the tracking loss, never resumed until a reload.
    @Test func aSuspendedRemoteAudioIsResumed() {
        let page = RecoveryPage()
        page.run("var a = makeAudio(liveStream('audio')); a.paused = false; tick();")
        page.run("a.paused = true; advance(2000); tick();")
        #expect(page.bool("!a.paused"))
        #expect(page.int("plays.length") == 1)
        #expect(page.posted("rtcAudioSuspended") == 1)
        page.run("advance(2000); tick();")
        #expect(page.posted("rtcAudioRecovered") == 1)
    }

    /// The page's reason always wins: a `pause()` it called itself is never
    /// undone, and the log says so once. A later `play()` from the page clears
    /// that, so a suspension after it is ours to resume again.
    @Test func thePagesOwnPauseIsLeftAlone() {
        let page = RecoveryPage()
        page.run("var a = makeAudio(liveStream('audio')); a.paused = false; tick();")
        page.run("a.pause(); advance(2000); tick(); advance(2000); tick();")
        #expect(page.bool("a.paused"))
        #expect(page.int("plays.length") == 0)
        #expect(page.posted("rtcAudioPausedByPage") == 1)
        #expect(page.posted("rtcAudioSuspended") == 0)

        page.run("a.play(); advance(2000); tick(); a.paused = true; advance(2000); tick();")
        #expect(page.bool("!a.paused"))
        #expect(page.posted("rtcAudioSuspended") == 1)
    }

    /// An element nobody has seen play is one the page is holding in reserve.
    @Test func anElementNeverSeenPlayingIsNotStarted() {
        let page = RecoveryPage()
        page.run("var a = makeAudio(liveStream('audio')); tick(); advance(10000); tick();")
        #expect(page.bool("a.paused"))
        #expect(page.int("plays.length") == 0)
    }

    /// A participant who left: the track ended, and the element stays as is.
    @Test func anEndedTrackIsLeftAlone() {
        let page = RecoveryPage()
        page.run("var s = liveStream('audio'); var a = makeAudio(s); a.paused = false; tick();")
        page.run("s.tracks[0].readyState = 'ended'; a.paused = true; advance(2000); tick();")
        #expect(page.int("plays.length") == 0)
    }

    /// A tracking loss can outlast any budget, and giving up would leave the
    /// call silent: retries back off but never stop, and report once.
    @Test func audioRetriesBackOffAndNeverGiveUp() {
        let page = RecoveryPage()
        page.run("var a = makeAudio(liveStream('audio')); a.paused = false; tick();")
        page.run("refusePlay = true; a.paused = true;")
        page.run("for (var i = 0; i < 40; i++) { advance(2000); tick(); }")
        let refused = page.int("plays.length")
        // 80 s at the backoff (4, 8, … capped at 30 s): a handful, not one per tick.
        #expect(refused >= 4 && refused < 20)
        page.run("refusePlay = false; advance(30000); tick();")
        #expect(page.bool("!a.paused"))
        #expect(page.posted("rtcAudioSuspended") == 1)
        page.run("advance(2000); tick();")
        #expect(page.posted("rtcAudioRecovered") == 1)
    }

    // MARK: - Repeated suspension of a tile

    /// Every tracking loss suspends the same long-lived stream again. Each one
    /// that follows a long enough healthy stretch gets its own budget.
    @Test func everyTrackingLossGetsItsOwnBudget() {
        let page = RecoveryPage()
        page.run("var v = makeVideo(liveStream('video')); v.play(); tick();")
        for _ in 0..<4 {
            page.run("v.paused = true; advance(8000); tick(); tick();")
            #expect(page.bool("!v.paused"))
            page.run("for (var i = 0; i < 20; i++) { advance(2000); tick(); }")
        }
        #expect(page.posted("rtcGaveUp") == 0)
        #expect(page.posted("rtcSuspended") == 4)
        #expect(page.posted("rtcRecovered") == 4)
    }

    /// The control: an element suspended again seconds after each resume is
    /// not recovering, and still runs out of attempts.
    @Test func anElementSuspendedRightAfterEachResumeStillGivesUp() {
        let page = RecoveryPage()
        page.run("var v = makeVideo(liveStream('video')); v.play(); tick();")
        page.run("for (var i = 0; i < 6; i++) { advance(2000); tick(); v.paused = true; advance(6000); tick(); }")
        #expect(page.posted("rtcGaveUp") == 1)
        #expect(page.int("plays.length") == 3)  // the page's own, then MAX_ATTEMPTS
    }
}

/// The script in a JavaScriptCore context with an `HTMLMediaElement` faked
/// around it. Promise jobs drain when each evaluation returns; time moves only
/// through `advance(ms)`, and the watchdog ticks only through `tick()`.
@MainActor
private final class RecoveryPage {
    let context: JSContext

    init() {
        context = JSContext()
        context.exceptionHandler = { _, exception in
            Issue.record("JavaScript threw: \(exception?.toString() ?? "?")")
        }
        context.evaluateScript(Self.prelude)
        context.evaluateScript(RAVEWebRTCRecoveryScript.userScript(probeCamera: false).source)
    }

    func run(_ js: String) { context.evaluateScript(js) }
    func bool(_ js: String) -> Bool { context.evaluateScript(js)?.toBool() ?? false }
    func int(_ js: String) -> Int { Int(context.evaluateScript(js)?.toInt32() ?? -1) }
    func posted(_ kind: String) -> Int {
        int("posts.filter(function (m) { return m.kind === '\(kind)'; }).length")
    }

    private static let prelude = #"""
    var window = this;
    var location = { href: 'https://meet.example/abc' };
    var posts = [], plays = [], timers = [], intervals = [], nextTimer = 1;
    var clock = 1000000, refusePlay = false;
    Date.now = function () { return clock; };
    function advance(ms) { clock += ms; }

    function setTimeout(fn) { var id = nextTimer++; timers.push({ id: id, fn: fn }); return id; }
    function clearTimeout(id) { timers = timers.filter(function (t) { return t.id !== id; }); }
    function setInterval(fn) { var id = nextTimer++; intervals.push({ id: id, fn: fn }); return id; }
    function clearInterval(id) { intervals = intervals.filter(function (t) { return t.id !== id; }); }
    // One watchdog tick; attach timers fire first, as they would have by now.
    function tick() {
      var due = timers; timers = []; due.forEach(function (t) { t.fn(); });
      intervals.slice().forEach(function (t) { t.fn(); });
    }

    window.webkit = { messageHandlers: { ravePageReports: { postMessage: function (m) {
      posts.push(JSON.parse(JSON.stringify(m)));
    } } } };
    var navigator = {};

    var audios = [], videos = [];
    var document = {
      readyState: 'complete', documentElement: {},
      querySelectorAll: function (sel) { return sel === 'audio' ? audios : sel === 'video' ? videos : []; }
    };

    function HTMLMediaElement() {}
    HTMLMediaElement.prototype.play = function () {
      plays.push(this.tagName);
      if (!refusePlay) { this.paused = false; }
      return Promise.resolve();
    };
    HTMLMediaElement.prototype.pause = function () { this.paused = true; };
    Object.defineProperty(HTMLMediaElement.prototype, 'srcObject', {
      configurable: true, enumerable: true,
      get: function () { return this._src || null; },
      set: function (value) { this._src = value; }
    });

    function liveStream(kind) {
      return {
        tracks: [{ kind: kind, readyState: 'live', muted: false, enabled: true,
                   getSettings: function () { return {}; } }],
        getTracks: function () { return this.tracks.slice(); },
        getVideoTracks: function () { return this.tracks.filter(function (t) { return t.kind === 'video'; }); },
        getAudioTracks: function () { return this.tracks.filter(function (t) { return t.kind === 'audio'; }); }
      };
    }
    function makeElement(tag, stream) {
      var el = Object.create(HTMLMediaElement.prototype);
      el.tagName = tag; el.paused = true; el.isConnected = true; el.readyState = 4;
      el.videoWidth = tag === 'VIDEO' ? 640 : 0; el.videoHeight = tag === 'VIDEO' ? 360 : 0;
      el.clientWidth = 333; el.clientHeight = 188;
      el.getClientRects = function () { return [{}]; };
      el.srcObject = stream;
      return el;
    }
    function makeAudio(stream) { var el = makeElement('AUDIO', stream); audios.push(el); return el; }
    function makeVideo(stream) { var el = makeElement('VIDEO', stream); videos.push(el); return el; }
    """#
}
#endif
