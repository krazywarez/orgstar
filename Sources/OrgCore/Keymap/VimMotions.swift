import Foundation

extension Vim {
    // MARK: - Motions

    enum MotionKind { case exclusive, inclusive, linewise }

    enum MotionResult {
        case incomplete
        case invalid
        case moved(Int, MotionKind)
    }

    mutating func motion(_ keys: [KeyChord], _ buffer: inout Buffer, _ caret: inout Int, count n: Int, operatorPending: Bool) -> MotionResult {
        guard let key = keys.first else { return .incomplete }
        let c = caret
        func column(_ position: Int) -> Int { position - buffer.lineStart(position) }
        switch (key.key, key.modifiers) {
        case ("h", []), ("<left>", []), ("DEL", []):
            goalColumn = nil
            return .moved(max(buffer.lineStart(c), c - n), .exclusive)
        case ("l", []), ("<right>", []), ("SPC", []):
            goalColumn = nil
            let end = buffer.lineEnd(c)
            let limit = operatorPending ? end : max(buffer.lineStart(c), end - 1)
            return .moved(min(limit, c + n), .exclusive)
        case ("j", []), ("k", []), ("<down>", []), ("<up>", []), ("d", [.control]), ("u", [.control]), ("+", []), ("-", []), ("RET", []):
            let down = ["j", "<down>", "+", "RET"].contains(key.key) || key == KeyChord("d", .control)
            let lines = key.modifiers.contains(.control) ? (n == 1 ? contextHalfPage : n) : n
            let goal = goalColumn ?? column(c)
            var line = buffer.lineStart(c)
            var moved = 0
            for _ in 0..<lines {
                if down {
                    let end = buffer.lineEnd(line)
                    guard end < buffer.length, end + 1 <= buffer.length else { break }
                    if end + 1 == buffer.length { break }
                    line = end + 1
                } else {
                    guard line > 0 else { break }
                    line = buffer.lineStart(line - 1)
                }
                moved += 1
            }
            if moved == 0, !key.modifiers.contains(.control) { return .invalid }
            if ["+", "-", "RET"].contains(key.key) { return .moved(buffer.firstNonBlank(line), .linewise) }
            goalColumn = goal
            let length = buffer.lineEnd(line) - line
            return .moved(line + min(goal, operatorPending ? length : max(0, length - 1)), .linewise)
        case ("w", []), ("W", []):
            goalColumn = nil
            var p = c
            for _ in 0..<n { p = buffer.wordForward(p, bigWord: key.key == "W") }
            return .moved(p, .exclusive)
        case ("b", []), ("B", []):
            goalColumn = nil
            var p = c
            for _ in 0..<n { p = buffer.wordBackward(p, bigWord: key.key == "B", stopAtLine: false) }
            return .moved(p, .exclusive)
        case ("e", []), ("E", []):
            goalColumn = nil
            var p = c
            for _ in 0..<n { p = buffer.wordEnd(p, bigWord: key.key == "E", fromInside: false) }
            return .moved(p, .inclusive)
        case ("0", []), ("<home>", []):
            goalColumn = nil
            return .moved(buffer.lineStart(c), .exclusive)
        case ("^", []):
            goalColumn = nil
            return .moved(buffer.firstNonBlank(buffer.lineStart(c)), .exclusive)
        case ("$", []), ("<end>", []):
            var line = buffer.lineStart(c)
            for _ in 1..<max(1, n) where buffer.lineEnd(line) < buffer.length { line = buffer.lineEnd(line) + 1 }
            goalColumn = Int.max
            let end = buffer.lineEnd(line)
            if mode == .visual { return .moved(end, .inclusive) }
            return .moved(max(line, end - 1), .inclusive)
        case ("G", []):
            // `evil-start-of-line` nil: the column stays.
            let line = n > 1 || keys.count > 1 ? buffer.lineOffset(n) : buffer.lineStart(buffer.length)
            let column = c - buffer.lineStart(c)
            let length = buffer.lineEnd(line) - line
            return .moved(line + min(column, operatorPending ? length : max(0, length - 1)), .linewise)
        case ("g", []):
            guard keys.count >= 2 else { return .incomplete }
            switch keys[1].key {
            case "g":
                let line = buffer.lineOffset(n)
                let column = c - buffer.lineStart(c)
                let length = buffer.lineEnd(line) - line
                return .moved(line + min(column, operatorPending ? length : max(0, length - 1)), .linewise)
            case "e", "E":
                var p = c
                for _ in 0..<n { p = buffer.wordEndBackward(p, bigWord: keys[1].key == "E") }
                return .moved(p, .inclusive)
            case "j" where contextOrg, "k" where contextOrg:
                // evil-org: org-forward-element and org-backward-element, which take no count.
                guard let p = Self.orgObject(keys[1].key, inner: false, buffer, c)?.range.lowerBound, p != c else { return .invalid }
                goalColumn = nil
                return .moved(p, .exclusive)
            case "j":
                return motion([KeyChord("j")], &buffer, &caret, count: n, operatorPending: operatorPending)
            case "k":
                return motion([KeyChord("k")], &buffer, &caret, count: n, operatorPending: operatorPending)
            case "_":
                let end = buffer.lineEnd(c)
                var p = end
                while p > buffer.lineStart(c), let ch = buffer.char(p - 1), Buffer.isBlank(ch) { p -= 1 }
                return .moved(max(buffer.lineStart(c), p - 1), .inclusive)
            default:
                return .invalid
            }
        case ("f", []), ("F", []), ("t", []), ("T", []):
            // evil-snipe-override-mode: one-character snipes.
            guard keys.count >= 2 else { return .incomplete }
            let char = keys[1].key == "SPC" ? " " : keys[1].key == "TAB" ? "\t" : keys[1].key
            guard char.count == 1 else { return .invalid }
            let forward = key.key == "f" || key.key == "t"
            lastSnipe = (forward, char, n, key.key == "f" || key.key == "F", (KeyChord(key.key.lowercased()), KeyChord(key.key.uppercased())))
            return snipe(forward: forward, count: n, buffer, c, operatorPending: operatorPending, repeating: false)
        case (";", []), (",", []):
            // evil-snipe-repeat, with Doom's `evil-snipe-repeat-scope` visible.
            guard let last = lastSnipe else { return .invalid }
            let forward = key.key == ";" ? last.forward : !last.forward
            return snipe(forward: forward, count: n * last.count, buffer, c, operatorPending: operatorPending, repeating: true)
        case ("s", []) where !operatorPending, ("S", []) where !operatorPending:
            guard keys.count >= 3 else { return .incomplete }
            let chars = keys[1...2].map { $0.key == "SPC" ? " " : $0.key == "TAB" ? "\t" : $0.key }.joined()
            lastSnipe = (key.key == "s", chars, n, true, (KeyChord("s"), KeyChord("S")))
            return snipe(forward: key.key == "s", count: n, buffer, c, operatorPending: operatorPending, repeating: false)
        case ("%", []):
            guard let p = buffer.matchingBracket(c) else { return .invalid }
            return .moved(p, .inclusive)
        case ("'", []), ("`", []):
            guard keys.count >= 2 else { return .incomplete }
            let name = keys[1].key == "'" || keys[1].key == "`" ? Character("'") : keys[1].key.first
            guard let name, let mark = currentMarks[name] else { return .invalid }
            goalColumn = nil
            let p = min(mark, buffer.length)
            return key.key == "'" ? .moved(buffer.firstNonBlank(buffer.lineStart(p)), .linewise) : .moved(p, .exclusive)
        case ("}", []), ("{", []):
            var p = c
            for _ in 0..<n { p = buffer.paragraph(p, forward: key.key == "}") }
            return .moved(p, .exclusive)
        case ("n", []), ("N", []):
            guard let search = lastSearch else { return .invalid }
            let forward = key.key == "n" ? search.forward : !search.forward
            guard let p = buffer.search(search.pattern, from: c, forward: forward, count: n) else { return .invalid }
            return .moved(p, .exclusive)
        case ("*", []), ("#", []):
            guard let word = buffer.wordAt(c) else { return .invalid }
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
            lastSearch = (pattern, key.key == "*")
            guard let p = buffer.search(pattern, from: buffer.wordStart(c), forward: key.key == "*", count: n) else { return .invalid }
            return .moved(p, .exclusive)
        case ("H", []), ("M", []), ("L", []):
            // The visible lines: H the count-th from the top, L from the bottom, M the middle.
            guard let visible = contextVisible else { return .invalid }
            goalColumn = nil
            let lower = min(visible.lowerBound, buffer.length)
            let last = buffer.lineStart(max(lower, min(visible.upperBound, buffer.length) - 1))
            var lines: [Int] = []
            var line = buffer.lineStart(lower)
            while true {
                lines.append(line)
                guard line < last, buffer.lineEnd(line) < buffer.length else { break }
                line = buffer.lineEnd(line) + 1
            }
            let index = key.key == "H" ? min(n, lines.count) - 1 : key.key == "L" ? max(0, lines.count - n) : (lines.count - 1) / 2
            return .moved(buffer.firstNonBlank(lines[index]), .linewise)
        default:
            return .invalid
        }
    }

