/*
 RAVEMedia - URL redaction for logs.

 Media URLs routinely carry credentials in the query string (Spatial Stash's
 Stash server takes an `apikey` there; the web-yt-dlp proxy takes a `token`).
 Those URLs have to be logged at `privacy: .public`, because `.private`
 interpolation renders as `<private>` in Console and made media-load failures
 undiagnosable on device — so the redaction has to happen before the string
 reaches os_log, not be delegated to the privacy annotation.

 This is the package's copy of what Spatial Stash's `URL.loggableDescription`
 does. It is deliberately a denylist of parameter *names* rather than an
 attempt to detect secret-shaped values: a name that isn't listed is a fixable
 omission, whereas a heuristic that misses one silently publishes a credential.
 */

import Foundation

extension URL {
    /// Query values whose names look like credentials, replaced with a
    /// placeholder. Add to this list rather than logging a raw URL.
    private static let redactedQueryNames: Set<String> = ["apikey", "api_key", "token", "access_token", "key", "password", "secret"]

    /// URL string safe to log at `privacy: .public`.
    var redactedForLogging: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              var items = components.queryItems, !items.isEmpty else {
            return absoluteString
        }
        for index in items.indices
        where Self.redactedQueryNames.contains(items[index].name.lowercased()) {
            items[index].value = "REDACTED"
        }
        components.queryItems = items
        return components.url?.absoluteString ?? absoluteString
    }
}
