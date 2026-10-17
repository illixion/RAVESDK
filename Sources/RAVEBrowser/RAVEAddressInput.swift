/*
 RAVEBrowser — turning what the user typed into something to load.

 An address bar takes one text field and has to decide between "navigate here"
 and "search for this". Getting it wrong in either direction is annoying in a
 way users notice immediately: searching for `localhost:8080` because it has no
 scheme, or navigating to `swift package manager` because it has dots in it.

 The rules below are ordered so the cheap certain answers come first and the
 ambiguous case falls through to search, which is the recoverable mistake — a
 search results page for a typo'd host costs a click, while a navigation
 attempt at a search phrase costs a DNS failure page.

 **It is a security boundary**: the only text-to-URL conversion an address bar
 has, so it is where a `javascript:` or `data:` URL would get in. The scheme
 allowlist is `http`/`https`/`about`; everything else with a scheme is searched
 for, not navigated.

 Raven's `AddressInput`, lifted 2026-10-17. The search template is the app's
 (Raven keeps one per profile), so it is a parameter here, never a default.
 */

import Foundation

public enum RAVEAddressInput {
    /// Schemes we will hand to WebKit directly. Anything else typed with a
    /// scheme (`javascript:`, `data:`, `file:`) is treated as text: those are
    /// the schemes an address bar is used to attack someone with, and none of
    /// them is something a person types on purpose.
    private static let navigableSchemes: Set<String> = ["http", "https", "about"]

    /// Hosts with no dot that are still real destinations.
    private static let dotlessHosts: Set<String> = ["localhost"]

    /// A URL to load for what was typed, or nil for nothing (blank input).
    ///
    /// - Parameter searchTemplate: a URL prefix the percent-encoded text is
    ///   appended to, e.g. `https://duckduckgo.com/?q=`.
    public static func resolve(_ raw: String, searchTemplate: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 1. An explicit scheme decides it, one way or the other.
        if let scheme = explicitScheme(of: text) {
            guard navigableSchemes.contains(scheme) else { return search(for: text, template: searchTemplate) }
            return URL(string: text) ?? search(for: text, template: searchTemplate)
        }

        // 2. Whitespace inside means a phrase. No URL a user types by hand has
        // a raw space in it — a pasted one arrives percent-encoded.
        if text.contains(" ") { return search(for: text, template: searchTemplate) }

        // 3. A bare host[:port][/path]: `localhost:8080`, `example.com`,
        // `192.168.1.1/admin`. Judged on the authority component alone, so a
        // query string full of dots can't promote a phrase into a URL.
        let authority = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let parts = authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let hostname = String(parts.first ?? "")
        // An explicit port is itself strong evidence of a host — nobody types
        // `dev-box:3000` meaning to search for it — and it is the only thing
        // that rescues a dotless LAN name from the hostname test below.
        let hasPort = parts.count == 2 && !parts[1].isEmpty && parts[1].allSatisfy(\.isNumber)
        if !hostname.isEmpty,
           hasPort || dotlessHosts.contains(hostname.lowercased()) || looksLikeHostname(hostname),
           let url = URL(string: "https://" + text) {
            return url
        }

        return search(for: text, template: searchTemplate)
    }

    /// The scheme only if it is written as one. A colon is not enough: it is
    /// also the host/port separator, and both sides have to be checked to tell
    /// the two apart.
    ///
    /// - A dot before the colon means a host — `example.com:8080`.
    /// - Digits straight after the colon mean a port — `localhost:8080`,
    ///   `dev-box:3000`. This is the case that matters, because a dotless
    ///   hostname is otherwise perfectly scheme-shaped. No real scheme is
    ///   followed by a bare number (`http:` is followed by `//`).
    private static func explicitScheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let candidate = text[text.startIndex..<colon].lowercased()
        guard !candidate.isEmpty,
              candidate.first!.isLetter,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." })
        else { return nil }
        guard !candidate.contains(".") else { return nil }

        let rest = text[text.index(after: colon)...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !(!rest.isEmpty && rest.allSatisfy(\.isNumber)) else { return nil }

        return candidate
    }

    /// A dotted name whose last label is alphabetic (a TLD) or which is all
    /// digits and dots (an IPv4 literal). Deliberately not a full validator:
    /// this only has to separate "looks addressable" from "looks like prose",
    /// and prose that survives this is prose without spaces.
    private static func looksLikeHostname(_ hostname: String) -> Bool {
        let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return labels.count == 4 }
        guard let tld = labels.last else { return false }
        return tld.count >= 2 && tld.allSatisfy { $0.isLetter }
    }

    private static func search(for text: String, template: String) -> URL? {
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
        return URL(string: template + encoded)
    }

    /// What the address bar shows when it isn't focused: the URL minus the
    /// noise. Keeps a non-default port and any path, because those change where
    /// you are; drops the scheme and a leading `www.`, which don't.
    public static func displayText(for url: URL) -> String {
        var text = url.absoluteString
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
            break
        }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/"), text.dropLast().allSatisfy({ $0 != "/" }) { text.removeLast() }
        return text
    }
}
