#if canImport(WebKit)
import Foundation
import JavaScriptCore
import Testing
@testable import RAVEBrowser

/// The avatar source's privacy rule, run rather than read: the real
/// `RAVECameraProxyScript` is evaluated in JavaScriptCore against stand-ins for
/// the WebKit objects it touches, and every way the proxy used to degrade to
/// WebKit's camera is driven through. With the avatar selected, none may ask
/// WebKit for the camera a second time, bind it to the element, draw it, or
/// hand the page a stream carrying it. Moved from Raven with the script, and
/// joined by the virtual device's stronger rule: never ask WebKit at all.
///
/// The fakes record exactly those four things. The Persona control case shows
/// the same recording catches a fallback when one happens, so the avatar
/// assertions cannot pass by observing nothing.
@Suite("Camera proxy fails closed")
@MainActor
struct RAVECameraProxyFailClosedTests {
    @Test func noAvatarFrameInTimePaintsTheCardNotTheCamera() {
        let page = ProxyPage(mode: .avatar)
        page.run("request({ video: { width: 1280, height: 720 } });")
        #expect(page.posted("nativeStart") == 1)
        #expect(page.bool("log.stopped.indexOf('REAL CAMERA') >= 0"), "the real track is released before Swift is asked")
        #expect(!page.bool("result !== null"), "nothing painted yet, so nothing handed over")

        page.run("fireTimers();")  // FIRST_PAINT_MS passes with no frame

        #expect(page.bool("result !== null && failure === null"), "the page still gets its track")
        #expect(page.bool("result.getVideoTracks()[0].isCanvas === true"))
        #expect(page.bool("log.texts.indexOf('Avatar camera offline') >= 0"))
        #expect(page.posted("avatarFault") == 1)
        page.expectRealCameraNeverShown()
    }

    /// Swift's outage, its stray `nativeEnd`, a decoder fault, a configure
    /// that throws: each was a fallback to WebKit's camera with the Persona.
    @Test func everyFailureAfterArmingStaysOnTheProxy() {
        let page = ProxyPage(mode: .avatar)
        page.run("request({ video: true });")
        page.run("__ravenReplay.nativeOffline();")
        #expect(page.bool("result !== null && result.getVideoTracks()[0].isCanvas === true"))

        // The avatar comes back: a decoded frame replaces the card.
        page.run("""
        __ravenReplay.nativeConfig('hvc1.1.6.L120.B0', 'AAAA');
        __ravenReplay.nativeChunk('AAAA', 33333, true, -1, Date.now());
        decoders[decoders.length - 1].init.output(fakeFrame(33333));
        """)
        #expect(page.bool("log.drawn.indexOf('frame') >= 0"), "the avatar frame painted")
        #expect(page.int("intervals.length") == 0, "the card's repaint stops once frames return")

        page.run("""
        decoders[decoders.length - 1].init.error({ name: 'EncodingError' });
        __ravenReplay.nativeEnd('the camera is in use by another tab');
        VideoDecoder.prototype.configure = function () { throw new Error('unsupported'); };
        __ravenReplay.nativeConfig('hvc1.bogus', 'AAAA');
        fireTimers(); fireIntervals();
        """)
        #expect(page.int("intervals.length") == 1, "the card is up and being repainted")
        page.expectRealCameraNeverShown()
        #expect(page.posted("nativeStop") == 0, "the native session stays wanted, so Swift keeps reconnecting")
    }

    /// A combined request is taken apart rather than returned whole: the
    /// microphone is the page's, live and untouched; the camera is the proxy.
    @Test func aCombinedRequestKeepsTheMicrophoneAndProxiesTheCamera() {
        let page = ProxyPage(mode: .avatar)
        page.run("request({ video: true, audio: true });")
        page.run("__ravenReplay.nativeOffline();")
        #expect(page.bool("result !== null"))
        #expect(page.int("result.getVideoTracks().length") == 1)
        #expect(page.bool("result.getVideoTracks()[0].isCanvas === true"))
        #expect(page.bool("result.getAudioTracks().length === 1 && result.getAudioTracks()[0].label === 'REAL MIC'"))
        #expect(page.bool("result.getAudioTracks()[0].readyState === 'live'"))
        page.expectRealCameraNeverShown()
    }