    /// `evil-snipe--seek` for the last snipe: the `n`th match from `c` in the line after (or
    /// before) the search start, or for a repeat in the visible text, with smart case,
    /// Doom's `evil-snipe-char-fold` and `evil-snipe-skip-leading-whitespace`.
    mutating func snipe(forward: Bool, count n: Int, _ buffer: Buffer, _ c: Int, operatorPending: Bool, repeating: Bool) -> MotionResult {
        guard let last = lastSnipe else { return .invalid }
        // f, s and F search from the next or this character, t and T one further.
        let start = forward ? c + (last.consume ? 1 : 2) : c - (last.consume ? 0 : 1)
        guard start >= 0, start <= buffer.length else { return .invalid }
        var bound = forward ? buffer.lineEnd(start) : buffer.lineStart(start)
        if repeating, let visible = contextVisible {
            bound = forward ? min(visible.upperBound, buffer.length) - 1 : min(visible.lowerBound, start)
        }
        let blankKeys = last.chars.first == " " || last.chars.first == "\t"
        let regexps = last.chars.map(CharFold.regexp)
        var pattern = regexps.map(CharFold.icu).joined()
        if blankKeys, let ch = buffer.char(start), Buffer.isBlank(ch) { pattern += "[^ \t]" }
        // `evil-snipe--case-p`: case matters when the regexps hold a capital letter.
        let caseFold = !regexps.joined().unicodeScalars.contains { ("A"..."Z").contains($0) }
        let regex = try! NSRegularExpression(pattern: pattern, options: caseFold ? .caseInsensitive : [])
        var match: NSRange?
        if forward, start <= bound {
            var from = start
            for _ in 0..<n {
                match = regex.firstMatch(in: buffer.ns as String, range: NSRange(location: from, length: bound - from))?.range
                guard let found = match else { break }
                from = NSMaxRange(found)
            }
        } else if !forward {
            var from = start
            for _ in 0..<n {
                match = nil
                var p = from - 1
                while p >= bound, match == nil {
                    match = regex.firstMatch(in: buffer.ns as String, options: .anchored, range: NSRange(location: p, length: from - p))?.range
                    p -= 1
                }
                guard let found = match else { break }
                from = found.location
            }
        }
        guard let found = match else {
            if repeating { snipeRepeatKeys = last.keys }
            return .invalid
        }
        if !operatorPending { snipeRepeatKeys = last.keys }
        var end = NSMaxRange(found)
        var length = found.length
        if blankKeys {
            end -= 1
            length -= 1
        }
        let visual = mode == .visual || mode == .visualLine || mode == .visualBlock
        var p: Int
        if !forward {
            p = last.consume ? found.location : end
        } else {
            p = visual ? (last.consume ? end : found.location) : operatorPending ? end : found.location
            if last.consume {
                if visual { p -= 1 }
            } else {
                p -= length
                if length > 1, !operatorPending { p += 1 }
            }
        }
        return .moved(p, .exclusive)
    }

    // MARK: - Text objects

    func textObject(_ inner: Bool, _ key: KeyChord, _ buffer: Buffer, _ c: Int, count: Int) -> (range: Range<Int>, linewise: Bool)? {
        switch key.key {
        case "w", "W":
            return buffer.wordObject(c, inner: inner, bigWord: key.key == "W", count: count).map { ($0, false) }
        case "\"", "'", "`":
            return buffer.quoteObject(c, quote: key.key.utf16.first!, inner: inner).map { ($0, false) }
        case "(", ")", "b":
            return buffer.bracketObject(c, open: 40, close: 41, inner: inner).map { ($0, false) }
        case "[", "]":
            return buffer.bracketObject(c, open: 91, close: 93, inner: inner).map { ($0, false) }
        case "{", "}", "B":
            return buffer.bracketObject(c, open: 123, close: 125, inner: inner).map { ($0, false) }
        case "<", ">":
            return buffer.bracketObject(c, open: 60, close: 62, inner: inner).map { ($0, false) }
        case "p":
            return buffer.paragraphObject(c, inner: inner).map { ($0, true) }
        case "e", "E", "r", "R":
            return Self.orgObject(key.key, inner: inner, buffer, c)
        default:
            return nil
        }
    }
}
