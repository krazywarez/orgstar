import Foundation

/// An Emacs regexp as an `NSRegularExpression`, with the syntax table of an Org buffer, where
/// table formulas and Emacs Lisp blocks run. A construct it can't translate exactly throws
/// `Elisp.Unsupported`, and so do subjects where ICU's tables could differ from Emacs's:
/// syntax classes against text past ASCII, and case folding with letters past ASCII.
struct ElispRegex {
    let pattern: String
    let groups: Int
    /// Has letters, ranges over letters or case classes: case folding changes what matches.
    let foldable: Bool
    /// Has classes whose members past ASCII come from Emacs's syntax or Unicode tables.
    let asciiClasses: Bool
    /// Has letters with case past ASCII.
    let nonASCIILetters: Bool
    let plain: NSRegularExpression
    let folded: NSRegularExpression

    /// `char-syntax` of each ASCII character in `org-mode-syntax-table`.
    static let syntax = Array(".........  .  .................. .\".ww_w()__._._wwwwwwwwww..(_)..wwwwwwwwwwwwwwwwwwwwwwwwww(_)._.wwwwwwwwwwwwwwwwwwwwwwwwww(_)_.")

    static func codes(_ syntaxClass: Character) -> [UInt32] {
        syntax.indices.filter { syntax[$0] == syntaxClass }.map(UInt32.init)
    }

    static func hex(_ c: UInt32) -> String { "\\x{" + String(c, radix: 16) + "}" }

    static func set(_ codes: [UInt32], negated: Bool = false) -> String {
        "[" + (negated ? "^" : "") + codes.map(hex).joined() + "]"
    }

    static let word = codes("w")
    static let symbol = word + codes("_")

    /// A letter with case, which case folding changes.
    static func isLetter(_ c: UInt32) -> Bool {
        (65...90).contains(c) || (97...122).contains(c) || c > 127 && Unicode.Scalar(c).map { $0.properties.changesWhenCaseMapped || $0.properties.changesWhenCaseFolded } ?? false
    }

