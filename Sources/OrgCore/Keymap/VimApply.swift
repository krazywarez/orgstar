import Foundation

extension Vim {
    // MARK: - Applying

    func visualRange(_ buffer: Buffer, _ caret: Int) -> (range: Range<Int>, linewise: Bool) {
        let a = min(anchor, caret)
        let b = max(anchor, caret)
        if mode == .visualLine {
            let end = buffer.lineEnd(b)
            return (buffer.lineStart(a)..<min(buffer.length, end + 1), true)
        }
        return (a..<min(buffer.length, b + 1), false)
    }

    func visualActions(_ buffer: Buffer, _ caret: Int) -> [Action] {
        let a = min(anchor, caret)
        let b = max(anchor, caret)
        let range = mode == .visualLine ? buffer.lineStart(a)..<buffer.lineEnd(b) : a..<min(buffer.length, b + 1)
        return [.move(caret: caret), .select(range)]
    }

    mutating func store(_ text: String, linewise: Bool, register: Character?, yank: Bool) -> [Action] {
        if register == "_" { return [] }
        if let register, register.isLetter {
            let key = Character(register.lowercased())
            if register.isUppercase, let existing = registers[key] {
                registers[key] = (existing.text + text, existing.linewise || linewise)
            } else {
                registers[key] = (text, linewise)
            }
            return []
        }
        if yank { registers["0"] = (text, linewise) }
        clipboardRecord = (text, linewise)
        return [.setClipboard(text)]
    }

    func paste(_ register: Character?, _ context: Context) -> (String, Bool)? {
        if let register, register != "\"", register != "+", register != "*" {
            return registers[Character(register.lowercased())]
        }
        guard let clip = context.clipboard ?? clipboardRecord?.text else { return nil }
        if let record = clipboardRecord, record.text == clip { return (clip, record.linewise) }
        return (clip, false)
    }

    mutating func change(_ edits: [TextEdit], caret: Int, keys: [KeyChord]) -> [Action] {
        lastChange = (keys, nil)
        return [.edit(edits, caret: caret)]
    }

