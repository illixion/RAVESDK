/*
 RAVE SDK — accessibility identifiers for the shared UI.

 XCUITest is the only supported way to drive a visionOS app's UI: `simctl` has
 no tap/swipe/scroll of any kind, so the alternative is coordinate math against
 a screenshot. XCUITest finds elements by identifier or label, and a *label* is
 display copy — it changes with the wording and takes the test with it. So the
 shared components carry identifiers, formed here rather than spelled out at
 each call site in each app.

 Identifiers are derived from a name so a test can compute the same string
 without linking the app: `RAVEA11y.tab("pictures")` is what the Pictures tab
 button will carry. Pass the *stable* name, not the display title — for an
 enum-backed tab that means the case name, which survives the copy changes the
 title does not (`RAVETabItem.accessibilityIdentifier` is overridable for
 exactly that).
 */

#if canImport(SwiftUI)

import SwiftUI

/// Identifier vocabulary for the shared UI. Values are stable API: a test in
/// another repository may be matching on them, so change them the way you would
/// change a public function's name.
public enum RAVEA11y {

    // MARK: - Tab bar

    /// A tab-bar tab button.
    public static func tab(_ name: String) -> String { "rave.tab.\(slug(name))" }

    /// A trailing action button in the tab bar (Spatial Stash's slideshow
    /// launcher and library switch).
    public static func tabAction(_ name: String) -> String { "rave.tabAction.\(slug(name))" }

    // MARK: - Window manager

    /// The window inventory's list.
    public static let windowList = "rave.windowList"

    /// One window's row, identified by the label the app gave it.
    public static func windowRow(_ title: String) -> String { "rave.window.\(slug(title))" }

    /// The Summon button in a window's row.
    public static func windowSummon(_ title: String) -> String { "\(windowRow(title)).summon" }

    /// The Close button in a window's row.
    public static func windowClose(_ title: String) -> String { "\(windowRow(title)).close" }

    // MARK: - Slug

    /// Lowercased, with every run of non-alphanumerics collapsed to a single
    /// hyphen and the ends trimmed.
    ///
    /// Deliberately simple and total: identifiers have to be computable by a
    /// test target that shares nothing with the app but this function, so it
    /// cannot depend on locale-sensitive transforms or reject any input.
    public static func slug(_ name: String) -> String {
        var out = ""
        var pendingSeparator = false
        for character in name.lowercased() {
            if character.isLetter || character.isNumber {
                if pendingSeparator && !out.isEmpty { out.append("-") }
                pendingSeparator = false
                out.append(character)
            } else {
                pendingSeparator = true
            }
        }
        return out
    }
}

#endif