    /// WebKit's legacy call reaches the internal method, not the property the
    /// proxy replaced, and the prototype's original is one `.call` away. With
    /// the avatar both lead to the proxy.
    @Test func theLegacyAndPrototypeCallsGoThroughTheProxy() {
        let page = ProxyPage(mode: .avatar)
        page.run("navigator.getUserMedia({ video: true }, function (s) { result = s; }, function (e) { failure = e; });")
        page.run("__ravenReplay.nativeOffline();")
        #expect(page.bool("result !== null && result.getVideoTracks()[0].isCanvas === true"))
        page.run("""
        result = null;
        MediaDevices.prototype.getUserMedia.call(navigator.mediaDevices, { video: true })
          .then(function (s) { result = s; });
        """)
        page.run("__ravenReplay.nativeOffline();")
        #expect(page.bool("result !== null && result.getVideoTracks()[0].isCanvas === true"))
        #expect(page.posted("nativeStart") == 2)
        page.expectRealCameraNeverShown(requests: 2)
    }

    /// The control: with the Persona, the same `nativeEnd` does fall back to
    /// WebKit's camera — and this harness sees it. Without this, the avatar
    /// tests above could be passing because the fakes record nothing.
    @Test func thePersonaFallbackIsVisibleToTheHarness() {
        let page = ProxyPage(mode: .persona(nativeCapture: true))
        page.run("request({ video: true });")
        page.run("__ravenReplay.nativeEnd('access denied');")
        #expect(page.int("gumCalls.length") == 2)
        #expect(page.int("log.srcObjectSet") == 1)
        #expect(page.int("log.rvfc") >= 1)
        // The element loop paints the real camera from here on.
        page.run("log.frameCallbacks.forEach(function (cb) { cb(); });")
        #expect(page.bool("log.drawn.indexOf('video') >= 0"))
    }

    // MARK: - The virtual device

    private static let device = RAVEVirtualCaptureDevice(
        label: "Avatar", deviceId: "virtual-avatar-id", groupId: "virtual-avatar-group")
    private func virtualPage() -> ProxyPage { ProxyPage(mode: .virtualDevice(Self.device)) }

    /// A camera request never reaches WebKit: the proxy answers it alone, from
    /// the feed, and the page's track is painted by the feed's frames.
    @Test func aVideoOnlyRequestNeverReachesWebKit() {
        let page = virtualPage()
        page.run("request({ video: { width: 1280, height: 720 } });")
        #expect(page.int("gumCalls.length") == 0)
        #expect(page.posted("nativeStart") == 1)
        page.run("paintAFrame();")
        #expect(page.bool("result !== null && failure === null"))
        #expect(page.bool("result.getVideoTracks()[0].isCanvas === true"))
        #expect(page.bool("log.drawn.indexOf('frame') >= 0"), "the feed's frame painted the track")
        #expect(page.bool("result.getAudioTracks().length === 0"))
        page.expectNoCameraEverRequested()
    }

    /// Audio and video: WebKit gets the audio half alone, exactly as asked, and
    /// the page gets one stream carrying its microphone and the proxy camera.
    @Test func audioAndVideoSendsOnlyAudioToWebKit() {
        let page = virtualPage()
        page.run("request({ video: true, audio: { echoCancellation: true } });")
        #expect(page.int("gumCalls.length") == 1)
        #expect(page.bool("gumCalls[0].video === undefined"))
        #expect(page.bool("gumCalls[0].audio.echoCancellation === true"))
        page.run("__ravenReplay.nativeOffline();")
        #expect(page.bool("result !== null"))
        #expect(page.bool("result.getVideoTracks().length === 1 && result.getVideoTracks()[0].isCanvas === true"))
        #expect(page.bool("result.getAudioTracks().length === 1 && result.getAudioTracks()[0].label === 'REAL MIC'"))
        #expect(page.bool("result.getAudioTracks()[0].readyState === 'live'"))
        page.expectNoCameraEverRequested()
    }

    /// A microphone-only request is none of the proxy's business.
    @Test func audioOnlyPassesThroughUntouched() {
        let page = virtualPage()
        page.run("var asked = { audio: true }; request(asked);")
        #expect(page.bool("gumCalls.length === 1 && gumCalls[0] === asked"))
        #expect(page.bool("result !== null && result.getAudioTracks()[0].label === 'REAL MIC'"))
        #expect(page.posted("nativeStart") == 0)
    }

