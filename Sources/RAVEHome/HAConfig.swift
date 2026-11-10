/*
 RAVEHome - Home Assistant connection config

 Codable settings describing how to reach a Home Assistant instance. Persisting it
 (the token belongs in the Keychain) is the app's job. The access token is a long-lived access token
 created in the HA user profile; it is entered at runtime and never committed.
 */

import Foundation

public struct HAConfig: Codable, Equatable, Sendable {
    /// Base URL of the HA instance, e.g. "https://home.illixion.com".
    public var baseURL: String
    /// Long-lived access token from the HA user profile.
    public var accessToken: String

    public init(baseURL: String = "", accessToken: String = "") {
        self.baseURL = baseURL
        self.accessToken = accessToken
    }

    public var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedToken: String {
        accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isConfigured: Bool {
        !trimmedBaseURL.isEmpty && !trimmedToken.isEmpty
    }

    /// The WebSocket API endpoint: `wss://<host>/api/websocket`
    /// (http → ws, https → wss). Returns nil if the base URL is unusable.
    public var webSocketURL: URL? {
        var base = trimmedBaseURL
        guard !base.isEmpty else { return nil }
        // Strip a trailing slash so we don't double up on the path.
        while base.hasSuffix("/") { base.removeLast() }

        if base.hasPrefix("https://") {
            base = "wss://" + base.dropFirst("https://".count)
        } else if base.hasPrefix("http://") {
            base = "ws://" + base.dropFirst("http://".count)
        } else {
            // No scheme provided — assume TLS.
            base = "wss://" + base
        }
        return URL(string: base + "/api/websocket")
    }

    /// The REST base, normalized with a scheme and no trailing slash.
    public var restBaseURL: URL? {
        var base = trimmedBaseURL
        guard !base.isEmpty else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasPrefix("http://") && !base.hasPrefix("https://") {
            base = "https://" + base
        }
        return URL(string: base)
    }
}
