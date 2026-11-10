//
//  RAVESupportStore.swift
//  RAVESupport
//
//  Remembers whether the person has already been shown the welcome card, so it
//  appears once per app and never again. Kept in UserDefaults under a per-app
//  key; the defaults are injectable so tests never touch the real ones.
//

import Foundation

public struct RAVESupportStore {
    private let defaults: UserDefaults
    private let key: String

    public init(appID: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = "rave.support.welcomeShown.\(appID)"
    }

    /// True once the welcome card has been shown (answered or dismissed).
    public var welcomeShown: Bool { defaults.bool(forKey: key) }

    public func markWelcomeShown() { defaults.set(true, forKey: key) }

    /// For a "show it again" debug action and for tests.
    public func reset() { defaults.removeObject(forKey: key) }
}
