import Foundation
@testable import RAVEDeviceSetup
import Testing

/// `fixture` was made by a different implementation (Python's `cryptography`: Argon2id and
/// ChaCha20-Poly1305), with the cost turned down so a test stays quick. If it opens here, the
/// two agree on the key derivation, the cipher and the authenticated header.
private let fixture = Data("""
{"cipher": "chacha20-poly1305", "format": "test-sealed", "from": "Test on Ixion's Vision Pro", "iterations": 2, \
"kdf": "argon2id", "memoryKiB": 256, "nonce": "FRYXGBkaGxwdHh8g", "parallelism": 1, \
"salt": "AQIDBAUGBwgJCgsMDQ4PEA==", "sealed": "S4ByRok9EZdE8vZSVBDZ3P93JbyRjp0F86mbhwWU5RXq", "version": 1}
""".utf8)
private let fixtureWords = "aardvark computer lemon tiger zucchini"
private let fixturePlain = Data(#"{"hello":"world"}"#.utf8)

@Suite struct RAVESealedFileTests {
    @Test func openingAFileAnotherImplementationSealed() async throws {
        let plain = try await RAVESealedFile.open(fixture, format: "test-sealed", words: fixtureWords)
        #expect(plain == fixturePlain)
    }

    @Test func sealingWithTheSameInputsGivesTheSameBytes() async throws {
        let sealed = try await RAVESealedFile.seal(
            fixturePlain, format: "test-sealed", from: "Test on Ixion's Vision Pro", words: fixtureWords,
            salt: Data(1...16), nonce: Data(21...32), memoryKiB: 256, iterations: 2)
        let mine = try JSONDecoder().decode(RAVESealedFile.File.self, from: sealed.file)
        let theirs = try JSONDecoder().decode(RAVESealedFile.File.self, from: fixture)
        #expect(mine.sealed == theirs.sealed)
        #expect(mine.authenticatedHeader == theirs.authenticatedHeader)
    }

    @Test func theWordsMayBeTypedAnyWay() async throws {
        for typed in ["Aardvark, Computer; LEMON tiger   zucchini",
                      "aar com lem tig zuc",
                      "aardvarkzzz computerish lemonade tigerlily zucchinis",
                      "aardvark\ncomputer\nlemon\ntiger\nzucchini"] {
            let plain = try await RAVESealedFile.open(fixture, format: "test-sealed", words: typed)
            #expect(plain == fixturePlain, "\(typed)")
        }
    }

    @Test func aRoundTripAtTheShippedCost() async throws {
        let secret = Data(#"{"jellyfin":{"server":"https://example.test","apiKey":"k"}}"#.utf8)
        let sealed = try await RAVESealedFile.seal(secret, format: "test-sealed", from: "Test")
        #expect(sealed.words.split(separator: " ").count == RAVESealedFile.wordCount)
        #expect(!String(decoding: sealed.file, as: UTF8.self).contains("example.test"), "the payload must not appear in the file")
        for word in sealed.words.split(separator: " ") {
            #expect(!String(decoding: sealed.file, as: UTF8.self).contains(word), "the words must not appear in the file")
        }
        #expect(RAVESealedFile.sender(of: sealed.file, format: "test-sealed") == "Test")
        let opened = try await RAVESealedFile.open(sealed.file, format: "test-sealed", words: sealed.words)
        #expect(opened == secret)
    }

    @Test func eachSealingUsesNewWordsAndSalt() async throws {
        let first = try await RAVESealedFile.seal(fixturePlain, format: "test-sealed", from: "Test")
        let second = try await RAVESealedFile.seal(fixturePlain, format: "test-sealed", from: "Test")
        #expect(first.words != second.words)
        #expect(first.file != second.file)
    }

    @Test func wrongWordsOpenNothing() async throws {
        await #expect(throws: RAVESealedFile.Failure.wrongWords(from: "Test on Ixion's Vision Pro")) {
            _ = try await RAVESealedFile.open(fixture, format: "test-sealed", words: "aardvark computer lemon tiger walrus")
        }
    }

    @Test func aChangedHeaderIsRefused() async throws {
        var file = try JSONDecoder().decode(RAVESealedFile.File.self, from: fixture)
        file.from = "Somebody else"
        let tampered = try JSONEncoder().encode(file)
        await #expect(throws: RAVESealedFile.Failure.wrongWords(from: "Somebody else")) {
            _ = try await RAVESealedFile.open(tampered, format: "test-sealed", words: fixtureWords)
        }
    }

    @Test func aChangedSealedByteIsRefused() async throws {
        var file = try JSONDecoder().decode(RAVESealedFile.File.self, from: fixture)
        var bytes = try #require(Data(base64Encoded: file.sealed))
        bytes[0] ^= 1
        file.sealed = bytes.base64EncodedString()
        let tampered = try JSONEncoder().encode(file)
        await #expect(throws: RAVESealedFile.Failure.wrongWords(from: "Test on Ixion's Vision Pro")) {
            _ = try await RAVESealedFile.open(tampered, format: "test-sealed", words: fixtureWords)
        }
    }

    @Test func aFileAskingForTooMuchIsRefusedBeforeAnythingIsDerived() async throws {
        var file = try JSONDecoder().decode(RAVESealedFile.File.self, from: fixture)
        file.memoryKiB = 1024 * 1024
        let greedy = try JSONEncoder().encode(file)
        await #expect(throws: RAVESealedFile.Failure.unsupportedSettings) {
            _ = try await RAVESealedFile.open(greedy, format: "test-sealed", words: fixtureWords)
        }
        file.memoryKiB = 256
        file.iterations = 1000
        let slow = try JSONEncoder().encode(file)
        await #expect(throws: RAVESealedFile.Failure.unsupportedSettings) {
            _ = try await RAVESealedFile.open(slow, format: "test-sealed", words: fixtureWords)
        }
    }

    @Test func anotherKindOfFileIsRefused() async throws {
        #expect(RAVESealedFile.sender(of: fixture, format: "other-sealed") == nil)
        await #expect(throws: RAVESealedFile.Failure.notASealedFile(format: "other-sealed")) {
            _ = try await RAVESealedFile.open(fixture, format: "other-sealed", words: fixtureWords)
        }
        await #expect(throws: RAVESealedFile.Failure.notASealedFile(format: "test-sealed")) {
            _ = try await RAVESealedFile.open(Data("not json".utf8), format: "test-sealed", words: fixtureWords)
        }
    }

    @Test func theWordsAreChecked() throws {
        #expect(throws: RAVESealedFile.Failure.wordCount(4)) { _ = try RAVESealedFile.canonicalWords("aardvark computer lemon tiger") }
        #expect(throws: RAVESealedFile.Failure.wordCount(6)) { _ = try RAVESealedFile.canonicalWords("a b c d e f") }
        #expect(throws: RAVESealedFile.Failure.unknownWord("qqqqq")) { _ = try RAVESealedFile.canonicalWords("aardvark computer lemon tiger qqqqq") }
        #expect(throws: RAVESealedFile.Failure.unknownWord("ab")) { _ = try RAVESealedFile.canonicalWords("aardvark computer lemon tiger ab") }
    }

    @Test func theWordListIsTheEFFShortListWithoutYoYo() {
        let list = RAVESealedWords.list
        #expect(list.count == 1295)
        #expect(Set(list.map { $0.prefix(3) }).count == list.count, "every word is known by its first three letters")
        #expect(list.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isLowercase } })
    }
}
