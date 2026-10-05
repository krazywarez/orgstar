/// One key press in Emacs notation: `C-x`, `M-<`, `S-<left>`, `s-s`, `TAB`.
///
/// `C` is Control, `M` Meta, `S` Shift, `s` Super (⌘). Shift on a letter is folded into the
/// letter (`S-a` is `A`); on other keys it stays a modifier (`S-TAB`, `S-<up>`).
public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let meta = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    /// A single character, a named key (`TAB`, `RET`, `SPC`, `ESC`, `DEL`), or a bracketed
    /// function key (`<left>`, `<f5>`, `<delete>`).
    public let key: String
    public let modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers = []) {
        var key = Self.aliases[key] ?? key
        var modifiers = modifiers
        if key == "<backtab>" {
            key = "TAB"
            modifiers.insert(.shift)
        }
        if modifiers.contains(.shift), key.count == 1, let letter = key.first, letter.isLetter, letter.isLowercase {
            key = key.uppercased()
            modifiers.remove(.shift)
        }
        self.key = key
        self.modifiers = modifiers
    }

    static let named: Set<String> = ["TAB", "RET", "SPC", "ESC", "DEL"]
    static let aliases = [
        " ": "SPC", "<tab>": "TAB", "<return>": "RET", "<escape>": "ESC", "<backspace>": "DEL",
    ]

    /// Parses one token such as `C-M-x`; nil if it isn't a key.
    public static func parse<S: StringProtocol>(_ token: S) -> KeyChord? {
        var rest = Substring(token)
        var modifiers: Modifiers = []
        while rest.count >= 3, rest.dropFirst().first == "-" {
            switch rest.first {
            case "C": modifiers.insert(.control)
            case "M": modifiers.insert(.meta)
            case "S": modifiers.insert(.shift)
            case "s": modifiers.insert(.command)
            default: return nil
            }
            rest = rest.dropFirst(2)
        }
        let key = String(rest)
        let isFunctionKey = key.count > 2 && key.hasPrefix("<") && key.hasSuffix(">")
        guard key.count == 1 || named.contains(key) || isFunctionKey || aliases[key] != nil else { return nil }
        return KeyChord(key, modifiers)
    }

    public var description: String {
        var text = ""
        if modifiers.contains(.control) { text += "C-" }
        if modifiers.contains(.meta) { text += "M-" }
        if modifiers.contains(.shift) { text += "S-" }
        if modifiers.contains(.command) { text += "s-" }
        return text + key
    }
}

public enum KeySequence {
    /// Parses space-separated chords: `C-c C-x C-i`. Nil if any token isn't a key.
    public static func parse(_ text: String) -> [KeyChord]? {
        let tokens = text.split(separator: " ")
        guard !tokens.isEmpty else { return nil }
        var chords: [KeyChord] = []
        for token in tokens {
            guard let chord = KeyChord.parse(token) else { return nil }
            chords.append(chord)
        }
        return chords
    }

    public static func format(_ keys: [KeyChord]) -> String {
        keys.map(\.description).joined(separator: " ")
    }
}
