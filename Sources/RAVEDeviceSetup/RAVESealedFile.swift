/*
 RAVEDeviceSetup - a file sealed under five words, for AirDrop, Files and any other channel
 nobody vouches for

 The QR route (`RAVESetupReceiver`) needs two devices that can see each other on the local
 network. A file works between two apps on one device, from a Mac to a headset in a message,
 or from a backup folder months later. The same scheme as Apparition's `.apparitionkey`:

 - The sending device makes five words from the EFF's short wordlist (`RAVESealedWords`,
   about 51.7 bits) and shows them. They never go into the file.
 - Argon2id (64 MiB, four passes, about a second on a phone) turns the words into a key, and
   ChaCha20-Poly1305 seals the payload with it.
 - The header (who sealed it, the cost settings, the salt and nonce) is the associated data,
   so it can't be changed without the file refusing to open. Only `from` is readable without
   the words, so the receiver can say whose file it is.
 - The words are read back however they were typed or dictated: any case, any separators,
   each word known by its first three letters.

 The app names its kind of file in `format` ("hypnos-setup-sealed"); a file of another format
 is refused before anything is derived. What is inside is the app's: any `Data`.

 The cost settings travel in the file, so a later version can raise them. A file asking for
 more than this one would ever choose (256 MiB, 16 passes) is refused, so a crafted file
 can't tie the device up.
 */

import CRAVEArgon2
import CryptoKit
import Foundation

public enum RAVESealedFile {
    /// Words in the passphrase.
    public static let wordCount = 5

    /// A sealed file and the words that open it.
    public struct Sealed: Sendable {
        public let file: Data
        /// Five words separated by spaces, to show on the sending device.
        public let words: String
    }

    public enum Failure: Error, LocalizedError, Equatable, Sendable {
        case notASealedFile(format: String)
        case newerVersion
        case unsupportedSettings
        case damaged
        case wordCount(Int)
        case unknownWord(String)
        case wrongWords(from: String)
        case couldntSeal

        public var errorDescription: String? {
            switch self {
            case .notASealedFile(let format): "This isn't a \(format) file."
            case .newerVersion: "This file was made by a newer version of the app. Update this one and try again."
            case .unsupportedSettings: "This file asks for key settings this app doesn't use."
            case .damaged: "This file is damaged."
            case .wordCount: "Type all \(RAVESealedFile.wordCount) words, as the other device shows them."
            case .unknownWord(let word): "\"\(word)\" isn't one of the words used here; check it against the other device."
            case .wrongWords(let from): "Those words don't open this file: check them against \(from)."
            case .couldntSeal: "Couldn't seal the file."
            }
        }
    }

    // MARK: - Settings

    static let version = 1
    static let kdfName = "argon2id"
    static let cipherName = "chacha20-poly1305"
    static let memoryKiB: UInt32 = 64 * 1024
    static let iterations: UInt32 = 4
    static let maxMemoryKiB: UInt32 = 256 * 1024
    static let maxIterations: UInt32 = 16

    // MARK: - The file

    struct File: Codable {
        var format: String
        var version: Int
        var from: String
        var kdf: String
        var memoryKiB: UInt32
        var iterations: UInt32
        var parallelism: UInt32
        var salt: String
        var cipher: String
        var nonce: String
        var sealed: String

        /// Everything but the sealed bytes, as the exact text both sides authenticate. One line
        /// per field in a fixed order, so no JSON library's key order or spacing can matter.
        var authenticatedHeader: Data {
            Data(["rave-sealed-file", format, String(version), from, kdf, String(memoryKiB), String(iterations),
                  String(parallelism), salt, cipher, nonce].joined(separator: "\n").utf8)
        }
    }

    // MARK: - Sealing

