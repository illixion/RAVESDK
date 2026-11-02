#if canImport(WebKit)
import Foundation
import Testing
import WebKit
@testable import RAVEBrowser

/// An exception is a pin: one address, one certificate. These are the rules
/// that keep "accept this router" from becoming "accept whatever answers here".
@MainActor
@Suite("Certificate exceptions")
struct RAVECertificateTrustTests {
    private func problem(host: String = "172.20.48.130", port: Int = 443, fingerprint: String = "aa") -> RAVECertificateProblem {
        RAVECertificateProblem(host: host, port: port, fingerprint: fingerprint, reason: "self-signed")
    }

    @Test func fingerprintIsSHA256OfTheDERInLowercaseHex() {
        // The FIPS 180 test vector for "abc".
        let hex = RAVECertificateProblem.fingerprint(of: Data("abc".utf8))
        #expect(hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func nothingIsTrustedUntilItIsGranted() {
        #expect(RAVECertificateExceptions().isTrusted(problem()) == false)
    }

    @Test func aGrantCoversThatCertificateAtThatAddress() {
        let exceptions = RAVECertificateExceptions()
        exceptions.trust(problem())

        #expect(exceptions.isTrusted(problem()))
        // Host case is not a different host.
        #expect(exceptions.isTrusted(problem(host: "NAS.Local")) == false)
        exceptions.trust(problem(host: "NAS.Local", fingerprint: "bb"))
        #expect(exceptions.isTrusted(problem(host: "nas.local", fingerprint: "bb")))
    }

    @Test func aChangedCertificateFailsAgain() {
        let exceptions = RAVECertificateExceptions()
        exceptions.trust(problem(fingerprint: "aa"))

        #expect(exceptions.isTrusted(problem(fingerprint: "cc")) == false)
    }

    @Test func aGrantDoesNotCoverAnotherPort() {
        let exceptions = RAVECertificateExceptions()
        exceptions.trust(problem(port: 443))

        #expect(exceptions.isTrusted(problem(port: 8443)) == false)
    }

    @Test func forgettingRevokesEverything() {
        let exceptions = RAVECertificateExceptions()
        exceptions.trust(problem())
        exceptions.forgetAll()

        #expect(exceptions.isTrusted(problem()) == false)
    }

    @Test func aTabWithNoExceptionsReportsNoUntrustedCertificate() {
        let tab = RAVEBrowserTab(dataStore: .nonPersistent())
        #expect(tab.certificateExceptions == nil)
        #expect(tab.untrustedCertificate == nil)
    }

    /// The Swift 6 near-miss this project has been bitten by three times: a
    /// completion handler typed without the SDK's attributes compiles, warns
    /// somewhere nobody reads, and is never called. A tab that cannot be told
    /// about a certificate would silently refuse every pin.
    @Test func theDelegateReallyImplementsTheChallengeMethod() {
        let delegate = RAVEBrowserTab.Delegate()
        let selector = NSSelectorFromString("webView:didReceiveAuthenticationChallenge:completionHandler:")
        #expect(delegate.responds(to: selector))
    }
}
#endif
