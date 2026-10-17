#if canImport(WebKit)
import Foundation
import Testing
import WebKit
@testable import RAVEBrowser

/// No JS runtime in this test target, so what's pinnable is the generated
/// source's shape — the same bargain `DarkModeScriptTests` documents. The
/// invariants below are the ones whose loss would be silent: a script that
/// still injects, still logs, and suppresses the wrong keyboard (or swallows
/// the page's focus) looks healthy from every other angle.
@Suite("Keyboard suppression script")
@MainActor
struct KeyboardSuppressionScriptTests {
    private var script: WKUserScript { RAVEKeyboardSuppressionScript.userScript() }
    private var source: String { script.source }

    /// Meet's composer is in the Google Chat iframe, so main-frame-only would
    /// miss the exact element this exists for. Document start because the
    /// `focus()` wrapper has to be in place before any page script calls it.
    @Test func injectsIntoEveryFrameAtDocumentStart() {
        #expect(script.isForMainFrameOnly == false)
        #expect(script.injectionTime == .atDocumentStart)
    }

    /// The rule is "recent trusted gesture ⇒ leave it alone", and both seams
    /// must consult it. A wrapper that suppressed unconditionally would mean a
    /// tapped field never raises a keyboard at all.
    @Test func bothSeamsAreGatedOnARecentGesture() {
        #expect(source.contains("if (ENABLED && !asked() && takesKeyboard(this)) { suppress(this); }"))
        #expect(source.contains("if (asked()) { release(el); return; }"))
        #expect(source.contains("lastGestureAt > 0 && (Date.now() - lastGestureAt) <= GESTURE_WINDOW_MS"))
    }

    /// Only a *trusted* event may count as a gesture. Without this a page that
    /// dispatches its own synthetic pointer events would clear the guard for
    /// itself, which is precisely the case being guarded against.
    @Test func onlyTrustedEventsCountAsGestures() {
        #expect(source.contains("if (!event || !event.isTrusted) { return; }"))
    }

    /// Capture phase, so the gesture is recorded (and the element released)
    /// before any page handler can stop the event travelling — and before the
    /// focus the tap is about to cause.
    @Test func gestureListenersRunInCapturePhase() {
        for event in ["pointerdown", "mousedown", "touchstart", "keydown"] {
            #expect(source.contains("document.addEventListener('\(event)', noteGesture, true);"))
        }
        #expect(source.contains("document.addEventListener('focusin', function (event) {"))
    }

    /// The default action suppresses the keyboard and leaves focus where the
    /// page put it. Blurring is the escalation and ships off — it takes focus
    /// away from a page that may have had a good reason for it, which is the
    /// mistake `WebRTCRecoveryScript` paid for twice.
    @Test func defaultActionIsInputModeRatherThanBlur() {
        #expect(source.contains("var BLUR_INSTEAD = false;"))
        #expect(source.contains("el.setAttribute('inputmode', 'none');"))
    }

    /// The page's focus must happen either way: suppression is a decoration on
    /// the call, never a veto of it.
    @Test func theFocusWrapperAlwaysCallsThrough() {
        #expect(source.contains("return nativeFocus.apply(this, arguments);"))
    }

    /// An element the page never gave an `inputmode` must get none back, not an
    /// invented default — otherwise every field this ever touched is left
    /// carrying an attribute the page did not write.
    @Test func releaseRestoresTheAbsentAttributeAsAbsent() {
        #expect(source.contains("el.hasAttribute('inputmode')"))
        #expect(source.contains("if (was === null || was === undefined) { el.removeAttribute('inputmode'); }"))
    }

    /// Restoring the attribute under a live input session does not re-ask for a
    /// keyboard; WebKit reconsiders on a focus transition, so a tapped element
    /// that already holds focus has to be blurred for the tap to make one.
    @Test func releaseBlursAnAlreadyFocusedElementSoTheTapCanRefocusIt() {
        #expect(source.contains("if (document.activeElement === el) { el.blur(); }"))
    }

    /// Controls that raise no keyboard are not worth a page mutation.
    @Test func leavesInputsThatRaiseNoKeyboardAlone() {
        for type in ["checkbox", "radio", "range", "submit", "file", "color"] {
            #expect(source.contains("\(type): 1"))
        }
    }

    /// The kill switch and the log budget, both of which the sibling scripts
    /// carry for the same reasons: observe-without-acting is the first move
    /// when this misbehaves, and a site that focuses fields constantly must not
    /// spend the document's whole message budget saying so.
    @Test func keepsTheKillSwitchAndTheReportCap() {
        #expect(source.contains("var ENABLED = true;"))
        #expect(source.contains("if (reports++ >= REPORT_CAP) { return; }"))
    }

    /// The double-injection guard: `atDocumentStart` scripts re-run on a
    /// same-document navigation, and a second wrapper around an already-wrapped
    /// `focus()` would nest.
    @Test func guardsAgainstDoubleInjection() {
        #expect(source.contains("window.__ravenKeyboardGuard"))
    }

    /// Reports go to the handler the app names (Raven: its diagnostics).
    @Test func reportsGoToTheHandlerTheAppNames() {
        let raven = RAVEKeyboardSuppressionScript.userScript(reportHandler: "ravenDiagnostics").source
        #expect(raven.hasPrefix(#"window.__ravenKeyboardGuardConfig={reportHandler:"ravenDiagnostics"};"#))
        #expect(raven.contains("window.webkit.messageHandlers[REPORT_HANDLER].postMessage(fields);"))
    }
}
#endif