    init(_ pattern: String) throws {
        self.pattern = pattern
        let p = Array(pattern.unicodeScalars)
        var out = ""
        var groups = 0
        var open: [Int] = []
        var closed: Set<Int> = []
        var foldable = false
        var asciiClasses = false
        // Where `^` is an anchor, and where `*`, `+` and `?` are ordinary characters: at the
        // start, after `\(` or `\|`, and for the second also after that `^`.
        var anchor = true
        var ordinary = true
        var quantifiable = false
        // After a repetition, and whether a `?` may make it non-greedy.
        var quantified = false
        var lazy = false
        var i = 0
        func unsupported(_ what: String) -> Elisp.Unsupported { Elisp.Unsupported(what: "regexp \(what) in \(Elisp.printed(.string(pattern), escape: true))") }
        func literal(_ c: Unicode.Scalar) {
            if c.isASCII, c.properties.isAlphabetic || ("0"..."9").contains(c) { out.unicodeScalars.append(c) } else { out += Self.hex(c.value) }
            if Self.isLetter(c.value) { foldable = true }
            (anchor, ordinary, quantifiable, quantified) = (false, false, true, false)
        }
        func atom(_ text: String) {
            out += text
            (anchor, ordinary, quantifiable, quantified) = (false, false, true, false)
        }
        func assertion(_ text: String) {
            out += text
            (anchor, ordinary, quantifiable, quantified) = (false, false, false, false)
        }
        while i < p.count {
            let c = p[i]
            i += 1
            switch c {
            case "^":
                if anchor {
                    out += "(?:(?<![\\s\\S])|(?<=\\n))"
                    anchor = false
                } else {
                    literal(c)
                }
            case "$":
                let rest = p[i...]
                if rest.isEmpty || rest.starts(with: ["\\", ")"]) || rest.starts(with: ["\\", "|"]) {
                    assertion("(?=\\n|(?![\\s\\S]))")
                } else {
                    literal(c)
                }
            case ".":
                atom("[^\\n]")
            case "*", "+", "?":
                if quantified {
                    guard c == "?", lazy else { throw unsupported("\(c) after a repetition") }
                    out += "?"
                    lazy = false
                } else if quantifiable {
                    out.unicodeScalars.append(c)
                    (quantifiable, quantified, lazy) = (false, true, true)
                } else if ordinary {
                    literal(c)
                } else {
                    throw unsupported(String(c))
                }
            case "[":
                var j = i
                var text = "["
                if j < p.count, p[j] == "^" {
                    text += "^"
                    j += 1
                }
                var first = true
                while true {
                    guard j < p.count else { throw unsupported("[") }
                    let c = p[j]
                    if c == "]", !first {
                        j += 1
                        break
                    }
                    first = false
                    if c == "[", j + 1 < p.count, p[j + 1] == ":" {
                        var k = j + 2
                        var name = ""
                        while k + 1 < p.count, !(p[k] == ":" && p[k + 1] == "]") {
                            name.unicodeScalars.append(p[k])
                            k += 1
                        }
                        guard k + 1 < p.count else { throw unsupported("[:") }
                        j = k + 2
                        let ascii: (String, Bool, Bool) = switch name {
                        case "alpha": ("A-Za-z", true, false)
                        case "alnum": ("0-9A-Za-z", true, false)
                        case "upper": ("A-Z", true, true)
                        case "lower": ("a-z", true, true)
                        case "digit": ("0-9", false, false)
                        case "xdigit": ("0-9A-Fa-f", false, false)
                        case "cntrl": ("\\x{0}-\\x{1f}", false, false)
                        case "ascii": ("\\x{0}-\\x{7f}", false, false)
                        case "nonascii": ("\\x{80}-\\x{10ffff}", false, false)
                        case "space": (Self.codes(" ").map(Self.hex).joined(), true, false)
                        case "blank": ("\\x{9}\\x{20}", true, false)
                        case "punct": ((33...126).filter { !Self.isLetter($0) && !(48...57).contains($0) }.map(Self.hex).joined(), true, false)
                        case "graph": ("\\x{21}-\\x{7e}", true, false)
                        case "print": ("\\x{20}-\\x{7e}", true, false)
                        case "word": (Self.word.map(Self.hex).joined(), true, false)
                        default: throw unsupported("[:\(name):]")
                        }
                        text += ascii.0
                        if ascii.1 { asciiClasses = true }
                        if ascii.2 { foldable = true }
                        continue
                    }
                    if j + 2 < p.count, p[j + 1] == "-", p[j + 2] != "]" {
                        let end = p[j + 2]
                        guard c.value <= end.value else { throw unsupported("range") }
                        text += Self.hex(c.value) + "-" + Self.hex(end.value)
                        if end.value >= 65, c.value <= 122 || end.value > 127 { foldable = true }
                        j += 3
                        continue
                    }
                    text += Self.hex(c.value)
                    if Self.isLetter(c.value) { foldable = true }
                    j += 1
                }
                i = j
                atom(text + "]")
            case "\\":
                guard i < p.count else { throw unsupported("\\ at the end") }
                let e = p[i]
                i += 1
                switch e {
                case "(":
                    if i < p.count, p[i] == "?" {
                        guard i + 1 < p.count, p[i + 1] == ":" else { throw unsupported("\\(?") }
                        i += 2
                        out += "(?:"
                        open.append(0)
                    } else {
                        groups += 1
                        out += "("
                        open.append(groups)
                    }
                    (anchor, ordinary, quantifiable, quantified) = (true, true, false, false)
                case ")":
                    guard let n = open.popLast() else { throw unsupported("\\)") }
                    closed.insert(n)
                    atom(")")
                case "|":
                    out += "|"
                    (anchor, ordinary, quantifiable, quantified) = (true, true, false, false)
                case "{":
                    guard quantifiable else { throw unsupported("\\{") }
                    var low = ""
                    var high: String?
                    while i < p.count, ("0"..."9").contains(p[i]) {
                        low.unicodeScalars.append(p[i])
                        i += 1
                    }
                    if i < p.count, p[i] == "," {
                        i += 1
                        var digits = ""
                        while i < p.count, ("0"..."9").contains(p[i]) {
                            digits.unicodeScalars.append(p[i])
                            i += 1
                        }
                        high = digits
                    }
                    guard i + 1 < p.count, p[i] == "\\", p[i + 1] == "}", !low.isEmpty || high != nil else { throw unsupported("\\{") }
                    i += 2
                    out += "{" + (low.isEmpty ? "0" : low) + (high.map { "," + $0 } ?? "") + "}"
                    (quantifiable, quantified, lazy) = (false, true, false)
                case "1"..."9":
                    let n = Int(e.value) - 48
                    guard closed.contains(n) else { throw unsupported("\\\(n)") }
                    atom("(?:\\\(n))")
                case "w", "W":
                    asciiClasses = true
                    atom(Self.set(Self.word, negated: e == "W"))
                case "s", "S":
                    guard i < p.count else { throw unsupported("\\s") }
                    let code: Character = switch p[i] {
                    case "-", " ": " "
                    case "w", "_", ".", "(", ")", "\"": Character(p[i])
                    default: throw unsupported("\\s\(p[i])")
                    }
                    i += 1
                    asciiClasses = true
                    atom(Self.set(Self.codes(code), negated: e == "S"))
                case "b", "B", "<", ">":
                    asciiClasses = true
                    let w = Self.set(Self.word)
                    let text = switch e {
                    case "b": "(?:(?<=\(w))(?!\(w))|(?<!\(w))(?=\(w)))"
                    case "B": "(?:(?<=\(w))(?=\(w))|(?<!\(w))(?!\(w)))"
                    case "<": "(?<!\(w))(?=\(w))"
                    default: "(?<=\(w))(?!\(w))"
                    }
                    assertion(text)
                case "_":
                    guard i < p.count, p[i] == "<" || p[i] == ">" else { throw unsupported("\\_") }
                    asciiClasses = true
                    let s = Self.set(Self.symbol)
                    assertion(p[i] == "<" ? "(?<!\(s))(?=\(s))" : "(?<=\(s))(?!\(s))")
                    i += 1
                case "`":
                    assertion("(?<![\\s\\S])")
                case "'":
                    assertion("(?![\\s\\S])")
                default:
                    guard !e.isASCII || !(e.properties.isAlphabetic || ("0"..."9").contains(e) || e == "}") else { throw unsupported("\\\(e)") }
                    literal(e)
                }
            default:
                literal(c)
            }
        }
        guard open.isEmpty else { throw unsupported("\\(") }
        self.groups = groups
        self.foldable = foldable
        self.asciiClasses = asciiClasses
        nonASCIILetters = p.contains { !$0.isASCII && Self.isLetter($0.value) }
        do {
            plain = try NSRegularExpression(pattern: out.isEmpty ? "(?:)" : out)
            folded = try NSRegularExpression(pattern: out.isEmpty ? "(?:)" : out, options: .caseInsensitive)
        } catch {
            throw unsupported("syntax")
        }
    }

