import Foundation

// `electric-pair-mode` (Emacs 31.1 elec-pair.el) in an Org buffer, with its defaults:
// `electric-pair-preserve-balance`, skipping whitespace before a closer, deleting adjacent
// pairs and opening a line between them. Delimiters are what `org-mode-syntax-table` makes
// them: () [] {} <> and "; inside a string, `prog-mode-syntax-table`'s.

/// A syntax table's view of a character, as far as pairing goes.
private enum SyntaxClass: Equatable {
    case open(unichar), close(unichar), string, escape, other
}

private enum SyntaxTable {
    case org, text

    func classify(_ c: unichar) -> SyntaxClass {
        switch c {
        case 40: return .open(41)
        case 91: return .open(93)
        case 123: return .open(125)
        case 41: return .close(40)
        case 93: return .close(91)
        case 125: return .close(123)
        case 34: return .string
        case 60: return self == .org ? .open(62) : .other
        case 62: return self == .org ? .close(60) : .other
        // Org makes the backslash a symbol constituent; the standard table escapes with it.
        case 92: return self == .org ? .other : .escape
        default: return .other
        }
    }

    /// `matching-paren`.
    func matching(_ c: unichar) -> unichar? {
        switch classify(c) {
        case .open(let m), .close(let m): return m
        default: return nil
        }
    }
}

/// The text being typed into, with point, as the hook functions see the buffer.
private final class PairBuffer {
    let s: NSMutableString
    var point: Int

    init(_ text: String, point: Int) {
        s = NSMutableString(string: text)
        self.point = point
    }

    var length: Int { s.length }
    func char(_ i: Int) -> unichar? { i >= 0 && i < s.length ? s.character(at: i) : nil }
    var charAfter: unichar? { char(point) }
    var charBefore: unichar? { char(point - 1) }

    func insert(_ text: String, at i: Int) {
        s.insert(text, at: i)
        if point >= i { point += (text as NSString).length }
    }

    func delete(_ range: Range<Int>) {
        s.deleteCharacters(in: NSRange(location: range.lowerBound, length: range.count))
        if point > range.upperBound { point -= range.count } else if point > range.lowerBound { point = range.lowerBound }
    }

    // MARK: Parsing, as `parse-partial-sexp` and `scan-sexps`

    struct State {
        var depth = 0
        /// Positions of the open parens enclosing the end, innermost last (nth 9).
        var opens: [Int] = []
        /// The string's delimiter while inside one (nth 3).
        var stringChar: unichar?
        /// Where that string starts (nth 8).
        var stringStart: Int?
    }

    func parse(from: Int, to: Int, table: SyntaxTable) -> State {
        var state = State()
        var i = from
        while i < to, let c = char(i) {
            let cls = table.classify(c)
            if let delimiter = state.stringChar {
                if cls == .escape { i += 2; continue }
                if c == delimiter { state.stringChar = nil; state.stringStart = nil }
            } else {
                switch cls {
                case .open: state.depth += 1; state.opens.append(i)
                case .close: state.depth -= 1; if !state.opens.isEmpty { state.opens.removeLast() }
                case .string: state.stringChar = c; state.stringStart = i
                case .escape: i += 2; continue
                case .other: break
                }
            }
            i += 1
        }
        return state
    }

    /// `syntax-ppss`: the buffer's table, from the start.
    func ppss(_ pos: Int) -> State { parse(from: 0, to: pos, table: .org) }

    /// `electric-pair--syntax-ppss` with WHERE `(string comment)`: inside a string, its text
    /// parsed with the text table.
    func pairPpss(_ pos: Int) -> State {
        let quick = ppss(pos)
        if quick.stringChar != nil, let start = quick.stringStart {
            return parse(from: start + 1, to: pos, table: .text)
        }
        return quick
    }

    enum ScanResult {
        case done
        /// "Containing expression ends prematurely", and where it stopped.
        case premature(Int)
        case unbalanced
    }