    /// The device is listed before any permission, in place of WebKit's
    /// anonymous camera entry, with the real audio entries left as they were —
    /// through the instance and through the prototype alike.
    @Test func enumerateDevicesListsTheDevice() {
        let page = virtualPage()
        page.run("listDevices();")
        #expect(page.bool("devices.map(function (d) { return d.kind; }).join() === 'audioinput,videoinput,audiooutput'"))
        #expect(page.bool("devices[1].deviceId === 'virtual-avatar-id'"))
        #expect(page.bool("devices[1].groupId === 'virtual-avatar-group'"))
        #expect(page.bool("devices[1].label === 'Avatar'"))
        #expect(page.bool("devices[1].getCapabilities().deviceId === 'virtual-avatar-id'"))
        #expect(page.bool("JSON.stringify(devices[1]).indexOf('virtual-avatar-id') >= 0"))
        #expect(page.bool("devices[0].label === '' && devices[2].kind === 'audiooutput'"), "audio entries untouched")
        page.run("""
        devices = null;
        MediaDevices.prototype.enumerateDevices.call(navigator.mediaDevices).then(function (l) { devices = l; });
        """)
        #expect(page.bool("devices.filter(function (d) { return d.kind === 'videoinput'; }).length === 1"))
        #expect(page.bool("devices[1].deviceId === 'virtual-avatar-id'"))
        page.expectNoCameraEverRequested()
    }

    /// The id a page reads from `enumerateDevices` and asks for with `exact`
    /// is the id the track reports everywhere a page can look — the check Meet
    /// failed a synthesized microphone on.
    @Test func theDeviceIdRoundTripsThroughExact() {
        let page = virtualPage()
        page.run("listDevices();")
        page.run("request({ video: { deviceId: { exact: devices[1].deviceId }, width: 1280 } });")
        page.run("paintAFrame();")
        page.run("var track = result.getVideoTracks()[0];")
        #expect(page.bool("track.getSettings().deviceId === 'virtual-avatar-id'"))
        #expect(page.bool("track.getSettings().groupId === 'virtual-avatar-group'"))
        #expect(page.bool("track.label === 'Avatar'"))
        #expect(page.bool("track.getCapabilities().deviceId === 'virtual-avatar-id'"))
        #expect(page.bool("track.getCapabilities().groupId === 'virtual-avatar-group'"))
        #expect(page.bool("track.getConstraints().deviceId.exact === 'virtual-avatar-id'"))
        #expect(page.bool("track.getConstraints().width === 1280"))
        page.expectNoCameraEverRequested()
    }

    /// There is no other camera in this mode: an `exact` for someone else's
    /// camera, an `ideal`, a bare id, all get the virtual device — and read
    /// back naming it, in the form they were asked in.
    @Test func anyCameraIdGetsTheVirtualDevice() {
        let page = virtualPage()
        page.run("request({ video: { deviceId: { exact: 'someone-elses-camera' } } });")
        page.run("paintAFrame();")
        #expect(page.bool("result !== null && result.getVideoTracks()[0].isCanvas === true"))
        #expect(page.bool("result.getVideoTracks()[0].getConstraints().deviceId.exact === 'virtual-avatar-id'"))
        page.run("result = null; request({ video: { deviceId: { ideal: 'x' } } });")
        page.run("paintAFrame();")
        #expect(page.bool("result.getVideoTracks()[0].getConstraints().deviceId.ideal === 'virtual-avatar-id'"))
        page.run("result = null; request({ video: { deviceId: 'x' } });")
        page.run("paintAFrame();")
        #expect(page.bool("result.getVideoTracks()[0].getConstraints().deviceId === 'virtual-avatar-id'"))
        page.run("result.getVideoTracks()[0].applyConstraints({ deviceId: { exact: 'y' }, frameRate: 24 });")
        #expect(page.bool("result.getVideoTracks()[0].getConstraints().deviceId.exact === 'virtual-avatar-id'"))
        #expect(page.bool("result.getVideoTracks()[0].getConstraints().frameRate === 24"))
        #expect(page.posted("nativeStart") == 3)
        page.expectNoCameraEverRequested()
    }

