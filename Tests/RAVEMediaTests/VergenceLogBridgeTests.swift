import DebugTrace
import Testing
@testable import RAVEMedia

/// Vergence's lines must reach DebugTrace with each value's privacy intact,
/// never flattened to text a trace would export in the clear.
@Test func bridgedMessagesKeepPrivacyValueByValue() {
    let user = "someone@example.com", count = 4, key = "secret"
    let message: VergenceLogMessage = "user \(user) has \(count) items \(key, privacy: .sensitive) \(user, privacy: .private(mask: .hash))"
    let bridged = RAVEMediaLog.debugMessage(message)
    #expect(!bridged.isPublic)
    #expect(bridged.redacted.hasPrefix("user <private> has 4 items <private> <hash:"))
    #expect(!bridged.redacted.contains(user) && !bridged.redacted.contains(key))
    #expect(!bridged.revealed.contains(key))
    #expect(bridged.revealed.contains(user))
}
