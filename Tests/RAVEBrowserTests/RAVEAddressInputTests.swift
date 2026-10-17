import Foundation
import Testing
@testable import RAVEBrowser

/// The address bar has to guess between "go here" and "search for this" from
/// one text field, and both wrong answers are visible to the user immediately.
/// It also happens to be the app's one text-to-URL boundary, so it is where a
/// `javascript:` URL would get in if it could.
@Suite("Address input")
struct AddressInputTests {
    /// A fixed template, independent of any app's settings — these
    /// tests exercise `resolve`'s own logic, not whatever the live setting
    /// happens to be, and must stay hermetic across runs.
    private let testTemplate = "https://duckduckgo.com/?q="

    private func resolved(_ text: String) -> String? {
        RAVEAddressInput.resolve(text, searchTemplate: testTemplate)?.absoluteString
    }

    private func isSearch(_ text: String) -> Bool {
        resolved(text)?.hasPrefix(testTemplate) ?? false
    }

    // MARK: - Navigating

    @Test(arguments: [
        "https://example.com",
        "http://example.com/path?q=1",
        "about:blank",
    ])
    func explicitNavigableSchemesGoStraightThrough(text: String) {
        #expect(resolved(text) == text)
    }

    @Test(arguments: [
        "example.com",
        "sub.example.co.uk",
        "example.com/path",
        "example.com/a?b=c#d",
    ])
    func bareHostnamesGetHTTPS(text: String) {
        #expect(resolved(text) == "https://" + text)
    }

    /// The case that makes naive scheme-detection fail: the colon is a port
    /// separator, not a scheme separator.
    @Test func hostWithPortIsNotMistakenForAScheme() {
        #expect(resolved("example.com:8080") == "https://example.com:8080")
        #expect(resolved("192.168.1.1:8123/admin") == "https://192.168.1.1:8123/admin")
    }

    /// A dotless host that is still a real destination. Without the allowlist
    /// this fails the hostname test and gets searched for.
    @Test func localhostNavigatesDespiteHavingNoDot() {
        #expect(resolved("localhost") == "https://localhost")
    }

    /// A dotless hostname is perfectly scheme-shaped, so `localhost:8080` reads
    /// as scheme `localhost` unless what follows the colon is checked too. This
    /// caught the bug; the port rule is what fixes it, and it generalises to
    /// any LAN name.
    @Test(arguments: ["localhost:8080", "dev-box:3000", "nas:5000/ui"])
    func dotlessHostWithPortIsNotMistakenForAScheme(text: String) {
        #expect(resolved(text) == "https://" + text)
    }

    @Test func ipv4LiteralsNavigate() {
        #expect(resolved("192.168.1.1") == "https://192.168.1.1")
    }

    // MARK: - Searching

    @Test(arguments: [
        "swift package manager",
        "what is a vision pro",
        "example.com and other things",
    ])
    func phrasesWithSpacesSearch(text: String) {
        #expect(isSearch(text))
    }

    /// Dots do not make a URL. Three-label prose with a numeric last label is
    /// not a hostname, and neither is a version number.
    @Test(arguments: ["hello", "1.2.3", "192.168.1", "a.1"])
    func dottedNonHostnamesSearch(text: String) {
        #expect(isSearch(text), "\(text) should search, got \(resolved(text) ?? "nil")")
    }

    /// The security boundary. These are the schemes an address bar gets used to
    /// attack someone with, and none of them is something a person types on
    /// purpose — so they are treated as text, never navigated.
    @Test(arguments: [
        "javascript:alert(1)",
        "data:text/html,<script>alert(1)</script>",
        "file:///etc/passwd",
        "JavaScript:alert(1)",
    ])
    func dangerousSchemesAreSearchedForRatherThanNavigated(text: String) {
        let result = resolved(text)
        #expect(isSearch(text), "\(text) must not navigate, got \(result ?? "nil")")
        // Belt and braces: whatever came back is an https search URL, so it
        // cannot execute in the page's context however it is used.
        #expect(result?.hasPrefix("https://") == true)
    }

    @Test func emptyAndWhitespaceResolveToNothing() {
        #expect(RAVEAddressInput.resolve("", searchTemplate: testTemplate) == nil)
        #expect(RAVEAddressInput.resolve("   \n ", searchTemplate: testTemplate) == nil)
    }

    @Test func surroundingWhitespaceIsTrimmedNotTreatedAsAPhrase() {
        #expect(resolved("  example.com  ") == "https://example.com")
    }

    // MARK: - Display

    @Test func displayTextDropsSchemeAndWWWButKeepsWhatChangesWhereYouAre() {
        #expect(RAVEAddressInput.displayText(for: URL(string: "https://www.example.com/")!) == "example.com")
        #expect(RAVEAddressInput.displayText(for: URL(string: "https://example.com/path")!) == "example.com/path")
        // A non-default port and a query change the destination — keep them.
        #expect(RAVEAddressInput.displayText(for: URL(string: "http://example.com:8080/a?b=c")!) == "example.com:8080/a?b=c")
    }

    /// The trailing slash is dropped only for a bare host, where it is noise —
    /// not for a path, where it is part of the address.
    @Test func trailingSlashHandling() {
        #expect(RAVEAddressInput.displayText(for: URL(string: "https://example.com/")!) == "example.com")
        #expect(RAVEAddressInput.displayText(for: URL(string: "https://example.com/dir/")!) == "example.com/dir/")
    }
}
