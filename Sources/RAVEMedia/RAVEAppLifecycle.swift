/*
 RAVEMedia - app lifecycle shim.

 `DepthConversionManager` has to know when the app backgrounds: visionOS kills
 the HEVC encoder out from under a running conversion, so a job in flight is
 interrupted and restarted on foreground rather than surfacing as a failure.
 That knowledge is `UIApplication`'s, which does not exist on macOS — and the
 package declares macOS so `swift test` has a host to build the conversion
 arithmetic for.

 So the three facts it needs go through here. On macOS the app is always
 "active" and the notifications never fire, which is exactly right for a test
 host: nothing there has an app lifecycle to interrupt.
 */

import Foundation

#if canImport(UIKit)
import UIKit
#endif

enum RAVEAppLifecycle {
    /// False while the app is backgrounded or inactive. The conversion pipeline
    /// treats anything but active as "do not start / do not continue encoding".
    @MainActor
    static var isActive: Bool {
        #if canImport(UIKit)
        UIApplication.shared.applicationState == .active
        #else
        true
        #endif
    }

    #if canImport(UIKit)
    static let didEnterBackground = UIApplication.didEnterBackgroundNotification
    static let willEnterForeground = UIApplication.willEnterForegroundNotification
    #else
    /// Names nothing posts, so observers register harmlessly and never fire.
    static let didEnterBackground = Notification.Name("RAVEMediaHostDidEnterBackground")
    static let willEnterForeground = Notification.Name("RAVEMediaHostWillEnterForeground")
    #endif
}
