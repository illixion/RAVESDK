//
//  RAVEConsentTypes.swift
//  RAVEConsent
//
//  The vocabulary of "may this leave my hands?": what kind of data, where
//  it would go, and what exactly would be sent.
//

import CoreGraphics
import Foundation

/// A kind of personal data an app asks about, e.g. a screenshot, weigh-ins,
/// a body recording. Open on purpose: each app names its own as static
/// members, so the package never lists what an app may hold.
///
///     extension RAVEConsentKind {
///         static let screenshot = RAVEConsentKind("screenshot")
///     }
///
/// A grant is for one kind, so allowing screenshots says nothing about health data.
public struct RAVEConsentKind: Hashable, Sendable {
    /// Stable and short: what a grant is keyed by and what the logs and
    /// debug status show. Never put data in it.
    public let id: String

    public init(_ id: String) { self.id = id }
}

/// Where the data would go, as the person reads it and as a grant is keyed.
/// A grant is for one destination, so changing the backend asks again.
public struct RAVEConsentDestination: Hashable, Sendable {
    /// Stable across launches: the backend, plus the host for a server.
    public let key: String
    /// "To the on-device model. It stays on this Vision Pro."
    public let summary: String
    /// Whether the data leaves this device.
    public let leavesDevice: Bool

    public init(key: String, summary: String, leavesDevice: Bool) {
        self.key = key
        self.summary = summary
        self.leavesDevice = leavesDevice
    }

    // Identity is the key: a rewording of the summary is the same place.
    public static func == (a: Self, b: Self) -> Bool { a.key == b.key }
    public func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

/// What would be sent, shown to the person before they answer. Held in
/// memory for the prompt only: never logged, never in `status`.
public enum RAVEConsentPreview {
    case none
    /// The picture itself.
    case image(CGImage)
    /// The values or text itself, as a list of lines the person can read
    /// ("Weight 72.4 kg · 3 Oct"). Scrolls when long.
    case text(String)
}

public struct RAVEConsentRequest: Identifiable {
    public let id = UUID()
    public let kind: RAVEConsentKind
    public let destination: RAVEConsentDestination
    /// A question: "Show the character this screenshot?"
    public let title: String
    /// One or two sentences on what and why.
    public let detail: String
    public let preview: RAVEConsentPreview
    /// The verb on the buttons: "Send", "Share", "Save". The buttons read
    /// "Send", "Send for 15 Minutes" and "Don't Send".
    public let action: String
    /// Whether "for 15 Minutes" is offered. Off for what should be a fresh
    /// decision every time, like a recording of the person's body.
    public let offersGrant: Bool

    public init(kind: RAVEConsentKind, destination: RAVEConsentDestination, title: String, detail: String,
                preview: RAVEConsentPreview = .none, action: String = "Send", offersGrant: Bool = true) {
        self.kind = kind
        self.destination = destination
        self.title = title
        self.detail = detail
        self.preview = preview
        self.action = action
        self.offersGrant = offersGrant
    }
}

public enum RAVEConsentDecision: String, Sendable {
    /// This once.
    case once
    /// This and the same kind to the same place for the grant's duration.
    case forAWhile
    case deny
    /// A newer question took this one's place before it was answered. Not an
    /// answer: do nothing, the newer one decides.
    case superseded
    /// A live grant covered it; nobody was asked. Only `authorize` returns it.
    case granted

    public var allowed: Bool { self == .once || self == .forAWhile || self == .granted }
}

public struct RAVEConsentGrant: Equatable, Sendable {
    public let kind: RAVEConsentKind
    public let destination: RAVEConsentDestination
    public let until: Date
}
