//
//  RAVEConsentLog.swift
//  RAVEConsent
//
//  The subsystem stays `Bundle.main.bundleIdentifier`, as in `RAVEBrowserLog`.
//  Only what this code decided is `.public`: the kind's id and the decision.
//  Destinations carry a host, so they are hashed; a title, detail or preview
//  is never logged at all.
//

import DebugTrace
import Foundation

enum RAVEConsentLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.illixion.raveconsent"

    static let consent = DebugLogger(subsystem: subsystem, category: "consent")
}