    /// Seals `plain` under five new words.
    public static func seal(_ plain: Data, format: String, from: String) async throws -> Sealed {
        var generator = SystemRandomNumberGenerator()
        let words = (0..<wordCount).map { _ in RAVESealedWords.list.randomElement(using: &generator)! }.joined(separator: " ")
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let nonce = Data((0..<12).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return try await seal(plain, format: format, from: from, words: words, salt: salt, nonce: nonce,
                              memoryKiB: memoryKiB, iterations: iterations)
    }

    /// The same with everything chosen by the caller, for a known-answer test.
    static func seal(_ plain: Data, format: String, from: String, words: String, salt: Data, nonce: Data,
                     memoryKiB: UInt32, iterations: UInt32) async throws -> Sealed {
        var file = File(format: format, version: version, from: from, kdf: kdfName, memoryKiB: memoryKiB,
                        iterations: iterations, parallelism: 1, salt: salt.base64EncodedString(), cipher: cipherName,
                        nonce: nonce.base64EncodedString(), sealed: "")
        let key = try await deriveKey(words: words, salt: salt, memoryKiB: memoryKiB, iterations: iterations)
        guard let chachaNonce = try? ChaChaPoly.Nonce(data: nonce),
              let box = try? ChaChaPoly.seal(plain, using: key, nonce: chachaNonce, authenticating: file.authenticatedHeader)
        else { throw Failure.couldntSeal }
        file.sealed = (box.ciphertext + box.tag).base64EncodedString()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return Sealed(file: try encoder.encode(file), words: words)
    }

    // MARK: - Opening

    /// Who sealed `file`, if it is a sealed file of `format` (readable without the words).
    public static func sender(of file: Data, format: String) -> String? {
        guard let decoded = try? JSONDecoder().decode(File.self, from: file), decoded.format == format else { return nil }
        return decoded.from
    }

    /// The payload inside `file`, opened with the words as typed. Wrong words throw
    /// `Failure.wrongWords` and change nothing.
    public static func open(_ file: Data, format: String, words typed: String) async throws -> Data {
        guard let decoded = try? JSONDecoder().decode(File.self, from: file) else {
            throw Failure.notASealedFile(format: format)
        }
        guard decoded.format == format else { throw Failure.notASealedFile(format: format) }
        guard decoded.version == version else { throw Failure.newerVersion }
        guard decoded.kdf == kdfName, decoded.cipher == cipherName,
              decoded.memoryKiB >= 8, decoded.memoryKiB <= maxMemoryKiB,
              decoded.iterations >= 1, decoded.iterations <= maxIterations,
              decoded.parallelism == 1
        else { throw Failure.unsupportedSettings }
        let words = try canonicalWords(typed)
        guard let salt = Data(base64Encoded: decoded.salt), !salt.isEmpty,
              let nonceBytes = Data(base64Encoded: decoded.nonce),
              let nonce = try? ChaChaPoly.Nonce(data: nonceBytes),
              let sealed = Data(base64Encoded: decoded.sealed), sealed.count >= 16
        else { throw Failure.damaged }
        let key = try await deriveKey(words: words, salt: salt, memoryKiB: decoded.memoryKiB, iterations: decoded.iterations)
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        do {
            return try ChaChaPoly.open(box, using: key, authenticating: decoded.authenticatedHeader)
        } catch {
            throw Failure.wrongWords(from: decoded.from)
        }
    }

    // MARK: - The words

    /// The words as the sealer chose them, from however they were typed or dictated: any case,
    /// any separators, each word known by its first three letters (so a typo after them, or an
    /// autocorrected ending, doesn't matter).
    public static func canonicalWords(_ typed: String) throws -> String {
        let tokens = typed.split(whereSeparator: { !$0.isLetter }).map { $0.lowercased() }
        guard tokens.count == wordCount else { throw Failure.wordCount(tokens.count) }
        return try tokens.map { token in
            let prefix = String(token.prefix(3))
            guard prefix.count == 3, let word = RAVESealedWords.list.first(where: { $0.hasPrefix(prefix) }) else {
                throw Failure.unknownWord(token)
            }
            return word
        }.joined(separator: " ")
    }

    // MARK: - Argon2id

    /// Blocks for about a second, so it runs off the caller's actor.
    static func deriveKey(words: String, salt: Data, memoryKiB: UInt32, iterations: UInt32) async throws -> SymmetricKey {
        try await Task.detached(priority: .userInitiated) {
            guard let work = malloc(Int(memoryKiB) * 1024) else { throw Failure.couldntSeal }
            defer { free(work) }
            var hash = [UInt8](repeating: 0, count: 32)
            let pass = Array(words.utf8)
            let saltBytes = [UInt8](salt)
            pass.withUnsafeBufferPointer { passBuffer in
                saltBytes.withUnsafeBufferPointer { saltBuffer in
                    let config = crypto_argon2_config(algorithm: UInt32(CRYPTO_ARGON2_ID), nb_blocks: memoryKiB,
                                                      nb_passes: iterations, nb_lanes: 1)
                    let inputs = crypto_argon2_inputs(pass: passBuffer.baseAddress, salt: saltBuffer.baseAddress,
                                                      pass_size: UInt32(passBuffer.count), salt_size: UInt32(saltBuffer.count))
                    crypto_argon2(&hash, 32, work, config, inputs, crypto_argon2_no_extras)
                }
            }
            defer { hash.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
            return SymmetricKey(data: hash)
        }.value
    }
}
