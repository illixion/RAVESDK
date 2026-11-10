//
//  RAVESupportStore.swift
//  RAVESupport
//
//  Remembers what the person has already been shown, so each card appears at
//  most once per app: the welcome sheet on first use, and one "Enjoying this
//  app?" nudge once `nudgeDelay` (24 hours) has passed since that first use.
//  Kept in UserDefaults under per-app keys; the defaults and the clock are
//  injectable so tests never touch the real ones or wait a day.
//

import Foundation

public struct RAVESupportStore {
    /// How long after first use the nudge becomes due.
    public static let nudgeDelay: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults
    private let welcomeKey: String
    private let firstUseKey: String
    private let nudgeKey: String
    private let now: () -> Date

    public init(appID: String, defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        self.welcomeKey = "rave.support.welcomeShown.\(appID)"
        self.firstUseKey = "rave.support.firstUse.\(appID)"
        self.nudgeKey = "rave.support.nudgeShown.\(appID)"
    }

    /// True once the welcome card has been shown (answered or dismissed).
    public var welcomeShown: Bool { defaults.bool(forKey: welcomeKey) }

    /// True once the nudge has been shown. It never comes back.
    public var nudgeShown: Bool { defaults.bool(forKey: nudgeKey) }

    /// When the welcome card was first shown; nil before that.
    public var firstUse: Date? {
        defaults.object(forKey: firstUseKey) == nil ? nil : Date(timeIntervalSince1970: defaults.double(forKey: firstUseKey))
    }

    public func markWelcomeShown() {
        defaults.set(true, forKey: welcomeKey)
        if firstUse == nil { defaults.set(now().timeIntervalSince1970, forKey: firstUseKey) }
    }

    public func markNudgeShown() { defaults.set(true, forKey: nudgeKey) }

    /// True when the nudge should show now: the welcome was shown at least `nudgeDelay` ago and the
    /// nudge has not been shown. A welcome recorded without a date (the flag set by an older build
    /// or a UI test) starts its clock now rather than counting as long ago.
    public func nudgeDue() -> Bool {
        guard welcomeShown, !nudgeShown else { return false }
        guard let first = firstUse else {
            defaults.set(now().timeIntervalSince1970, forKey: firstUseKey)
            return false
        }
        return now().timeIntervalSince(first) >= Self.nudgeDelay
    }

    /// For a "show it again" debug action and for tests.
    public func reset() {
        for k in [welcomeKey, firstUseKey, nudgeKey] { defaults.removeObject(forKey: k) }
    }
}