    /// The camera is granted; the microphone is WebKit's question.
    @Test func permissionsGrantTheCameraAndLeaveTheMicrophone() {
        let page = virtualPage()
        page.run("""
        var camera = null, microphone = null;
        navigator.permissions.query({ name: 'camera' }).then(function (s) { camera = s; });
        navigator.permissions.query({ name: 'microphone' }).then(function (s) { microphone = s; });
        """)
        #expect(page.bool("camera.state === 'granted' && camera.name === 'camera'"))
        page.run("camera.onchange = function () {}; camera.addEventListener('change', function () {});")
        #expect(page.bool("typeof camera.onchange === 'function'"), "a page may set the handler")
        #expect(page.bool("microphone.state === 'prompt'"))
        #expect(page.bool("permissionQueries.join() === 'microphone'"), "only the microphone reached WebKit")
    }

    /// Fail closed, as the avatar does: the feed ending, a decoder fault, a
    /// stray `nativeEnd`, a first frame that never comes — the card, every
    /// time, on the same track, and never the real camera.
    @Test func theFeedEndingShowsTheCardNeverTheRealCamera() {
        let page = virtualPage()
        page.run("request({ video: true });")
        page.run("paintAFrame();")
        #expect(page.bool("result !== null && result.getVideoTracks()[0].isCanvas === true"))
        page.run("__ravenReplay.nativeOffline();")
        #expect(page.bool("log.texts.indexOf('Avatar camera offline') >= 0"))
        #expect(page.int("intervals.length") == 1, "the card is up and being repainted")
        page.run("""
        paintAFrame();
        decoders[decoders.length - 1].init.error({ name: 'EncodingError' });
        __ravenReplay.nativeEnd('gone');
        fireTimers(); fireIntervals();
        """)
        #expect(page.posted("avatarFault") >= 1)
        #expect(page.posted("nativeStop") == 0, "the feed stays wanted, so Swift keeps reconnecting")
        #expect(page.int("intervals.length") == 1)
        page.expectNoCameraEverRequested()

        // A first frame that never comes is the same outage, not a fallback.
        let late = virtualPage()
        late.run("request({ video: true });")
        late.run("fireTimers();")
        #expect(late.bool("result !== null && result.getVideoTracks()[0].isCanvas === true"))
        #expect(late.bool("log.texts.indexOf('Avatar camera offline') >= 0"))
        late.expectNoCameraEverRequested()
    }

    /// The side doors are closed here too.
    @Test func theLegacyCallGoesThroughTheVirtualDevice() {
        let page = virtualPage()
        page.run("navigator.getUserMedia({ video: true }, function (s) { result = s; }, function (e) { failure = e; });")
        page.run("__ravenReplay.nativeOffline();")
        #expect(page.bool("result !== null && result.getVideoTracks()[0].isCanvas === true"))
        page.expectNoCameraEverRequested()
    }

    /// The Persona and the avatar list and permit what WebKit does: only the
    /// virtual device virtualizes.
    @Test func otherModesLeaveDevicesAndPermissionsToWebKit() {
        for mode in [RAVECameraProxy.Mode.persona(nativeCapture: true), .avatar] {
            let page = ProxyPage(mode: mode)
            page.run("""
            listDevices();
            var camera = null;
            navigator.permissions.query({ name: 'camera' }).then(function (s) { camera = s; });
            """)
            #expect(page.bool("devices[1].kind === 'videoinput' && devices[1].deviceId === ''"))
            #expect(page.bool("camera.state === 'prompt'"))
        }
    }
}

// MARK: - The page

/// `RAVECameraProxyScript` in a JavaScriptCore context with just enough of WebKit
/// faked around it. JavaScriptCore drains promise jobs when an evaluation
/// returns, so each `run` sees its promise chains settled; timers never fire
/// on their own — `fireTimers()` / `fireIntervals()` stand in for time.
@MainActor
private final class ProxyPage {
    let context: JSContext

    init(mode: RAVECameraProxy.Mode) {
        context = JSContext()
        context.exceptionHandler = { _, exception in
            Issue.record("JavaScript threw: \(exception?.toString() ?? "?")")
        }
        context.evaluateScript(Self.prelude)
        context.evaluateScript(
            RAVECameraProxyScript.userScript(
                aspect: 16.0 / 9.0, mode: mode,
                offlineCard: .init(title: "Avatar camera offline", hint: "Open Spatial Character")
            ).source
        )
    }

