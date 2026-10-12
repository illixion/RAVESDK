/*
 RAVERoboFrame - server URLs

 The WebSocket URL and every HTTP route a client fetches from, built from one
 server address. The access token rides in the query (`?token=`), so these
 URLs are secrets: log them through RAVENet's endpoint redaction, never whole.
 */

import Foundation

public struct RoboFrameEndpoint: Hashable, Sendable {
    /// The server's HTTP base, e.g. `http://servo:3123`.
    public var baseURL: URL
    public var accessToken: String
    /// Sent as `deviceId` on `/get` so `/history` files the request under this display.
    public var deviceId: String

    public init(baseURL: URL, accessToken: String = "", deviceId: String = "") {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.deviceId = deviceId
    }

    /// From a server address as a person types it: a bare `host:port` means https.
    public init?(server: String, accessToken: String = "", deviceId: String = "") {
        let value = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let url = URL(string: value.contains("://") ? value : "https://\(value)"),
              url.host != nil else { return nil }
        self.init(baseURL: url, accessToken: accessToken, deviceId: deviceId)
    }

    /// From a kiosk's configured WebSocket URL (`ws://host:3123/rpc/ws`): the
    /// HTTP base is the same host with the `/rpc/ws` suffix dropped.
    public init?(webSocketURL: URL, accessToken: String = "", deviceId: String = "") {
        guard var components = URLComponents(url: webSocketURL, resolvingAgainstBaseURL: false),
              components.host != nil else { return nil }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        var path = components.path
        if path.hasSuffix("/rpc/ws") { path.removeLast("/rpc/ws".count) }
        components.path = path
        components.query = nil
        guard let base = components.url else { return nil }
        self.init(baseURL: base, accessToken: accessToken, deviceId: deviceId)
    }

    /// `ws(s)://host/…/rpc/ws?token=…`.
    public var webSocketURL: URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.host != nil else { return nil }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        let base = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + (base.isEmpty ? "rpc/ws" : "\(base)/rpc/ws")
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        components.queryItems = token.isEmpty ? nil : [URLQueryItem(name: "token", value: token)]
        return components.url
    }

    /// `/get` for one post. See `RoboFrameMediaOptions` for the variants.
    public func mediaURL(postID: Int, options: RoboFrameMediaOptions = RoboFrameMediaOptions()) -> URL? {
        url(path: "get", items: [URLQueryItem(name: "id", value: String(postID))] + options.queryItems)
    }

    /// Any other route (`save`, `addtohistory`, `history.json`), with the
    /// post id when it takes one, and the deviceId and token.
    public func url(path: String, postID: Int? = nil) -> URL? {
        url(path: path, items: postID.map { [URLQueryItem(name: "id", value: String($0))] } ?? [])
    }

    private func url(path: String, items: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = items
        if !deviceId.isEmpty { items.append(URLQueryItem(name: "deviceId", value: deviceId)) }
        if !accessToken.isEmpty { items.append(URLQueryItem(name: "token", value: accessToken)) }
        components.queryItems = items
        return components.url
    }
}

/// `/get`'s variant parameters. Their values must match the session's
/// `slideshowConfig`, or the server pre-converts the wrong variant.
public struct RoboFrameMediaOptions: Hashable, Sendable {
    /// Count this fetch as a view in `/history` (`record=1`).
    public var record: Bool
    /// Fit-inside downscale; nil fetches at source resolution.
    public var width: Int?
    public var height: Int?
    /// JPEG output for stills, H.264 mp4 for animated posts.
    public var convert: Bool
    /// Re-encode non-JXL sources too, for decoder-poor kiosks.
    public var lowmem: Bool
    /// Dim to the night-light level.
    public var bright: Bool
    /// Animated posts as GIF (the PSP).
    public var gif: Bool
    /// A video post's transcode: `h264` (a progressive mp4) or `hls`.
    public var vcodec: String?
    /// Caps for the H.264 output; 0 keeps the source's.
    public var videoMaxHeight: Int?
    public var videoMaxFPS: Int?
    /// The untouched source, for a client that decodes animated formats itself.
    public var rawAnimated: Bool

    public init(
        record: Bool = false,
        width: Int? = nil,
        height: Int? = nil,
        convert: Bool = false,
        lowmem: Bool = false,
        bright: Bool = false,
        gif: Bool = false,
        vcodec: String? = nil,
        videoMaxHeight: Int? = nil,
        videoMaxFPS: Int? = nil,
        rawAnimated: Bool = false
    ) {
        self.record = record
        self.width = width
        self.height = height
        self.convert = convert
        self.lowmem = lowmem
        self.bright = bright
        self.gif = gif
        self.vcodec = vcodec
        self.videoMaxHeight = videoMaxHeight
        self.videoMaxFPS = videoMaxFPS
        self.rawAnimated = rawAnimated
    }

    var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "record", value: record ? "1" : "0")]
        func flag(_ name: String, _ on: Bool) { if on { items.append(URLQueryItem(name: name, value: "1")) } }
        func number(_ name: String, _ value: Int?) { if let value { items.append(URLQueryItem(name: name, value: String(value))) } }
        number("width", width)
        number("height", height)
        flag("convert", convert)
        flag("lowmem", lowmem)
        flag("bright", bright)
        flag("gif", gif)
        if let vcodec { items.append(URLQueryItem(name: "vcodec", value: vcodec)) }
        number("vmaxh", videoMaxHeight)
        number("vmaxfps", videoMaxFPS)
        flag("rawanimated", rawAnimated)
        return items
    }
}