    /// `scan-sexps` from `from` over as many sexps as there are, forward or back.
    func scan(from: Int, forward: Bool, table: SyntaxTable) -> ScanResult {
        var depth = 0
        if forward {
            var i = from
            while let c = char(i) {
                switch table.classify(c) {
                case .open: depth += 1
                case .close:
                    depth -= 1
                    if depth < 0 { return .premature(i + 1) }
                case .string:
                    var j = i + 1
                    while let d = char(j), d != c { j += table.classify(d) == .escape ? 2 : 1 }
                    if j >= length { return .unbalanced }
                    i = j
                case .escape: i += 1
                case .other: break
                }
                i += 1
            }
        } else {
            var i = from - 1
            while i >= 0, let c = char(i) {
                if quoted(i, table) { i -= 1; continue }
                switch table.classify(c) {
                case .close: depth += 1
                case .open:
                    depth -= 1
                    if depth < 0 { return .premature(i) }
                case .string:
                    var j = i - 1
                    while j >= 0, !(char(j) == c && !quoted(j, table)) { j -= 1 }
                    if j < 0 { return .unbalanced }
                    i = j
                default: break
                }
                i -= 1
            }
        }
        return depth > 0 ? .unbalanced : .done
    }

    /// `char-quoted`: an odd number of escapes before `i`.
    private func quoted(_ i: Int, _ table: SyntaxTable) -> Bool {
        var n = 0
        var j = i - 1
        while j >= 0, let c = char(j), table.classify(c) == .escape { n += 1; j -= 1 }
        return n % 2 == 1
    }

    /// `scan-sexps` forward by one from the open paren at `from`: past its closer, or nil on an
    /// error.
    func scanOne(from: Int, table: SyntaxTable) -> Int? {
        var depth = 0
        var i = from
        while let c = char(i) {
            switch table.classify(c) {
            case .open: depth += 1
            case .close:
                depth -= 1
                if depth < 0 { return nil }
                if depth == 0 { return i + 1 }
            case .string:
                var j = i + 1
                while let d = char(j), d != c { j += table.classify(d) == .escape ? 2 : 1 }
                if j >= length { return nil }
                i = j
                if depth == 0 { return i + 1 }
            case .escape: i += 1
            case .other: break
            }
            i += 1
        }
        return nil
    }

    // MARK: elec-pair.el

    struct Info {
        enum Syntax { case open, close, string }
        let syntax: Syntax
        let pair: unichar
        let unconditional: Bool
        /// Where the string point is in starts.
        let stringStart: Int?
    }

    /// `electric-quote-chars` pairs, from `electric-pair-pairs` (and the text pairs, the same).
    static let fallback: [(unichar, unichar)] = [(34, 34), (0x2018, 0x2019), (0x201C, 0x201D)]

    /// `electric-pair-syntax-info`.
    func info(_ c: unichar) -> Info? {
        let pre = point == 0 || ppss(point - 1).stringStart != nil
        let post = ppss(point).stringStart
        let stringStart = pre ? post : nil
        let table: SyntaxTable = stringStart == nil ? .org : .text
        switch table.classify(c) {
        case .open(let m): return Info(syntax: .open, pair: m, unconditional: false, stringStart: stringStart)
        case .close(let m): return Info(syntax: .close, pair: m, unconditional: false, stringStart: stringStart)
        case .string: return Info(syntax: .string, pair: c, unconditional: false, stringStart: stringStart)
        default: break
        }
        if let direct = Self.fallback.first(where: { $0.0 == c }) {
            return direct.0 == direct.1
                ? Info(syntax: .string, pair: c, unconditional: true, stringStart: stringStart)
                : Info(syntax: .open, pair: direct.1, unconditional: true, stringStart: stringStart)
        }
        if let reverse = Self.fallback.first(where: { $0.1 == c }) {
            return Info(syntax: .close, pair: reverse.0, unconditional: true, stringStart: stringStart)
        }
        return nil
    }

    struct Side {
        var matched: Bool
        var pair: unichar?
    }