    func run(_ js: String) { context.evaluateScript(js) }
    func bool(_ js: String) -> Bool { context.evaluateScript(js)?.toBool() ?? false }
    func int(_ js: String) -> Int { Int(context.evaluateScript(js)?.toInt32() ?? -1) }
    func posted(_ kind: String) -> Int {
        int("posts.filter(function (m) { return m.kind === '\(kind)'; }).length")
    }

    /// The four ways the real camera could reach the site: asked for again,
    /// bound to the element, drawn, or handed over in the page's stream.
    func expectRealCameraNeverShown(requests: Int = 1,
                                    sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(int("gumCalls.length") == requests, "WebKit asked for the camera again",
                sourceLocation: sourceLocation)
        #expect(int("log.srcObjectSet") == 0, "the element was bound to a camera stream",
                sourceLocation: sourceLocation)
        #expect(!bool("log.drawn.indexOf('video') >= 0"), "the element was drawn",
                sourceLocation: sourceLocation)
        #expect(int("log.rvfc") == 0, "the element frame loop started", sourceLocation: sourceLocation)
        #expect(!bool("""
        result !== null && result.getVideoTracks().some(function (t) { return t.label === 'REAL CAMERA' && !t.isCanvas; })
        """), "the page was handed the real camera track", sourceLocation: sourceLocation)
        #expect(!bool("liveRealCameras() > 0"), "a real camera track is still running",
                sourceLocation: sourceLocation)
    }

    /// The virtual device's stronger rule: WebKit is never asked for a camera
    /// at all — no request with `video`, no real camera track ever made.
    func expectNoCameraEverRequested(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(int("gumCalls.filter(function (c) { return c && c.video; }).length") == 0,
                "WebKit was asked for a camera", sourceLocation: sourceLocation)
        #expect(int("realTracks.length") == 0, "a real camera track exists", sourceLocation: sourceLocation)
        #expect(int("log.srcObjectSet") == 0, "the element was bound to a stream", sourceLocation: sourceLocation)
        #expect(int("log.rvfc") == 0, "the element frame loop started", sourceLocation: sourceLocation)
        #expect(!bool("log.drawn.indexOf('video') >= 0"), "the element was drawn", sourceLocation: sourceLocation)
    }

    private static let prelude = #"""
    var window = this;
    var console = { log: function () {}, error: function () {} };
    var posts = [], gumCalls = [], timers = [], intervals = [], nextTimer = 1, decoders = [];
    var realTracks = [];
    var log = { drawn: [], texts: [], filled: 0, srcObjectSet: 0, rvfc: 0, frameCallbacks: [], stopped: [] };
    var result = null, failure = null;

    function setTimeout(fn) { var id = nextTimer++; timers.push({ id: id, fn: fn }); return id; }
    function clearTimeout(id) { timers = timers.filter(function (t) { return t.id !== id; }); }
    function setInterval(fn) { var id = nextTimer++; intervals.push({ id: id, fn: fn }); return id; }
    function clearInterval(id) { intervals = intervals.filter(function (t) { return t.id !== id; }); }
    function fireTimers() { var due = timers; timers = []; due.forEach(function (t) { t.fn(); }); }
    function fireIntervals() { intervals.slice().forEach(function (t) { t.fn(); }); }
    function atob(s) { return new Array(Math.floor(s.length * 3 / 4) + 1).join('\0'); }
    function Event(type) { this.type = type; }
    function DOMException(message, name) { this.message = message; this.name = name; }

    window.addEventListener = function () {};
    window.webkit = { messageHandlers: { ravenReplay: { postMessage: function (m) {
      posts.push(JSON.parse(JSON.stringify(m)));
    } } } };

    function makeTrack(kind, label) {
      var track = {
        kind: kind, label: label, readyState: 'live', enabled: true, isCanvas: false,
        stop: function () { this.readyState = 'ended'; log.stopped.push(this.label); },
        getSettings: function () { return { deviceId: label + '-id', width: 1080, height: 1080 }; },
        getCapabilities: function () { return {}; },
        addEventListener: function () {},
        dispatchEvent: function () {},
        applyConstraints: function () { return Promise.resolve(); }
      };
      if (label === 'REAL CAMERA') { realTracks.push(track); }
      return track;
    }
    function liveRealCameras() {
      return realTracks.filter(function (t) { return t.readyState === 'live'; }).length;
    }
    function makeStream(tracks) {
      return {
        tracks: tracks.slice(),
        getTracks: function () { return this.tracks.slice(); },
        getVideoTracks: function () { return this.tracks.filter(function (t) { return t.kind === 'video'; }); },
        getAudioTracks: function () { return this.tracks.filter(function (t) { return t.kind === 'audio'; }); },
        addTrack: function (t) { this.tracks.push(t); }
      };
    }

    // WebKit's getUserMedia, and its legacy call, which reaches the internal
    // method rather than the `getUserMedia` property.
    function webkitGetUserMedia(constraints) {
      gumCalls.push(constraints);
      var tracks = [];
      if (constraints && constraints.video) { tracks.push(makeTrack('video', 'REAL CAMERA')); }
      if (constraints && constraints.audio) { tracks.push(makeTrack('audio', 'REAL MIC')); }
      return Promise.resolve(makeStream(tracks));
    }
    function MediaDevices() {}
    MediaDevices.prototype.getUserMedia = function (c) { return webkitGetUserMedia(c); };
    // What WebKit lists before any grant: one entry per kind, no ids, no labels.
    MediaDevices.prototype.enumerateDevices = function () {
      return Promise.resolve([
        { kind: 'audioinput', deviceId: '', groupId: '', label: '' },
        { kind: 'videoinput', deviceId: '', groupId: '', label: '' },
        { kind: 'audiooutput', deviceId: '', groupId: '', label: '' }
      ]);
    };
    var permissionQueries = [];
    function Permissions() {}
    Permissions.prototype.query = function (descriptor) {
      permissionQueries.push(descriptor.name);
      return Promise.resolve({ name: descriptor.name, state: 'prompt' });
    };
    function Navigator() {}
    Navigator.prototype.getUserMedia = function (c, ok, err) { webkitGetUserMedia(c).then(ok, err); };
    var navigator = new Navigator();
    navigator.mediaDevices = new MediaDevices();
    navigator.permissions = new Permissions();
    var devices = null;
    function listDevices() {
      navigator.mediaDevices.enumerateDevices().then(function (list) { devices = list; });
    }

    function makeContext() {
      return {
        fillStyle: '', font: '', textAlign: '', textBaseline: '',
        drawImage: function (image) { log.drawn.push(image && image.tag); },
        fillRect: function () { log.filled++; },
        fillText: function (text) { log.texts.push(text); }
      };
    }
    var document = {
      body: { appendChild: function (n) { n.parentNode = this; }, removeChild: function () {} },
      documentElement: null,
      createElement: function (tag) {
        if (tag === 'video') {
          var video = {
            tag: 'video', style: {}, videoWidth: 1080, videoHeight: 1080, parentNode: null,
            setAttribute: function () {}, pause: function () {},
            play: function () { return Promise.resolve(); },
            requestVideoFrameCallback: function (cb) { log.rvfc++; log.frameCallbacks.push(cb); }
          };
          Object.defineProperty(video, 'srcObject', {
            get: function () { return this._src || null; },
            set: function (value) { if (value) { log.srcObjectSet++; } this._src = value; }
          });
          return video;
        }
        return {
          tag: 'canvas', style: {}, width: 300, height: 150, parentNode: null,
          getContext: function () { return makeContext(); },
          captureStream: function () {
            var track = makeTrack('video', 'canvas');
            track.isCanvas = true;
            return makeStream([track]);
          }
        };
      }
    };

    function VideoDecoder(init) {
      this.init = init; this.state = 'unconfigured'; this.decodeQueueSize = 0;
      decoders.push(this);
    }
    VideoDecoder.prototype.configure = function () { this.state = 'configured'; };
    VideoDecoder.prototype.decode = function () {};
    VideoDecoder.prototype.close = function () { this.state = 'closed'; };
    function EncodedVideoChunk(init) { this.type = init.type; this.timestamp = init.timestamp; }
    function fakeFrame(timestamp) {
      return { tag: 'frame', timestamp: timestamp, displayWidth: 1920, displayHeight: 1080, close: function () {} };
    }

    function request(constraints) {
      navigator.mediaDevices.getUserMedia(constraints)
        .then(function (s) { result = s; }, function (e) { failure = e; });
    }
    function paintAFrame() {
      __ravenReplay.nativeConfig('hvc1.1.6.L120.B0', 'AAAA');
      __ravenReplay.nativeChunk('AAAA', 33333, true, -1, Date.now());
      decoders[decoders.length - 1].init.output(fakeFrame(33333));
    }
    """#
}
#endif
