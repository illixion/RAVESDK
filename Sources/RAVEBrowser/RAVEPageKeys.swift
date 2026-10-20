//
//  RAVEPageKeys.swift
//  RAVEBrowser
//
//  Key presses as a model writes them (`Enter`, `Shift+Tab`, `Meta+a`,
//  `ArrowDown ArrowDown Enter`) turned into what each input path needs: the
//  DOM's `key`/`code`/`keyCode` for synthetic events, and a Mac virtual key
//  code plus characters for a real `NSEvent`. Foundation only, so it builds
//  and is tested everywhere.
//
//  The character table is the US layout's. A key whose character is not on
//  it still works as text (it is typed, not pressed); only its key code is
//  unknown, which nothing but a site reading `code` would notice.
//

import Foundation

public struct RAVEPageModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = RAVEPageModifiers(rawValue: 1)
    public static let control = RAVEPageModifiers(rawValue: 2)
    /// Alt on other platforms.
    public static let option = RAVEPageModifiers(rawValue: 4)
    /// Meta, Command.
    public static let command = RAVEPageModifiers(rawValue: 8)

    /// From names a model writes: `shift`, `ctrl`/`control`, `alt`/`option`,
    /// `meta`/`cmd`/`command`. Unknown names are an error, not ignored.
    public static func parse(_ names: [String]) throws -> RAVEPageModifiers {
        var modifiers: RAVEPageModifiers = []
        for name in names {
            guard let modifier = byName[name.lowercased()] else {
                throw RAVEPageKeyError("unknown modifier '\(name)': use shift, control, option (alt) or command (meta)")
            }
            modifiers.insert(modifier)
        }
        return modifiers
    }

    static let byName: [String: RAVEPageModifiers] = [
        "shift": .shift, "ctrl": .control, "control": .control, "alt": .option, "option": .option,
        "opt": .option, "meta": .command, "cmd": .command, "command": .command,
    ]
}

public struct RAVEPageKeyError: Error, LocalizedError, Equatable {
    public let message: String
    init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// One key press, with the modifiers held for it.
public struct RAVEPageKeyChord: Sendable, Equatable {
    /// DOM `KeyboardEvent.key`: `Enter`, `a`, `A`, `ArrowDown`.
    public var key: String
    /// DOM `KeyboardEvent.code`: `Enter`, `KeyA`, `ArrowDown`.
    public var code: String
    /// The legacy `keyCode`/`which` many sites still read.
    public var keyCode: Int
    public var modifiers: RAVEPageModifiers
    /// What the press types, if anything: a printable key with no modifier
    /// but Shift.
    public var text: String?
    /// The Mac virtual key code (`kVK_…`), or nil for a character that is not
    /// on the US layout.
    public var macKeyCode: UInt16?
    /// `NSEvent.characters` for this press: the text, or the function-key
    /// character AppKit uses for a key that types nothing.
    public var macCharacters: String

    /// `a` → KeyA, `Shift+Tab`, `Meta+a`, `Space`, `F5`. A single character
    /// stands for itself, so `A` is Shift+a and `?` is Shift+/.
    public static func parse(_ text: String) throws -> RAVEPageKeyChord {
        // `+` separates; a trailing `+` (`Shift++`) is the plus key.
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("+"), parts.count >= 2 {
            parts.removeLast(2)
            parts.append("+")
        }
        guard let last = parts.last, !last.isEmpty else {
            throw RAVEPageKeyError("empty key in '\(text)'")
        }
        var modifiers = try RAVEPageModifiers.parse(Array(parts.dropLast()))
        if let named = named[last.lowercased()] {
            return RAVEPageKeyChord(key: named.key, code: named.code, keyCode: named.keyCode, modifiers: modifiers,
                                    text: named.text.flatMap { modifiers.subtracting(.shift).isEmpty ? $0 : nil },
                                    macKeyCode: named.mac, macCharacters: named.characters)
        }
        guard last.count == 1, let character = last.first else {
            throw RAVEPageKeyError("unknown key '\(last)': use a single character or a name such as Enter, Tab, "
                                   + "Escape, Backspace, Delete, Space, ArrowUp, Home, PageDown or F5")
        }
        var typed = String(character)
        if let base = shifted[character] {
            modifiers.insert(.shift)
            let info = characterInfo(base)
            return RAVEPageKeyChord(key: typed, code: info.code, keyCode: info.keyCode, modifiers: modifiers,
                                    text: modifiers.subtracting(.shift).isEmpty ? typed : nil,
                                    macKeyCode: info.mac, macCharacters: typed)
        }
        if character.isUppercase, character.isLetter {
            modifiers.insert(.shift)
        }
        let info = characterInfo(Character(character.lowercased()))
        // With Shift, a letter types its capital, whichever way it was written.
        if modifiers.contains(.shift), character.isLetter { typed = character.uppercased() }
        return RAVEPageKeyChord(key: typed, code: info.code, keyCode: info.keyCode, modifiers: modifiers,
                                text: modifiers.subtracting(.shift).isEmpty ? typed : nil,
                                macKeyCode: info.mac, macCharacters: typed)
    }