    /// `electric-pair--balance-info`: the innermost and outermost lists around point.
    func balance(forward: Bool, stringStart: Int?) -> (innermost: Side, outermost: Side) {
        let table: SyntaxTable = stringStart == nil ? .org : .text
        var innermost: Side?
        var outermost: Side?
        let saved = point
        defer { point = saved }
        while outermost == nil {
            switch scan(from: point, forward: forward, table: table) {
            case .done, .unbalanced:
                outermost = Side(matched: true)
                if innermost == nil { innermost = Side(matched: true) }
            case .premature(let pos):
                if stringStart != nil, ppss(point).stringStart == nil {
                    outermost = Side(matched: true)
                    if innermost == nil { innermost = Side(matched: true) }
                    break
                }
                point = pos
                let matched: Bool
                if forward {
                    let state = pairPpss(point - 1)
                    if let start = state.opens.last, let opener = char(start) {
                        matched = charBefore == (table.matching(opener) ?? opener)
                    } else {
                        matched = false
                    }
                } else if let end = scanOne(from: point, table: table), let closer = char(end - 1) {
                    matched = charAfter == table.matching(closer)
                } else {
                    matched = false
                }
                let actual = forward ? charBefore : charAfter
                if innermost == nil { innermost = Side(matched: matched, pair: actual) }
                if !matched { outermost = Side(matched: matched, pair: actual) }
            }
        }
        return (innermost!, outermost!)
    }

    /// `electric-pair-inhibit-if-helps-balance`, with the typed character before point.
    func inhibit(_ c: unichar) -> Bool {
        guard let info = info(c) else { return false }
        let at = point - 1
        delete(at..<point)
        defer { insert(String(utf16CodeUnits: [c], count: 1), at: at) }
        switch info.syntax {
        case .open:
            let outermost = balance(forward: true, stringStart: info.stringStart).outermost
            return outermost.matched ? false : outermost.pair == info.pair
        case .string:
            return ppss(length).stringChar == c
        case .close:
            return false
        }
    }

    /// `electric-pair-skip-if-helps-balance`, with the typed character before point.
    func skip(_ c: unichar) -> Bool {
        guard let info = info(c) else { return false }
        let at = point - 1
        delete(at..<point)
        defer { insert(String(utf16CodeUnits: [c], count: 1), at: at) }
        switch info.syntax {
        case .close:
            let (innermost, outermost) = balance(forward: false, stringStart: info.stringStart)
            if outermost.matched { return innermost.matched }
            return innermost.matched && outermost.pair != info.pair
        case .string:
            return ppss(point).stringChar == c
        case .open:
            return false
        }
    }

    /// `electric-pair--skip-whitespace`, unless that leaves or enters a string.
    func skipWhitespace() {
        let saved = point
        let before = ppss(point).stringStart
        while let c = charAfter, c == 9 || c == 32 || c == 10 { point += 1 }
        if ppss(point).stringStart != before { point = saved }
    }
}

public enum ElectricPair {
    /// Typing `c` into `text` with `selection` (point at its upper end, mark at its lower):
    /// the text and point that `self-insert-command` and `electric-pair-post-self-insert-function`
    /// leave.
    public static func type(_ c: unichar, text: String, selection: Range<Int>) -> (text: String, point: Int) {
        let b = PairBuffer(text, point: selection.upperBound)
        let typed = String(utf16CodeUnits: [c], count: 1)
        b.insert(typed, at: b.point)
        let pos = b.point
        guard let info = b.info(c) else { return (b.s as String, b.point) }
        if !selection.isEmpty {
            // `use-region-p`: the region is wrapped.
            let mark = selection.lowerBound
            let pair = String(utf16CodeUnits: [info.pair], count: 1)
            if info.syntax == .string || info.syntax == .close {
                b.insert(pair, at: mark)
            } else {
                b.delete(pos - 1..<pos)
                b.insert(pair, at: b.point)
                b.point = mark
                b.insert(typed, at: b.point)
            }
            return (b.s as String, b.point)
        }
        if info.syntax == .close || info.syntax == .string {
            let skipsSelf = info.unconditional || b.skip(c)
            if skipsSelf {
                let skipsSpace = !(info.unconditional && info.syntax == .string)
                let saved = b.point
                if skipsSpace { b.skipWhitespace() }
                let lands = b.charAfter == c
                b.point = saved
                if lands {
                    if skipsSpace { b.skipWhitespace() }
                    b.delete(pos - 1..<pos)
                    b.point += 1
                    return (b.s as String, b.point)
                }
            }
        }
        if info.syntax == .open || info.syntax == .string, info.unconditional || !b.inhibit(c) {
            b.insert(String(utf16CodeUnits: [info.pair], count: 1), at: b.point)
            b.point = pos
        }
        return (b.s as String, b.point)
    }

