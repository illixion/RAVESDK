/*
 RAVEBrowser — no keyboard for a focus the wearer did not ask for.

 Joining a Google Meet call raises the visionOS system keyboard over the call,
 unasked. `PageDiagnosticsScript`'s focus probe caught the cause on a live join:

     [EA28 iframe] focus div type= id=hj99tb0 label=History is on
                   box=70x20 visible=yes editable=yes readonly=no trusted=yes

 That is Meet's **chat composer** — a contenteditable in the Google Chat iframe,
 labelled with the history notice Chat puts on its compose box — taking focus on
 join while the chat panel is closed. Nobody opened chat, nothing was going to be
 typed, and the keyboard arrives anyway.

 **This is a platform difference, not a site bug, and the rule below is the one
 every other WebKit already applies.** On iOS, `element.focus()` from script
 raises no keyboard at all: WebKit requires a user gesture before it will show
 one, which is why an autofocused search box on iOS Safari focuses quietly and
 waits to be tapped. The desktop-class WebKit on visionOS does not carry that
 requirement — there is no soft keyboard on a Mac to withhold — so a page written
 against the desktop rule gets a headset keyboard in the middle of a call. This
 restores the gesture requirement rather than inventing a policy of its own.

 So: a focus that lands on a text field within `GESTURE_WINDOW_MS` of a *trusted*
 pointer or key event is one the wearer asked for and is left entirely alone.
 Anything else is focused with `inputmode="none"`, which suppresses the on-screen
 keyboard and nothing else.

 **`inputmode`, not `blur()`, and the difference is the whole design.** The page
 always has a better reason for its own state than this script does — the lesson
 `WebRTCRecoveryScript` paid for twice. Meet may well want that composer focused
 so a keystroke starts a message; taking focus away would break that, silently,
 on a site that never complains. `inputmode` leaves the page's focus model
 completely untouched and answers only the question the wearer cares about, which
 is whether a keyboard is on screen. A hardware keyboard still types into it.

 **Suppression is set before the focus, not after it.** `HTMLElement.prototype.focus`
 is wrapped so the attribute is in place before WebKit begins focusing — the same
 technique the recovery script uses on `play()`. The `focusin` listener is only a
 backstop for the paths that never call `focus()` (the `autofocus` attribute,
 WebKit's own restoration), where it may well be too late to stop the first
 keyboard; the log says which path fired.

 **Releasing is on the tap, before the tap's focus.** `pointerdown` precedes
 focus, so a trusted one restores `inputmode` on the element under the finger and
 the focus that follows raises the keyboard normally. An element that is *already*
 focused when tapped is blurred first, because restoring the attribute under a
 live input session does not by itself re-ask for a keyboard — the tap has to be a
 real focus transition for WebKit to reconsider.

 Whether this also removes Meet's join lag is a separate claim and is not
 settled: if the lag survives a join with no keyboard, the keyboard was never
 the cause. Raven's `KeyboardSuppressionScript`, lifted 2026-10-17; the
 `__raven…` globals keep their names because other scripts and tests key on
 them.
 */

#if canImport(WebKit)
import Foundation
import WebKit

public enum RAVEKeyboardSuppressionScript {
    /// - Parameter reportHandler: the message handler its `keyboard` lines go
    ///   to: `RAVEPageReports` by default, or an app's own diagnostics (Raven
    ///   passes its `PageDiagnostics` handler, a pure formatter with no state
    ///   to confuse — a second handler for a few lines would be more wiring
    ///   than it is worth). Nothing listening there just drops them.
    @MainActor
    public static func feature(reportHandler: String = RAVEPageReports.messageHandler) -> RAVEUserScriptFeature {
        RAVEUserScriptFeature(userScript(reportHandler: reportHandler))
    }