    /// The first match at or after character `start`: each group's range in characters, nil
    /// for groups that didn't match.
    func firstMatch(in s: String, from start: Int, caseFold: Bool) throws -> [Range<Int>?]? {
        let subjectNonASCII = s.unicodeScalars.contains { !$0.isASCII }
        if asciiClasses, subjectNonASCII { throw Elisp.Unsupported(what: "regexp classes on text past ASCII") }
        // Folding agrees for ASCII letters, unless the text has a character whose case maps
        // to ASCII, like the Kelvin sign or ß.
        if caseFold, foldable, nonASCIILetters || subjectNonASCII && s.unicodeScalars.contains(where: { c in
            !c.isASCII && (String(c).lowercased() + String(c).uppercased()).unicodeScalars.contains(where: \.isASCII)
        }) {
            throw Elisp.Unsupported(what: "case folding past ASCII")
        }
        // UTF-16 offset of each character, and the end.
        var offsets = [0]
        if subjectNonASCII {
            for scalar in s.unicodeScalars { offsets.append(offsets.last! + scalar.utf16.count) }
        }
        func utf16(_ i: Int) -> Int { subjectNonASCII ? offsets[i] : i }
        func character(_ u: Int) -> Int {
            guard subjectNonASCII else { return u }
            var low = 0
            var high = offsets.count - 1
            while low < high {
                let mid = (low + high) / 2
                if offsets[mid] < u { low = mid + 1 } else { high = mid }
            }
            return low
        }
        let length = (s as NSString).length
        let from = utf16(start)
        guard let m = (caseFold ? folded : plain).firstMatch(in: s, options: [.withTransparentBounds, .withoutAnchoringBounds],
                                                            range: NSRange(location: from, length: length - from)) else { return nil }
        return (0...groups).map { g in
            let r = m.range(at: g)
            return r.location == NSNotFound ? nil : character(r.location)..<character(NSMaxRange(r))
        }
    }
}