    /// Space-separated presses: `ArrowDown ArrowDown Enter`.
    public static func parseSequence(_ text: String) throws -> [RAVEPageKeyChord] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { throw RAVEPageKeyError("no keys given: pass e.g. \"Enter\" or \"Shift+Tab\"") }
        return try words.map(parse)
    }

    /// The press as `{key, code, keyCode, shift, ctrl, alt, meta, text}`, for
    /// the synthetic-event script.
    var scriptValue: [String: Any] {
        [
            "key": key, "code": code, "keyCode": keyCode, "text": text.map { $0 as Any } ?? NSNull(),
            "shift": modifiers.contains(.shift), "ctrl": modifiers.contains(.control),
            "alt": modifiers.contains(.option), "meta": modifiers.contains(.command),
        ]
    }

    // MARK: - Tables

    private struct Named {
        let key: String
        let code: String
        let keyCode: Int
        let mac: UInt16
        let characters: String
        let text: String?
    }

    /// AppKit's function-key characters (`NSUpArrowFunctionKey` and friends),
    /// spelled out so this file needs no AppKit.
    private static func function(_ value: Int) -> String { String(UnicodeScalar(UInt32(value)).map(Character.init) ?? " ") }

    private static let named: [String: Named] = {
        var table: [String: Named] = [
            "enter": Named(key: "Enter", code: "Enter", keyCode: 13, mac: 36, characters: "\r", text: nil),
            "tab": Named(key: "Tab", code: "Tab", keyCode: 9, mac: 48, characters: "\t", text: nil),
            "escape": Named(key: "Escape", code: "Escape", keyCode: 27, mac: 53, characters: "\u{1b}", text: nil),
            "backspace": Named(key: "Backspace", code: "Backspace", keyCode: 8, mac: 51, characters: "\u{7f}", text: nil),
            "delete": Named(key: "Delete", code: "Delete", keyCode: 46, mac: 117, characters: function(0xF728), text: nil),
            "space": Named(key: " ", code: "Space", keyCode: 32, mac: 49, characters: " ", text: " "),
            "arrowup": Named(key: "ArrowUp", code: "ArrowUp", keyCode: 38, mac: 126, characters: function(0xF700), text: nil),
            "arrowdown": Named(key: "ArrowDown", code: "ArrowDown", keyCode: 40, mac: 125, characters: function(0xF701), text: nil),
            "arrowleft": Named(key: "ArrowLeft", code: "ArrowLeft", keyCode: 37, mac: 123, characters: function(0xF702), text: nil),
            "arrowright": Named(key: "ArrowRight", code: "ArrowRight", keyCode: 39, mac: 124, characters: function(0xF703), text: nil),
            "home": Named(key: "Home", code: "Home", keyCode: 36, mac: 115, characters: function(0xF729), text: nil),
            "end": Named(key: "End", code: "End", keyCode: 35, mac: 119, characters: function(0xF72B), text: nil),
            "pageup": Named(key: "PageUp", code: "PageUp", keyCode: 33, mac: 116, characters: function(0xF72C), text: nil),
            "pagedown": Named(key: "PageDown", code: "PageDown", keyCode: 34, mac: 121, characters: function(0xF72D), text: nil),
            "plus": Named(key: "+", code: "Equal", keyCode: 187, mac: 24, characters: "+", text: "+"),
        ]
        let macFunctionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (index, mac) in macFunctionKeys.enumerated() {
            let n = index + 1
            table["f\(n)"] = Named(key: "F\(n)", code: "F\(n)", keyCode: 111 + n, mac: mac,
                                   characters: function(0xF704 + index), text: nil)
        }
        for (alias, name) in ["return": "enter", "esc": "escape", "up": "arrowup", "down": "arrowdown",
                              "left": "arrowleft", "right": "arrowright", "del": "delete", "pgup": "pageup",
                              "pgdn": "pagedown"] {
            table[alias] = table[name]
        }
        return table
    }()

    /// Shifted characters on the US layout and the key under each.
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
        "~": "`",
    ]

    private static func characterInfo(_ character: Character) -> (code: String, keyCode: Int, mac: UInt16?) {
        if let letter = character.unicodeScalars.first, character.isASCII, character.isLetter {
            let upper = Character(character.uppercased())
            return ("Key\(upper)", Int(upper.asciiValue ?? 0), macLetters[Character(String(letter))])
        }
        if character.isASCII, let digit = character.wholeNumberValue {
            return ("Digit\(digit)", 48 + digit, macDigits[digit])
        }
        if let punctuation = punctuation[character] { return punctuation }
        return ("", 0, nil)
    }

    private static let macLetters: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
        "k": 40, "n": 45, "m": 46,
    ]

    private static let macDigits: [Int: UInt16] = [1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28, 9: 25, 0: 29]

    private static let punctuation: [Character: (code: String, keyCode: Int, mac: UInt16?)] = [
        "-": ("Minus", 189, 27), "=": ("Equal", 187, 24), "[": ("BracketLeft", 219, 33),
        "]": ("BracketRight", 221, 30), "\\": ("Backslash", 220, 42), ";": ("Semicolon", 186, 41),
        "'": ("Quote", 222, 39), ",": ("Comma", 188, 43), ".": ("Period", 190, 47), "/": ("Slash", 191, 44),
        "`": ("Backquote", 192, 50), " ": ("Space", 32, 49),
    ]
}