    mutating func apply(_ op: String, range: Range<Int>, linewise: Bool, _ buffer: Buffer, register: Character?, keys: [KeyChord], count: Int) -> [Action] {
        let wasVisual = mode == .visual || mode == .visualLine
        if wasVisual { lastVisual = (anchor, caretForApply, mode) }
        let context0Column = max(0, caretForApply - buffer.lineStart(caretForApply))
        mode = .normal
        let text = buffer.substring(range)
        switch op {
        case "y":
            var actions = store(text, linewise: linewise, register: register, yank: true)
            let caret = linewise && !wasVisual ? min(range.lowerBound, buffer.length) : range.lowerBound
            actions.append(.move(caret: linewise && wasVisual ? buffer.lineStart(range.lowerBound) : caret))
            return actions
        case "d":
            var actions = store(text, linewise: linewise, register: register, yank: false)
            var deletion = range
            if linewise, range.upperBound >= buffer.length, range.lowerBound > 0, buffer.char(range.upperBound - 1) != 10 || range.upperBound == buffer.length {
                // The last line takes the newline before it.
                if buffer.char(range.lowerBound - 1) == 10, range.upperBound == buffer.length, !(text.hasSuffix("\n")) {
                    deletion = (range.lowerBound - 1)..<range.upperBound
                }
            }
            let after = buffer.removing(deletion)
            var caret = deletion.lowerBound
            if linewise {
                let column = context0Column
                let line = after.lineStart(min(deletion.lowerBound, after.length))
                let length = after.lineEnd(line) - line
                caret = line + min(column, max(0, length - 1))
            } else {
                caret = after.clampNormal(caret)
            }
            lastChange = (wasVisual ? [] : keys, nil)
            actions.insert(.edit([TextEdit(range: deletion, replacement: "")], caret: caret), at: 0)
            return actions
        case "c":
            var actions = store(text, linewise: linewise, register: register, yank: false)
            var deletion = range
            var replacement = ""
            if linewise {
                // cc keeps the newline and indents as the line before it calls for.
                replacement = range.lowerBound == 0 ? "" : Self.indentation(for: buffer, line: range.lowerBound - 1)
                if buffer.char(range.upperBound - 1) == 10 { deletion = range.lowerBound..<(range.upperBound - 1) }
            }
            let caret = deletion.lowerBound + replacement.utf16.count
            actions.insert(.edit([TextEdit(range: deletion, replacement: replacement)], caret: caret), at: 0)
            enterInsert(at: caret, keys: wasVisual ? [] : keys)
            return actions
        case ">", "<":
            let start = buffer.lineStart(range.lowerBound)
            var edits: [TextEdit] = []
            var line = start
            let end = linewise ? range.upperBound : max(range.upperBound, buffer.lineEnd(max(range.lowerBound, range.upperBound - 1)))
            while line < end || (line == start && line <= buffer.length) {
                let lineEnd = buffer.lineEnd(line)
                if lineEnd > line {
                    if op == ">" {
                        edits.append(TextEdit(range: line..<line, replacement: String(repeating: " ", count: Self.shiftWidth)))
                    } else {
                        let indent = buffer.substring(line..<buffer.firstNonBlankOrEnd(line))
                        let remove = min(Self.shiftWidth, indent.count)
                        if remove > 0 { edits.append(TextEdit(range: line..<(line + remove), replacement: "")) }
                    }
                }
                guard lineEnd < buffer.length else { break }
                line = lineEnd + 1
                if line >= end { break }
            }
            lastChange = (wasVisual ? [] : keys, nil)
            return [.edit(edits, caret: start)]
        case "gc":
            lastChange = (wasVisual ? [] : keys, nil)
            return [.edit(Self.toggleComments(buffer, range), caret: buffer.lineStart(range.lowerBound))]
        case "gq", "gw":
            // Whole lines, as evil's fill operators take them.
            lastChange = (wasVisual ? [] : keys, nil)
            let end = buffer.lineEnd(max(range.lowerBound, range.upperBound - 1))
            let lines = buffer.lineStart(range.lowerBound)..<min(buffer.length, end + 1)
            return [.fill(lines, keep: op == "gw" ? caretForApply : nil)]
        default:
            let transformed: String
            switch op {
            case "gu": transformed = text.lowercased()
            case "gU": transformed = text.uppercased()
            default: transformed = String(text.map { $0.isUppercase ? Character($0.lowercased()) : Character($0.uppercased()) })
            }
            lastChange = (wasVisual ? [] : keys, nil)
            return [.edit([TextEdit(range: range, replacement: transformed)], caret: range.lowerBound)]
        }
    }

    mutating func enterInsert(_ key: String, _ buffer: Buffer, _ caret: Int, keys: [KeyChord]) -> [Action] {
        switch key {
        case "i":
            enterInsert(at: caret, keys: keys)
            return [.move(caret: caret)]
        case "a":
            let p = buffer.char(caret).map { $0 != 10 } == true ? caret + 1 : caret
            enterInsert(at: p, keys: keys)
            return [.move(caret: p)]
        case "I":
            let p = buffer.firstNonBlank(buffer.lineStart(caret))
            enterInsert(at: p, keys: keys)
            return [.move(caret: p)]
        case "A":
            let p = buffer.lineEnd(caret)
            enterInsert(at: p, keys: keys)
            return [.move(caret: p)]
        case "o":
            let end = buffer.lineEnd(caret)
            let indent = Self.indentation(for: buffer, line: caret)
            enterInsert(at: end + 1 + indent.utf16.count, keys: keys)
            return [.edit([TextEdit(range: end..<end, replacement: "\n" + indent)], caret: end + 1 + indent.utf16.count)]
        default:
            let start = buffer.lineStart(caret)
            let indent = Self.indentation(for: buffer, line: max(0, start - 1)) == "" || start == 0 ? "" : Self.indentation(for: buffer, line: start - 1)
            enterInsert(at: start + indent.utf16.count, keys: keys)
            return [.edit([TextEdit(range: start..<start, replacement: indent + "\n")], caret: start + indent.utf16.count)]
        }
    }

