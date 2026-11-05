//
//  RAVELauncherShortcut.swift
//  RAVELauncher
//
//  A tile another app asked the launcher to keep: a title, an icon and the
//  URL that opens it in that app (Raven's `raven://open?url=…` for a pinned
//  page). Lifted from Apparition's Home tab, where Raven's "Pin to Spatial
//  Home" first used it.
//
//  The stored JSON is Apparition's (`launcher.shortcuts.v1`), field for
//  field: the names below are a wire format already on devices, not style.
//

import Foundation
import ImageIO

public struct RAVELauncherShortcut: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    /// The app the request says the URL opens in. A claim: a custom URL
    /// cannot authenticate its sender, so screens present it as one.
    public var ownerBundleID: String
    public var title: String
    public var targetURL: String
    /// An https icon the requester named, used when it sent no image.
    public var iconURL: String?
    /// The image the requester sent, saved beside the store; see
    /// `RAVELauncherShortcutStore.iconFileURL(of:)`.
    public var iconFileName: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), ownerBundleID: String, title: String, targetURL: String,
                iconURL: String? = nil, iconFileName: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.ownerBundleID = ownerBundleID
        self.title = title
        self.targetURL = targetURL
        self.iconURL = iconURL
        self.iconFileName = iconFileName
        self.createdAt = createdAt
    }
}

/// An app's request to add a shortcut, parsed and bounded, waiting for the
/// person to approve it.
///
/// The request URL is `<launcher scheme>://launcher-shortcut?` with
/// `bundle-id`, `title`, `url`, and an icon as `icon` (https) and/or
/// `icon-data` (base64 PNG/JPEG, at most 128 KB and 1024 px a side).
/// At least one icon is required, so a tile never shows up as a bare letter
/// the person can't tell apart from another app's.
public struct RAVELauncherShortcutRequest: Identifiable, Sendable {
    public let id = UUID()
    public let ownerBundleID: String
    public let title: String
    public let targetURL: String
    public let iconURL: String?
    public let iconData: Data?

    public init(ownerBundleID: String, title: String, targetURL: String, iconURL: String?, iconData: Data?) {
        self.ownerBundleID = ownerBundleID
        self.title = title
        self.targetURL = targetURL
        self.iconURL = iconURL
        self.iconData = iconData
    }

    public static let host = "launcher-shortcut"

    /// Whether `url` is addressed to this launcher's shortcut route at all,
    /// valid or not; a launcher answers an invalid one with an error rather
    /// than passing it to its other URL handling.
    public static func isRequest(_ url: URL, scheme: String) -> Bool {
        url.scheme?.caseInsensitiveCompare(scheme) == .orderedSame
            && url.host?.caseInsensitiveCompare(host) == .orderedSame
    }

    /// The request in `url`, or nil when it is not one or breaks a bound.
    /// The target may not use the launcher's own scheme, which would let a
    /// tile drive the launcher itself (Apparition's JIT launch).
    public static func parse(_ url: URL, scheme: String) -> RAVELauncherShortcutRequest? {
        guard isRequest(url, scheme: scheme),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        func value(_ key: String) -> String? {
            items.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let owner = value("bundle-id"), owner.count <= 160,
              owner.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil,
              let title = value("title"), !title.isEmpty, title.count <= 120,
              let target = value("url"), target.count <= 2048,
              let normalizedTarget = RAVELaunchLink.validated(target, forbidding: [scheme])?.absoluteString
        else { return nil }

        var iconURL: String?
        if let rawIcon = value("icon") {
            guard let icon = URLComponents(string: rawIcon), icon.scheme?.lowercased() == "https",
                  icon.host != nil, rawIcon.count <= 2048 else { return nil }
            iconURL = icon.url?.absoluteString
        }

        var iconData: Data?
        if let encoded = value("icon-data") {
            guard encoded.count <= 180_000,
                  let data = Data(base64Encoded: encoded), data.count <= 128 * 1024,
                  validIcon(data) else { return nil }
            iconData = data
        }
        guard iconURL != nil || iconData != nil else { return nil }
        return RAVELauncherShortcutRequest(ownerBundleID: owner, title: title,
                                           targetURL: normalizedTarget, iconURL: iconURL, iconData: iconData)
    }

    /// The URL an app sends to ask `scheme`'s launcher for a shortcut.
    public static func url(scheme: String, ownerBundleID: String, title: String, targetURL: URL,
                           iconURL: URL? = nil, iconData: Data? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        var items = [URLQueryItem(name: "bundle-id", value: ownerBundleID),
                     URLQueryItem(name: "title", value: title),
                     URLQueryItem(name: "url", value: targetURL.absoluteString)]
        if let iconURL { items.append(URLQueryItem(name: "icon", value: iconURL.absoluteString)) }
        if let iconData { items.append(URLQueryItem(name: "icon-data", value: iconData.base64EncodedString())) }
        components.queryItems = items
        // `+` is legal in a query but decodes as a space in form encoding; base64 carries it.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    private static func validIcon(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...1024).contains(width), (1...1024).contains(height) else { return false }
        return true
    }
}

/// The rule for a link a tile may open: a well-formed URL with a scheme, never one that
/// reaches local files or runs script.
public enum RAVELaunchLink {
    public static let alwaysForbidden: Set<String> = ["file", "javascript", "data"]

    /// `string` as a URL a tile may open, or nil. `forbidding` adds schemes (lowercase) on
    /// top of `alwaysForbidden`.
    public static func validated(_ string: String, forbidding: Set<String> = []) -> URL? {
        let candidate = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme.range(of: "^[a-z][a-z0-9+.-]*$", options: .regularExpression) != nil,
              !alwaysForbidden.contains(scheme),
              !forbidding.map({ $0.lowercased() }).contains(scheme) else { return nil }
        return components.url
    }
}