extension Elisp {
    /// `case-fold-search`.
    var caseFold: Bool { (try? value("case-fold-search")).map { !Self.isNil($0) } ?? true }

    func regex(_ pattern: String) throws -> ElispRegex {
        if let cached = regexes[pattern] { return cached }
        let compiled = try ElispRegex(pattern)
        regexes[pattern] = compiled
        return compiled
    }

    /// `string-match`: the match data, or nil.
    func stringMatch(_ pattern: String, _ s: String, start: Sexp = .nil) throws -> [Range<Int>?]? {
        let count = s.unicodeScalars.count
        var from = Self.isNil(start) ? 0 : try Self.int(start)
        if from < 0 { from += count }
        guard (0...count).contains(from) else { throw Signal(message: "Args out of range: \(Self.printed(.string(s), escape: true)), \(Self.printed(start))") }
        return try regex(pattern).firstMatch(in: s, from: from, caseFold: caseFold)
    }

    static func substring(_ s: String, _ range: Range<Int>) throws -> String {
        let scalars = Array(s.unicodeScalars)
        guard range.upperBound <= scalars.count else { throw Signal(message: "Args out of range") }
        return String(String.UnicodeScalarView(scalars[range]))
    }

    /// `replace-match` on a string, with the match data in characters of `s`.
    func replaceMatch(_ newText: String, fixedCase: Bool, literal: Bool, in s: String, subexp: Int) throws -> String {
        guard subexp < matchData.count, let target = matchData[subexp] else {
            throw Signal(message: "replace-match subexpression does not exist")
        }
        var text = ""
        if literal {
            text = newText
        } else {
            var chars = newText.unicodeScalars.makeIterator()
            while let c = chars.next() {
                guard c == "\\" else {
                    text.unicodeScalars.append(c)
                    continue
                }
                switch chars.next() {
                case "&": text += try Self.substring(s, matchData[0]!)
                case "\\": text += "\\"
                case let d? where ("1"..."9").contains(d):
                    let n = Int(d.value) - 48
                    if n < matchData.count, let r = matchData[n] { text += try Self.substring(s, r) }
                default: throw Signal(message: "Invalid use of ‘\\’ in replacement text")
                }
            }
        }
        let old = try Self.substring(s, target)
        if !fixedCase, !old.unicodeScalars.allSatisfy(\.isASCII) {
            // Past ASCII, only the cases that keep the replacement's case: no letter with a
            // case, or a lowercase letter first.
            let first = old.unicodeScalars.first.map { $0.properties.isLowercase && $0.properties.changesWhenUppercased } ?? false
            guard first || !old.unicodeScalars.contains(where: \.properties.changesWhenCaseMapped) else {
                throw Unsupported(what: "replace-match case past ASCII")
            }
        } else if !fixedCase {
            // How `replace-match` decides to change the replacement's case from the replaced text.
            func isWord(_ c: Unicode.Scalar) -> Bool { c.isASCII && ElispRegex.syntax[Int(c.value)] == "w" }
            var (multiletter, lower, nonUpperInitial, upper) = (false, false, false, false)
            var previous: Unicode.Scalar = "\n"
            for c in old.unicodeScalars {
                if ("a"..."z").contains(c) {
                    lower = true
                    if isWord(previous) { multiletter = true } else { nonUpperInitial = true }
                } else if ("A"..."Z").contains(c) {
                    upper = true
                    if isWord(previous) { multiletter = true }
                } else if !isWord(previous), isWord(c) {
                    nonUpperInitial = true
                }
                previous = c
            }
            let allCaps = (!lower && multiletter) || (!nonUpperInitial && !multiletter && upper)
            let initials = !allCaps && !nonUpperInitial && multiletter
            if allCaps || initials {
                guard text.unicodeScalars.allSatisfy(\.isASCII) else { throw Unsupported(what: "replace-match case past ASCII") }
                if allCaps {
                    text = text.uppercased()
                } else {
                    var result = ""
                    var previous: Unicode.Scalar = "\n"
                    for c in text.unicodeScalars {
                        result += !isWord(previous) ? String(c).uppercased() : String(c)
                        previous = c
                    }
                    text = result
                }
            }
        }
        let scalars = Array(s.unicodeScalars)
        return String(String.UnicodeScalarView(scalars[..<target.lowerBound])) + text + String(String.UnicodeScalarView(scalars[target.upperBound...]))
    }