    mutating func join(_ buffer: Buffer, at caret: Int, lines: Int, keys: [KeyChord]) -> [Action] {
        var edits: [TextEdit] = []
        var line = buffer.lineStart(caret)
        var position = caret
        for _ in 1..<lines {
            let end = buffer.lineEnd(line)
            guard end < buffer.length else { break }
            let nextStart = end + 1
            let nextText = buffer.firstNonBlankOrEnd(nextStart)
            let joinsEmpty = buffer.lineEnd(nextStart) == nextText
            let separator = joinsEmpty || buffer.char(nextText) == 41 ? "" : (end > line && buffer.char(end - 1) == 32 ? "" : " ")
            var from = end
            while from > line, let c = buffer.char(from - 1), c == 32 || c == 9 { from -= 1 }
            if !separator.isEmpty || from == end { from = end }
            edits.append(TextEdit(range: from..<nextText, replacement: separator))
            position = from
            line = nextStart
        }
        guard !edits.isEmpty else { return [] }
        lastChange = (keys, nil)
        // Positions in edits refer to the original text; apply back to front.
        let shift = edits.dropLast().reduce(0) { $0 + $1.replacement.utf16.count - $1.range.count }
        return [.edit(edits, caret: position + shift)]
    }

    mutating func repeatChange(_ count: Int, _ context: Context) -> [Action] {
        guard let change = lastChange, !change.keys.isEmpty else { return [] }
        var copy = self
        copy.lastChange = nil
        copy.pending = []
        var keys = change.keys
        if count > 1, let (_, _, rest) = Self.prefix(keys) {
            keys = Array("\(count)".map { KeyChord(String($0)) }) + Array(rest)
        }
        var actions: [Action] = []
        var text = context.text
        var caret = context.caret
        for key in keys {
            if copy.mode == .insert, key == KeyChord("ESC") {
                if let inserted = change.inserted, !inserted.isEmpty {
                    let edit = TextEdit(range: caret..<caret, replacement: inserted)
                    actions.append(.edit([edit], caret: caret + inserted.utf16.count))
                    text = edit.apply(to: text)
                    caret += inserted.utf16.count
                }
            }
            let produced = copy.feed(key, Context(text: text, caret: caret, clipboard: context.clipboard, halfPage: context.halfPage, visible: context.visible, org: context.org))
            for action in produced {
                switch action {
                case .edit(let edits, let to):
                    var new = text
                    for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { new = edit.apply(to: new) }
                    text = new
                    caret = to
                case .move(let to):
                    caret = to
                default:
                    break
                }
                actions.append(action)
            }
        }
        let preserved = (registers, clipboardRecord)
        self = copy
        registers = preserved.0
        clipboardRecord = copy.clipboardRecord ?? preserved.1
        lastChange = change
        return actions
    }

    /// `/pattern` or `?pattern` from the prompt: the caret's new place.
    public mutating func search(_ pattern: String, forward: Bool, _ context: Context) -> [Action] {
        lastSearch = (pattern, forward)
        let buffer = Buffer(context)
        guard let p = buffer.search(pattern, from: context.caret, forward: forward, count: 1) else { return [.message("Search failed: \(pattern)")] }
        if mode == .visual || mode == .visualLine { return visualActions(buffer, p) }
        return [.jumped(from: context.caret), .move(caret: p)]
    }

    /// Leave a visual state without acting, as `ESC` does.
    public mutating func reset() {
        pending = []
        if mode == .visual || mode == .visualLine || mode == .visualBlock { mode = .normal }
    }

    // MARK: - Text

    struct Buffer {
        let ns: NSString
        var length: Int { ns.length }

        init(_ context: Context) { ns = context.text as NSString }
        init(_ text: String) { ns = text as NSString }

