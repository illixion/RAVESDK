//
//  RAVEPageModel.swift
//  RAVEBrowser
//
//  What `RAVEPageDriver` reports about a page, as plain Codable values: the
//  scripts return JSON strings and these decode them, so nothing here needs
//  WebKit and the whole file builds on every platform, tvOS included.
//
//  The shapes are aimed at a language model as much as at code. An element's
//  `ref` is how a model names it back ("click 12"), and `outline()` is the
//  text form a model reads alongside a marked snapshot.
//

import Foundation
import CoreGraphics

/// The visible part of the page, in CSS pixels.
public struct RAVEPageViewport: Codable, Sendable, Equatable {
    public var width: Double
    public var height: Double
    public var scrollX: Double
    public var scrollY: Double
    public var scrollWidth: Double
    public var scrollHeight: Double
}

public struct RAVEPageInfo: Codable, Sendable, Equatable {
    public var title: String
    public var url: String
    public var readyState: String
    /// `document.visibilityState`: "hidden" is WebKit's own verdict that
    /// nobody can see the page, which is when it throttles timers and stops
    /// animation frames.
    public var visibility: String?
    public var viewport: RAVEPageViewport
    /// Filled in by the driver: whether the main frame is still loading.
    public var isLoading: Bool?
}

/// One thing on the page a user could click or type into.
public struct RAVEPageElement: Codable, Sendable, Equatable {
    /// Valid until the next `elements` call or navigation.
    public var ref: Int
    /// ARIA role, explicit or implied by the tag: link, button, textbox…
    public var role: String
    /// Accessible name, whitespace-collapsed and capped at 100 characters.
    public var name: String
    public var tag: String
    public var href: String?
    public var value: String?
    public var checked: Bool?
    public var disabled: Bool?
    /// Box in viewport CSS pixels at the time of the call.
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public var frame: CGRect { CGRect(x: x, y: y, width: w, height: h) }

    /// `[12] link "Top post" → https://…`, one line per element.
    public var outlineLine: String {
        var line = "[\(ref)] \(role)"
        if !name.isEmpty { line += " \"\(name)\"" }
        if let value, !value.isEmpty { line += " = \"\(value)\"" }
        if checked == true { line += " (checked)" }
        if disabled == true { line += " (disabled)" }
        if let href, !href.isEmpty, !href.hasPrefix("javascript:") {
            line += " → " + (href.count > 100 ? String(href.prefix(99)) + "…" : href)
        }
        return line
    }
}

public struct RAVEPageElements: Codable, Sendable, Equatable {
    public var viewport: RAVEPageViewport
    public var elements: [RAVEPageElement]
    /// How many qualified before `limit` cut the list.
    public var total: Int
    public var truncated: Bool

    public func element(_ ref: Int) -> RAVEPageElement? { elements.first { $0.ref == ref } }

    /// The list as a model reads it: where the viewport is, then one line
    /// per element in reading order.
    public func outline() -> String {
        let v = viewport
        var lines = ["Viewport \(Int(v.width))×\(Int(v.height)) at y=\(Int(v.scrollY)) of \(Int(v.scrollHeight))"]
        lines += elements.map(\.outlineLine)
        if truncated { lines.append("(\(total - elements.count) more not listed)") }
        return lines.joined(separator: "\n")
    }
}

/// A page's text, through Readability when it finds an article and the
/// page's rendered text otherwise.
public struct RAVEPageReading: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable {
        /// Readability decided whether there is an article.
        case auto
        /// Readability's article, which ignores whatever overlays the page.
        case reader
        /// `document.body.innerText`: what is rendered, overlays included.
        case page
    }

    public var mode: Mode
    public var title: String
    public var byline: String?
    public var excerpt: String?
    public var siteName: String?
    public var url: String
    public var lang: String?
    /// Characters before truncation.
    public var length: Int
    public var truncated: Bool
    /// Paragraphs split by blank lines; headings as `#`, list items as `- `.
    public var text: String
}

/// What a click or a typing action hit, and the page after it settled.
public struct RAVEPageAction: Codable, Sendable, Equatable {
    /// The element acted on, as `role "name"`.
    public var target: String
    /// Set when the action went through a link's URL instead of a click —
    /// a new-window link, which a web view with no UI delegate would drop.
    public var followed: String?
    public var info: RAVEPageInfo?
}

public struct RAVEPageScroll: Codable, Sendable, Equatable {
    public var moved: Bool
    /// Whether an inner element scrolled rather than the document.
    public var inner: Bool
    public var scrollY: Double
    public var scrollHeight: Double
    public var clientHeight: Double
    public var atTop: Bool
    public var atBottom: Bool
}

public struct RAVEPageFind: Codable, Sendable, Equatable {
    public var count: Int
    /// The match scrolled into view, or -1 when there are none.
    public var index: Int
    /// Up to ten matches with some text either side.
    public var snippets: [String]
}

public struct RAVEPageOverlays: Codable, Sendable, Equatable {
    /// What was hidden, as `tag.class "text…"`.
    public var hidden: [String]
    /// Whether `overflow: hidden` or a fixed-position body lock was undone.
    public var unlockedScroll: Bool
    /// The button pressed to decline a consent layer, if one offered it.
    public var declined: String?
}

public extension Encodable {
    /// The value as a JSON object, for a debug server's or a tool call's
    /// dictionary-shaped response.
    func raveJSONObject() -> Any {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [:] as [String: Any] }
        return object
    }
}
