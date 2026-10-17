//
//  RAVEBrowserLog.swift
//  RAVEBrowser
//
//  The subsystem stays `Bundle.main.bundleIdentifier`, as in `RAVECameraLog`,
//  so these lines sort with the host app's; only the categories are the
//  package's own. `browser` is the category Raven's tab lines always had,
//  kept so its console filters still find them.
//
//  Privacy is per value, and this is a web browser: debug traces are read by
//  cloud models and sent in by users.
//  - `.public` for what this code decided or measured: states, reasons it
//    wrote itself, counts, sizes, error domains and codes, and shape tokens a
//    script reported after `RAVELogToken` has vetted them.
//  - `.private` for anything a page or the user supplied: URLs, titles,
//    console and exception text, device labels, free-form messages a page
//    could have posted. Hosts are `.private(mask: .hash)`, so one tab can be
//    followed across lines.
//

import DebugTrace
import Foundation

public enum RAVEBrowserLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.illixion.ravebrowser"

    /// Tabs: navigation, content-process deaths, hibernation.
    public static let browser = DebugLogger(subsystem: subsystem, category: "browser")
    /// The camera proxy: its feed, the relay, the page's latency reports.
    public static let cameraProxy = DebugLogger(subsystem: subsystem, category: "cameraProxy")
    /// What page scripts report through `RAVEPageReports`.
    public static let page = DebugLogger(subsystem: subsystem, category: "page")
}

/// A value a page script reported that is safe to log `.public`: short, and
/// made only of the characters a shape or a code-defined word uses
/// (`native`, `1920x1080`, `810x1080+555+0`, `decoderBehind`). Anything else
/// reads `?`. A page can post to any message handler it can see, so a string
/// arriving from one is page-supplied until shown otherwise.
enum RAVELogToken {
    static func vet(_ value: Any?) -> String {
        guard let string = value as? String, !string.isEmpty, string.count <= 40,
              string.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "?" }
        return string
    }

    private static let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-._:x")
}

extension Error {
    /// `domain#code`, public-safe: the part of an error that diagnoses it in
    /// an export, where its `localizedDescription` (which can carry a URL or a
    /// server's words) is withheld.
    var raveLogCode: String {
        let error = self as NSError
        return "\(error.domain)#\(error.code)"
    }
}