        func char(_ i: Int) -> unichar? { i >= 0 && i < ns.length ? ns.character(at: i) : nil }
        func substring(_ r: Range<Int>) -> String { ns.substring(with: NSRange(location: r.lowerBound, length: r.count)) }
        func lineStart(_ i: Int) -> Int { ns.lineRange(for: NSRange(location: min(i, ns.length), length: 0)).location }
        func lineEnd(_ i: Int) -> Int {
            var end = 0
            ns.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: min(i, ns.length), length: 0))
            return end
        }
        func removing(_ r: Range<Int>) -> Buffer { Buffer(ns.replacingCharacters(in: NSRange(location: r.lowerBound, length: r.count), with: "")) }
        func applying(_ edits: [TextEdit]) -> Buffer {
            var text = ns as String
            for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { text = edit.apply(to: text) }
            return Buffer(text)
        }

        static func isBlank(_ c: unichar) -> Bool { c == 32 || c == 9 }
        static func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
        static func isWord(_ c: unichar) -> Bool {
            guard let scalar = Unicode.Scalar(c) else { return true }
            return CharacterSet.alphanumerics.contains(scalar) || c == 95
        }

        /// 0 blank, 1 word, 2 other.
        func kind(_ i: Int, bigWord: Bool) -> Int {
            guard let c = char(i) else { return 0 }
            if Self.isSpace(c) { return 0 }
            if bigWord { return 1 }
            return Self.isWord(c) ? 1 : 2
        }

        func clampNormal(_ i: Int) -> Int { clampNormal(i, in: lineStart(i)) }
        func clampNormal(_ i: Int, in line: Int) -> Int {
            let end = lineEnd(line)
            return max(line, min(i, end > line ? end - 1 : line))
        }

        func firstNonBlank(_ line: Int) -> Int {
            var p = line
            let end = lineEnd(line)
            while p < end, let c = char(p), Self.isBlank(c) { p += 1 }
            return p == end && end > line ? end - 1 : (p == end ? line : p)
        }

        func firstNonBlankOrEnd(_ line: Int) -> Int {
            var p = line
            let end = lineEnd(line)
            while p < end, let c = char(p), Self.isBlank(c) { p += 1 }
            return p
        }

        func firstNonBlankIn(_ inserted: String, at start: Int) -> Int {
            start + inserted.prefix { $0 == " " || $0 == "\t" }.utf16.count
        }

        func lineOffset(_ number: Int) -> Int {
            var line = 0
            for _ in 1..<max(1, number) {
                let end = lineEnd(line)
                guard end < length, end + 1 < length else { break }
                line = end + 1
            }
            return line
        }

        /// The number, from 1, of the line holding `i`.
        func lineNumber(_ i: Int) -> Int {
            var count = 1
            var p = 0
            while p < min(i, length) {
                if char(p) == 10 { count += 1 }
                p += 1
            }
            return count
        }

        func lineCount(_ r: Range<Int>) -> Int {
            substring(r).filter { $0 == "\n" }.count + (r.upperBound > 0 && char(r.upperBound - 1) == 10 ? 0 : 1)
        }

        func wordForward(_ c: Int, bigWord: Bool) -> Int {
            var p = c
            let k = kind(p, bigWord: bigWord)
            if k != 0 { while p < length, kind(p, bigWord: bigWord) == k { p += 1 } }
            // Skip blanks; an empty line is a word.
            while p < length, kind(p, bigWord: bigWord) == 0 {
                if char(p) == 10, p > c, char(p - 1) == 10 { return p }
                if char(p) == 10, p + 1 < length, char(p + 1) == 10, p + 1 > c { return p + 1 }
                p += 1
            }
            return min(p, length)
        }

        func wordBackward(_ c: Int, bigWord: Bool, stopAtLine: Bool) -> Int {
            var p = c
            guard p > 0 else { return 0 }
            p -= 1
            while p > 0, kind(p, bigWord: bigWord) == 0 {
                if char(p) == 10, char(p - 1) == 10, !stopAtLine { return p }
                if stopAtLine, char(p) == 10 { return p + 1 }
                p -= 1
            }
            let k = kind(p, bigWord: bigWord)
            while p > 0, kind(p - 1, bigWord: bigWord) == k, k != 0 { p -= 1 }
            return p
        }

        func wordEnd(_ c: Int, bigWord: Bool, fromInside: Bool) -> Int {
            var p = fromInside ? c : c + 1
            while p < length, kind(p, bigWord: bigWord) == 0 { p += 1 }
            let k = kind(p, bigWord: bigWord)
            while p + 1 < length, kind(p + 1, bigWord: bigWord) == k, k != 0 { p += 1 }
            return min(p, max(0, length - 1))
        }

        func wordEndBackward(_ c: Int, bigWord: Bool) -> Int {
            var p = c
            let k = kind(p, bigWord: bigWord)
            while p > 0, kind(p, bigWord: bigWord) == k, k != 0 { p -= 1 }
            while p > 0, kind(p, bigWord: bigWord) == 0 { p -= 1 }
            return p
        }

        func wordStart(_ c: Int) -> Int {
            var p = c
            while p > 0, let ch = char(p - 1), Self.isWord(ch) { p -= 1 }
            return p
        }

        func wordAt(_ c: Int) -> String? {
            var p = c
            while p < lineEnd(c), let ch = char(p), !Self.isWord(ch) { p += 1 }
            guard let ch = char(p), Self.isWord(ch) else { return nil }
            let start = wordStart(p)
            var end = p
            while end < length, let e = char(end), Self.isWord(e) { end += 1 }
            return substring(start..<end)
        }

        func matchingBracket(_ c: Int) -> Int? {
            let pairs: [unichar: (unichar, Bool)] = [40: (41, true), 91: (93, true), 123: (125, true), 41: (40, false), 93: (91, false), 125: (123, false)]
            var p = c
            let end = lineEnd(c)
            while p < end, let ch = char(p), pairs[ch] == nil { p += 1 }
            guard let open = char(p), let (close, forward) = pairs[open] else { return nil }
            var depth = 0
            var q = p
            while q >= 0, q < length {
                if char(q) == open { depth += 1 }
                if char(q) == close {
                    depth -= 1
                    if depth == 0 { return q }
                }
                q += forward ? 1 : -1
            }
            return nil
        }

        func paragraph(_ c: Int, forward: Bool) -> Int {
            func blank(_ line: Int) -> Bool { substring(line..<lineEnd(line)).allSatisfy { $0 == " " || $0 == "\t" } }
            var line = lineStart(c)
            if forward {
                while lineEnd(line) < length, blank(line) { line = lineEnd(line) + 1 }
                while lineEnd(line) < length {
                    line = lineEnd(line) + 1
                    if blank(line) { return line }
                }
                return max(0, length - (length > 0 && char(length - 1) == 10 ? 1 : 0))
            }
            while line > 0, blank(line) { line = lineStart(line - 1) }
            while line > 0 {
                line = lineStart(line - 1)
                if blank(line) { return line }
            }
            return 0
        }

        func search(_ pattern: String, from c: Int, forward: Bool, count: Int) -> Int? {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let all = regex.matches(in: ns as String, range: NSRange(location: 0, length: length)).map(\.range.location)
            guard !all.isEmpty else { return nil }
            var p = c
            for _ in 0..<count {
                if forward {
                    p = all.first { $0 > p } ?? all[0]
                } else {
                    p = all.last { $0 < p } ?? all[all.count - 1]
                }
            }
            return p
        }

        func wordObject(_ c: Int, inner: Bool, bigWord: Bool, count: Int) -> Range<Int>? {
            guard c < length else { return nil }
            var start = c
            var end = c
            let k = kind(c, bigWord: bigWord)
            let lineS = lineStart(c)
            let lineE = lineEnd(c)
            while start > lineS, kind(start - 1, bigWord: bigWord) == k, char(start - 1) != 10 { start -= 1 }
            while end < lineE, kind(end, bigWord: bigWord) == k { end += 1 }
            if inner {
                for _ in 1..<max(1, count) {
                    let k2 = kind(end, bigWord: bigWord)
                    while end < lineE, kind(end, bigWord: bigWord) == k2 { end += 1 }
                }
                return start..<end
            }
            for _ in 1..<max(1, count) {
                while end < lineE, let ch = char(end), Self.isBlank(ch) { end += 1 }
                let k2 = kind(end, bigWord: bigWord)
                while end < lineE, kind(end, bigWord: bigWord) == k2 { end += 1 }
            }
            if k == 0 {
                let k2 = kind(end, bigWord: bigWord)
                while end < lineE, kind(end, bigWord: bigWord) == k2 { end += 1 }
                return start..<end
            }
            var trailing = end
            while trailing < lineE, let ch = char(trailing), Self.isBlank(ch) { trailing += 1 }
            if trailing > end { return start..<trailing }
            while start > lineS, let ch = char(start - 1), Self.isBlank(ch) { start -= 1 }
            return start..<end
        }

        func quoteObject(_ c: Int, quote: unichar, inner: Bool) -> Range<Int>? {
            let s = lineStart(c)
            let e = lineEnd(c)
            var positions: [Int] = []
            var p = s
            while p < e {
                if char(p) == quote, p == s || char(p - 1) != 92 { positions.append(p) }
                p += 1
            }
            var pair: (Int, Int)?
            var i = 0
            while i + 1 < positions.count {
                if positions[i] <= c, c <= positions[i + 1] { pair = (positions[i], positions[i + 1]); break }
                i += 2
            }
            guard let (open, close) = pair else { return nil }
            if inner { return (open + 1)..<close }
            var end = close + 1
            while end < e, let ch = char(end), Self.isBlank(ch) { end += 1 }
            var start = open
            if end == close + 1 { while start > s, let ch = char(start - 1), Self.isBlank(ch) { start -= 1 } }
            return start..<end
        }

        func bracketObject(_ c: Int, open: unichar, close: unichar, inner: Bool) -> Range<Int>? {
            var depth = 0
            var p = c
            var start: Int?
            if char(c) == open {
                start = c
            } else {
                if char(c) == close { p = c - 1 }
                while p >= 0 {
                    if char(p) == close { depth += 1 }
                    if char(p) == open {
                        if depth == 0 { start = p; break }
                        depth -= 1
                    }
                    p -= 1
                }
            }
            if start == nil {
                var f = c
                while f < lineEnd(c), char(f) != open { f += 1 }
                if f < lineEnd(c) { start = f }
            }
            guard let s = start else { return nil }
            depth = 0
            var q = s
            var end: Int?
            while q < length {
                if char(q) == open { depth += 1 }
                if char(q) == close {
                    depth -= 1
                    if depth == 0 { end = q; break }
                }
                q += 1
            }
            guard let e = end else { return nil }
            if !inner { return s..<(e + 1) }
            var innerStart = s + 1
            var innerEnd = e
            // A block that starts and ends on its own lines keeps them.
            if char(innerStart) == 10, lineStart(innerEnd) == innerEnd || substring(lineStart(innerEnd)..<innerEnd).allSatisfy({ $0 == " " || $0 == "\t" }) {
                innerStart += 1
                innerEnd = lineStart(innerEnd)
            }
            return innerStart..<innerEnd
        }

        func paragraphObject(_ c: Int, inner: Bool) -> Range<Int>? {
            func blank(_ line: Int) -> Bool { substring(line..<lineEnd(line)).allSatisfy { $0 == " " || $0 == "\t" } }
            var start = lineStart(c)
            let isBlank = blank(start)
            while start > 0, blank(lineStart(start - 1)) == isBlank { start = lineStart(start - 1) }
            var end = lineEnd(c)
            while end < length, end + 1 <= length, end + 1 < length || !isBlank, blank(end + 1) == isBlank, end + 1 < length {
                end = lineEnd(end + 1)
            }
            var upper = min(length, end + 1)
            if !inner {
                var after = upper
                while after < length, blank(after) {
                    let next = lineEnd(after)
                    after = min(length, next + 1)
                    if next >= length { break }
                }
                upper = after
            }
            return start..<upper
        }
    }
}
