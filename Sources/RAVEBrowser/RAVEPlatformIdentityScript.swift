/*
 RAVEBrowser — finishing the Mac costume.

 A `RAVEBrowserTab` already identifies as desktop Mac Safari: WebKit's own UA
 says "Macintosh; Intel Mac OS X" on visionOS and `applicationNameForUserAgent`
 appends the Safari tail (`RAVEBrowserTab.safariUserAgentTail`). But WKWebView also reports
 `navigator.maxTouchPoints === 5`, and `platform === 'MacIntel'` with touch
 points is exactly the fingerprint Google uses to unmask desktop-mode iPads
 and classify them as mobile. Meet's measured response to that classification
 is a grayed-out Present button — with `getDisplayMedia=yes` and a clean
 desktop UA in the same capability report, so the shim and the UA both passed
 and the touch points were the remaining tell.

 A real Mac reports zero, so zero is what this claims. It is a smaller lie
 than the UA one it completes: the UA asserts an OS the app does not run on;
 this only asserts the absence of a digitizer that, for a wearer using gaze
 and pinch, arguably isn't there anyway.

 Deliberately NOT hidden: `'ontouchstart' in window` and `TouchEvent`. Sites
 feature-detect those to decide which listeners to attach, and visionOS
 really does deliver touch events for pinches — hiding them risks breaking
 drag interactions everywhere to satisfy a check Meet is not known to make.
 If the button stays gray with zero touch points, escalate there, measured.

 Page world at document start, all frames: identity must be consistent before
 any page script reads it, and Meet reads it from iframes too. First of a
 tab's scripts, so every later one (and any capability report) sees the
 finished identity.

 If a site's drag or scroll ever misbehaves, this spoof is the first suspect.
 Raven's `PlatformIdentityScript`, lifted 2026-10-17 with the call layer.
 */

#if canImport(WebKit)
import Foundation
import WebKit

public enum RAVEPlatformIdentityScript {
    @MainActor
    public static func feature() -> RAVEUserScriptFeature {
        RAVEUserScriptFeature(userScript())
    }

    @MainActor
    public static func userScript() -> WKUserScript {
        WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    private static let source = #"""
(function () {
  'use strict';
  try {
    Object.defineProperty(Navigator.prototype, 'maxTouchPoints', {
      get: function () { return 0; },
      configurable: true
    });
  } catch (e) {}
})();
"""#
}
#endif
