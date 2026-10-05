/// Position and counts for the modeline, as Emacs computes them in an org buffer.
public enum TextStats {
    /// The line (from 1) and `current-column` (from 0, tabs to multiples of 8, wide
    /// characters two columns, control characters as `^X` or `\200`) at a UTF-16 offset.
    public static func position(in text: String, at offset: Int) -> (line: Int, column: Int) {
        let utf16 = text.utf16
        let end = utf16.index(utf16.startIndex, offsetBy: min(max(0, offset), utf16.count))
        var line = 1
        var lineStart = utf16.startIndex
        var index = utf16.startIndex
        while index < end {
            if utf16[index] == 10 {
                line += 1
                lineStart = utf16.index(after: index)
            }
            index = utf16.index(after: index)
        }
        var column = 0
        for character in text[lineStart..<end] {
            let v = character.unicodeScalars.first!.value
            if character == "\t" {
                column = (column / 8 + 1) * 8
            } else if v < 0x20 || v == 0x7F {
                column += 2  // ^X
            } else if (0x80...0x9F).contains(v) {
                column += 4  // \200
            } else {
                column += displayWidth(of: character)
            }
        }
        return (line, column)
    }

    /// `count-words`: runs of characters with word syntax in org-mode (`WordSyntax.swift`),
    /// split where `forward-word` sees a boundary between scripts.
    public static func words(in text: some StringProtocol) -> Int {
        var count = 0
        var previous: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            if isWord(scalar) {
                if let previous, !boundary(previous, scalar) {} else { count += 1 }
                previous = scalar
            } else {
                previous = nil
            }
        }
        return count
    }

    /// `word_boundary_p` with the default `word-combining-categories` and
    /// `word-separating-categories`.
    static func boundary(_ a: Unicode.Scalar, _ b: Unicode.Scalar) -> Bool {
        if script(a) == script(b) { return isHiragana(a) && isKatakana(b) }
        if isCombining(a) || isCombining(b) { return false }
        return !(isHan(a) && (isHiragana(b) || isKatakana(b)))
    }

    static func script(_ scalar: Unicode.Scalar) -> UInt16 {
        let v = scalar.value
        var low = 0
        var high = scripts.count
        while low < high {
            let mid = (low + high) / 2
            if scripts[mid].start <= v { low = mid + 1 } else { high = mid }
        }
        return scripts[low - 1].script
    }

    static func isCombining(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }

    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v) || (0x20000...0x3FFFF).contains(v)
    }

    static func isHiragana(_ scalar: Unicode.Scalar) -> Bool { (0x3040...0x309F).contains(scalar.value) }

    static func isKatakana(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x30A0...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v) || (0xFF65...0xFF9F).contains(v)
    }

    static func isWord(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        var low = 0
        var high = nonWord.count
        while low < high {
            let mid = (low + high) / 2
            if nonWord[mid].upperBound < v { low = mid + 1 } else { high = mid }
        }
        return low == nonWord.count || !nonWord[low].contains(v)
    }

    /// `count-words-region`: lines (a partial last line counts), words and characters.
    public static func region(_ text: some StringProtocol) -> (lines: Int, words: Int, characters: Int) {
        var lines = 0
        var characters = 0
        var last: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            characters += 1
            if scalar == "\n" { lines += 1 }
            last = scalar
        }
        if let last, last != "\n" { lines += 1 }
        return (lines, words(in: text), characters)
    }
}