    static func regexFunctions(_ lisp: Elisp) {
        lisp.set("case-fold-search", t)
        for name in ["string-match", "string-match-p"] {
            lisp.define(name) { lisp, args in
                try arity(args, 2...4, name)
                guard let data = try lisp.stringMatch(try string(args[0]), try string(args[1]), start: args.count > 2 ? args[2] : .nil) else { return .nil }
                if name == "string-match" { lisp.matchData = data }
                return .integer(data[0]!.lowerBound)
            }
        }
        for name in ["match-beginning", "match-end"] {
            lisp.define(name) { lisp, args in
                try arity(args, 1...1, name)
                let n = try int(args[0])
                guard n >= 0 else { throw Signal(message: "Args out of range: \(n)") }
                guard n < lisp.matchData.count, let r = lisp.matchData[n] else { return .nil }
                return .integer(name == "match-beginning" ? r.lowerBound : r.upperBound)
            }
        }
        for name in ["match-string", "match-string-no-properties"] {
            lisp.define(name) { lisp, args in
                try arity(args, 1...2, name)
                guard args.count == 2, !isNil(args[1]) else { throw Unsupported(what: "\(name) in a buffer") }
                let n = try int(args[0])
                guard n >= 0, n < lisp.matchData.count, let r = lisp.matchData[n] else { return .nil }
                return .string(try substring(try string(args[1]), r))
            }
        }
        lisp.define("replace-match") { lisp, args in
            try arity(args, 1...5, "replace-match")
            guard args.count > 3, !isNil(args[3]) else { throw Unsupported(what: "replace-match in a buffer") }
            return .string(try lisp.replaceMatch(try string(args[0]), fixedCase: args.count > 1 && !isNil(args[1]), literal: args.count > 2 && !isNil(args[2]),
                                                 in: try string(args[3]), subexp: args.count > 4 && !isNil(args[4]) ? try int(args[4]) : 0))
        }
        lisp.define("replace-regexp-in-string") { lisp, args in
            try arity(args, 3...7, "replace-regexp-in-string")
            func optional(_ i: Int) -> Sexp { i < args.count ? args[i] : .nil }
            let regexp = try string(args[0])
            let s = try string(args[2])
            let scalars = Array(s.unicodeScalars)
            func piece(_ r: Range<Int>) -> String { String(String.UnicodeScalarView(scalars[r])) }
            let l = scalars.count
            var start = isNil(optional(6)) ? 0 : try int(optional(6))
            guard start >= 0 else { throw Unsupported(what: "replace-regexp-in-string from the end") }
            var matches = ""
            let saved = lisp.matchData
            defer { lisp.matchData = saved }
            while start < l, let data = try lisp.stringMatch(regexp, s, start: .integer(start)) {
                lisp.matchData = data
                let mb = data[0]!.lowerBound
                var me = data[0]!.upperBound
                if me == mb { me = min(l, mb + 1) }
                lisp.matchData = data.map { $0.map { ($0.lowerBound - mb)..<($0.upperBound - mb) } }
                let str = piece(mb..<me)
                let rep: String
                if case .string(let text) = args[1] {
                    rep = text
                } else {
                    rep = try string(try lisp.call(args[1], [.string(try substring(str, lisp.matchData[0]!))]))
                }
                matches += piece(start..<mb)
                matches += try lisp.replaceMatch(rep, fixedCase: !isNil(optional(3)), literal: !isNil(optional(4)), in: str,
                                                 subexp: isNil(optional(5)) ? 0 : try int(optional(5)))
                start = me
            }
            guard start <= l else { throw Signal(message: "Args out of range") }
            return .string(matches + piece(start..<l))
        }
        lisp.define("regexp-quote") { _, args in
            try arity(args, 1...1, "regexp-quote")
            var out = ""
            for c in try string(args[0]).unicodeScalars {
                if "[*.\\?+^$".unicodeScalars.contains(c) { out += "\\" }
                out.unicodeScalars.append(c)
            }
            return .string(out)
        }
        lisp.define("split-string") { lisp, args in
            try arity(args, 1...4, "split-string")
            func optional(_ i: Int) -> Sexp { i < args.count ? args[i] : .nil }
            let s = try string(args[0])
            let length = s.unicodeScalars.count
            let keepNulls = isNil(optional(1)) ? false : isNil(optional(2))
            let separators = isNil(optional(1)) ? "[ \u{0C}\t\n\r\u{0B}]+" : try string(optional(1))
            let trim = isNil(optional(3)) ? nil : try string(optional(3))
            var list: [Sexp] = []
            func push(_ from: Int, _ to: Int) throws {
                var from = from
                if let trim, let data = try lisp.stringMatch(trim, s, start: .integer(from)) {
                    lisp.matchData = data
                    if data[0]!.lowerBound == from { from = data[0]!.upperBound }
                }
                guard keepNulls || from < to else { return }
                guard from <= to else { throw Signal(message: "Args out of range") }
                var this = try substring(s, from..<to)
                if let trim, let data = try lisp.stringMatch(trim + "\\'", this) {
                    lisp.matchData = data
                    if data[0]!.lowerBound < this.unicodeScalars.count { this = try substring(this, 0..<data[0]!.lowerBound) }
                }
                if keepNulls || !this.isEmpty { list.append(.string(this)) }
            }
            var start = 0
            var notFirst = false
            while true {
                let from = notFirst && start == lisp.matchData.first??.lowerBound && start < length ? start + 1 : start
                guard let data = try lisp.stringMatch(separators, s, start: .integer(from)) else { break }
                lisp.matchData = data
                guard start < length else { break }
                notFirst = true
                let thisStart = start
                start = data[0]!.upperBound
                try push(thisStart, data[0]!.lowerBound)
            }
            try push(start, length)
            return Elisp.list(list)
        }
    }
}