    @MainActor
    public static func userScript(reportHandler: String = RAVEPageReports.messageHandler) -> WKUserScript {
        WKUserScript(
            source: "window.__ravenKeyboardGuardConfig={reportHandler:\(RAVEJavaScript.string(reportHandler))};\n" + source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    private static let source = #"""
(function () {
  'use strict';
  if (window.__ravenKeyboardGuard) { return; }
  window.__ravenKeyboardGuard = true;

  // Where reports go: Swift picks the handler (`userScript(reportHandler:)`).
  var REPORT_HANDLER = (window.__ravenKeyboardGuardConfig &&
                        window.__ravenKeyboardGuardConfig.reportHandler) || 'ravePageReports';

  // One-line kill switch, same shape as the recovery script's. False makes this
  // observe and report without touching the page — the log still says which
  // element grabbed focus and how long after the last gesture, which is the
  // measurement that decides whether the script is needed at all.
  var ENABLED = true;

  // The escalation, and it ships off. If `inputmode` turns out not to be
  // honoured on this engine the log will say `suppressed` while the keyboard
  // still appears; flipping this blurs the element instead, which certainly
  // dismisses it and just as certainly fights the page for its own focus. Do not
  // turn it on without reading the paragraph about `WebRTCRecoveryScript` above.
  var BLUR_INSTEAD = false;

  // How recently a real gesture must have happened for a focus to count as one
  // the wearer asked for. Generous on purpose: a page that focuses its composer
  // in a promise chain a tap started is still acting on that tap, and the cost of
  // being wrong in this direction is a keyboard that was wanted anyway.
  var GESTURE_WINDOW_MS = 1500;

  // A site that focuses fields constantly must not spend the whole document's
  // log budget saying so.
  var REPORT_CAP = 12;
  var URL_CAP = 300;
  var TEXT_CAP = 120;

  var lastGestureAt = 0;
  var reports = 0;

  function post(kind, fields) {
    try {
      if (reports++ >= REPORT_CAP) { return; }
      fields.kind = kind;
      fields.where = String(location.href || '').slice(0, URL_CAP);
      fields.top = (window === window.top);
      window.webkit.messageHandlers[REPORT_HANDLER].postMessage(fields);
    } catch (e) {}
  }

  function clamp(value) {
    try { return String(value == null ? '' : value).slice(0, TEXT_CAP); }
    catch (e) { return ''; }
  }

  // The input types that raise no keyboard whatever happens are left alone: a
  // checkbox or a colour well has nothing to suppress, and marking one would be
  // a page mutation bought for nothing.
  var SILENT_TYPES = {
    button: 1, checkbox: 1, color: 1, file: 1, hidden: 1, image: 1,
    radio: 1, range: 1, reset: 1, submit: 1
  };

  function takesKeyboard(el) {
    try {
      if (!el || !el.tagName) { return false; }
      var tag = String(el.tagName).toLowerCase();
      if (tag === 'textarea') { return true; }
      if (tag === 'input') {
        var type = String(el.getAttribute('type') || 'text').toLowerCase();
        return !SILENT_TYPES[type];
      }
      return el.isContentEditable === true;
    } catch (e) { return false; }
  }

  function describe(el) {
    var box = { width: 0, height: 0 };
    try { box = el.getBoundingClientRect(); } catch (e) {}
    return {
      tag: clamp(el.tagName && String(el.tagName).toLowerCase()),
      id: clamp(el.id),
      label: clamp((el.getAttribute && (el.getAttribute('aria-label')
              || el.getAttribute('placeholder'))) || ''),
      box: Math.round(box.width) + 'x' + Math.round(box.height),
      sinceGesture: lastGestureAt ? (Date.now() - lastGestureAt) : -1
    };
  }

  function suppress(el) {
    try {
      if (el.__ravenKbHeld) { return; }
      el.__ravenKbHeld = true;
      // Recorded as "was there an attribute at all", so releasing can put the
      // element back exactly as the page had it rather than leaving an
      // `inputmode="text"` the page never wrote.
      el.__ravenKbWas = el.hasAttribute('inputmode')
        ? el.getAttribute('inputmode') : null;
      var fields = describe(el);
      if (BLUR_INSTEAD) {
        fields.action = 'blurred';
        el.blur();
      } else {
        fields.action = 'suppressed';
        el.setAttribute('inputmode', 'none');
      }
      post('keyboard', fields);
    } catch (e) {}
  }

  function release(el) {
    try {
      if (!el || !el.__ravenKbHeld) { return; }
      el.__ravenKbHeld = false;
      var was = el.__ravenKbWas;
      if (was === null || was === undefined) { el.removeAttribute('inputmode'); }
      else { el.setAttribute('inputmode', was); }
      var fields = describe(el);
      fields.action = 'released';
      // Restoring the attribute under a live input session does not re-ask for a
      // keyboard — WebKit reconsiders on a focus transition. The tap that got
      // here is about to make one, so long as the element is not already the
      // thing it would focus.
      try {
        if (document.activeElement === el) { el.blur(); }
      } catch (e) {}
      post('keyboard', fields);
    } catch (e) {}
  }

  function noteGesture(event) {
    try {
      if (!event || !event.isTrusted) { return; }
      lastGestureAt = Date.now();
      // Walk up from the target: the tap lands on whatever the field renders
      // inside (a span of text in a contenteditable), not on the field itself.
      var node = event.target;
      for (var depth = 0; node && depth < 12; depth++) {
        if (node.__ravenKbHeld) { release(node); break; }
        node = node.parentNode;
      }
    } catch (e) {}
  }

  function asked() {
    return lastGestureAt > 0 && (Date.now() - lastGestureAt) <= GESTURE_WINDOW_MS;
  }

  try {
    // Capture phase, so the gesture is recorded before any page handler can stop
    // the event travelling — and before the focus it is about to cause.
    document.addEventListener('pointerdown', noteGesture, true);
    document.addEventListener('mousedown', noteGesture, true);
    document.addEventListener('touchstart', noteGesture, true);
    document.addEventListener('keydown', noteGesture, true);
  } catch (e) {}

  // The primary seam: in place before WebKit starts focusing, which the focusin
  // backstop below cannot promise.
  try {
    var nativeFocus = HTMLElement.prototype.focus;
    HTMLElement.prototype.focus = function () {
      try {
        if (ENABLED && !asked() && takesKeyboard(this)) { suppress(this); }
      } catch (e) {}
      return nativeFocus.apply(this, arguments);
    };
  } catch (e) {}

  // Backstop for the focus paths that never call focus(): the autofocus
  // attribute, and WebKit restoring focus itself.
  try {
    document.addEventListener('focusin', function (event) {
      try {
        var el = event.target;
        if (!takesKeyboard(el)) { return; }
        if (asked()) { release(el); return; }
        if (ENABLED) { suppress(el); }
      } catch (e) {}
    }, true);
  } catch (e) {}
})();
"""#
}
#endif