    /// DEL at `caret` between an opening delimiter and its pair: both go
    /// (`electric-pair-delete-pair`). Nil leaves DEL as it is.
    public static func deletePair(text: String, caret: Int) -> Range<Int>? {
        let b = PairBuffer(text, point: caret)
        guard let prev = b.charBefore, let next = b.charAfter, let info = b.info(prev),
              info.syntax != .close, info.pair == next else { return nil }
        return caret - 1..<caret + 1
    }

    /// RET at `caret` between an open paren and its closer: a second newline after point
    /// (`electric-pair-open-newline-between-pairs`).
    public static func opensLine(text: String, caret: Int) -> Bool {
        let b = PairBuffer(text, point: caret)
        guard caret > 0, caret < b.length, let prev = b.charBefore, let next = b.charAfter else { return false }
        return SyntaxTable.org.matching(next) == prev
    }
}

/// A key typed with `electric-pair-mode` on: a pairing character, DEL or RET. It doesn't
/// apply where the key types as it would without the mode.
public struct ElectricPairKey: OrgCommand {
    public let key: String
    public init(key: String) { self.key = key }
    public var id: String { "internal.electric-pair" }
    public var title: String { "Electric Pair" }

    /// The characters `electric-pair-syntax-info` knows in an Org buffer.
    public static let characters: Set<String> = ["(", ")", "[", "]", "{", "}", "<", ">", "\"", "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}"]

    public func applies(in context: EditContext) -> Bool { result(context) != nil }

    public func run(in context: EditContext) -> CommandStep {
        guard let result = result(context) else { return .failed("") }
        return .commit(result)
    }

    private func result(_ context: EditContext) -> EditResult? {
        guard context.options.electricPair else { return nil }
        let selection = context.selection.first ?? context.caret..<context.caret
        let ns = context.text as NSString
        switch key {
        case "DEL":
            guard selection.isEmpty, let range = ElectricPair.deletePair(text: context.text, caret: selection.lowerBound) else { return nil }
            return EditResult(baseRevision: context.revision, edits: [TextEdit(range: range, replacement: "")], selection: [range.lowerBound..<range.lowerBound])
        case "RET":
            guard selection.isEmpty, ElectricPair.opensLine(text: context.text, caret: selection.lowerBound) else { return nil }
            let at = selection.lowerBound
            return EditResult(baseRevision: context.revision, edits: [TextEdit(range: at..<at, replacement: "\n\n")], selection: [at + 1..<at + 1])
        default:
            guard Self.characters.contains(key), let unit = key.utf16.first else { return nil }
            let typed = ElectricPair.type(unit, text: context.text, selection: selection)
            let plain = ns.replacingCharacters(in: NSRange(location: selection.lowerBound, length: selection.count), with: key)
            if typed.text == plain, typed.point == selection.lowerBound + 1 { return nil }
            // One replacement: what lies between the common start and end.
            let new = typed.text as NSString
            var start = 0
            while start < ns.length, start < new.length, ns.character(at: start) == new.character(at: start) { start += 1 }
            var end = 0
            while end < ns.length - start, end < new.length - start,
                  ns.character(at: ns.length - 1 - end) == new.character(at: new.length - 1 - end) { end += 1 }
            let replacement = new.substring(with: NSRange(location: start, length: new.length - start - end))
            return EditResult(baseRevision: context.revision, edits: [TextEdit(range: start..<ns.length - end, replacement: replacement)],
                              selection: [typed.point..<typed.point])
        }
    }
}
