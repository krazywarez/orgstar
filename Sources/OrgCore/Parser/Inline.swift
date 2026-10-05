/// Characters allowed before an emphasis opener, besides whitespace and the start of the run.
private let emphasisPre: Set<Unicode.Scalar> = ["-", "(", "{", "'", "\""]

/// Characters allowed after an emphasis closer, besides whitespace and the end of the run.
private let emphasisPost: Set<Unicode.Scalar> = ["-", ".", ",", ":", "!", "?", ";", "'", "\"", ")", "}", "\\", "["]

private let angleLinkSchemes: Set<String> = [
    "http", "https", "mailto", "file", "id", "doi", "ftp", "news", "shell", "elisp", "info", "help", "attachment",
]

private let plainLinkPrefixes: [[Unicode.Scalar]] = ["https://", "http://", "mailto:", "file:"].map { Array($0.unicodeScalars) }

private func emphasisKind(_ c: Unicode.Scalar) -> SyntaxKind? {
    switch c {
    case "*": .bold
    case "/": .italic
    case "_": .underline
    case "+": .strikeThrough
    case "=": .verbatim
    case "~": .code
    default: nil
    }
}

func isNewline(_ c: Unicode.Scalar) -> Bool {
    c == "\n"
}

func isSpace(_ c: Unicode.Scalar) -> Bool {
    c.isASCII ? (c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0B}" || c == "\u{0C}") : c.properties.isWhitespace
}

func isWordScalar(_ c: Unicode.Scalar) -> Bool {
    if c.isASCII {
        let v = c.value
        return (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
    }
    return c.properties.isAlphabetic || c.properties.numericType != nil
}

enum InlineMatch {
    case emphasis(SyntaxKind, open: Int, close: Int)
    case link(path: Range<Int>, description: Range<Int>?, whole: Range<Int>)
    case object(SyntaxKind, Range<Int>)

    var end: Int {
        switch self {
        case .emphasis(_, _, let close): close + 1
        case .link(_, _, let whole): whole.upperBound
        case .object(_, let range): range.upperBound
        }
    }
}

/// Turns a run of text into text, newline and object tokens. Every scalar ends up in exactly
/// one token. Works on unicode scalars: every recognizer starts on an ASCII character, so
/// grapheme clusters never need to be formed.
struct InlineScanner {
    let chars: [Unicode.Scalar]
    /// Where each scalar starts in `source`, plus its end, so token text is sliced from the
    /// source instead of rebuilt scalar by scalar.
    let source: Substring.UnicodeScalarView
    let starts: [String.Index]

    init(_ text: Substring) {
        source = text.unicodeScalars
        var chars: [Unicode.Scalar] = []
        var starts: [String.Index] = []
        chars.reserveCapacity(text.utf8.count)
        starts.reserveCapacity(text.utf8.count + 1)
        var index = source.startIndex
        while index < source.endIndex {
            chars.append(source[index])
            starts.append(index)
            index = source.index(after: index)
        }
        starts.append(source.endIndex)
        self.chars = chars
        self.starts = starts
    }

    func scan(_ range: Range<Int>, into b: inout GreenBuilder, inLink: Bool = false) {
        var textStart = range.lowerBound
        var i = range.lowerBound
        while i < range.upperBound {
            if Self.mayStartObject(chars[i]), let match = match(at: i, in: range, inLink: inLink) {
                emitText(textStart..<i, into: &b)
                emit(match, into: &b, inLink: inLink)
                i = match.end
                textStart = i
            } else {
                i += 1
            }
        }
        emitText(textStart..<range.upperBound, into: &b)
    }

    /// The first characters any recognizer accepts.
    static func mayStartObject(_ c: Unicode.Scalar) -> Bool {
        switch c {
        case "[", "<", "{", "\\", "^", "s", "h", "m", "f", "*", "/", "_", "+", "=", "~": true
        default: false
        }
    }

    /// Text with each line break as its own newline token; "\r\n" stays one token.
    func emitText(_ range: Range<Int>, into b: inout GreenBuilder) {
        var start = range.lowerBound
        var k = range.lowerBound
        while k < range.upperBound {
            if chars[k] == "\n" {
                let breakStart = k > start && chars[k - 1] == "\r" ? k - 1 : k
                if start < breakStart { b.token(.text, string(start..<breakStart)) }
                b.token(.newline, string(breakStart..<(k + 1)))
                start = k + 1
            }
            k += 1
        }
        if start < range.upperBound { b.token(.text, string(start..<range.upperBound)) }
    }

    func emit(_ match: InlineMatch, into b: inout GreenBuilder, inLink: Bool) {
        switch match {
        case .emphasis(let kind, let open, let close):
            b.start(kind)
            b.token(.marker, string(open..<(open + 1)))
            if kind == .verbatim || kind == .code {
                emitText((open + 1)..<close, into: &b)
            } else {
                scan((open + 1)..<close, into: &b, inLink: inLink)
            }
            b.token(.marker, string(close..<(close + 1)))
            b.finish()
        case .link(let path, let description, let whole):
            b.start(.link)
            b.token(.marker, string(whole.lowerBound..<path.lowerBound))
            b.token(.linkPath, string(path))
            if let description {
                b.token(.marker, string(path.upperBound..<description.lowerBound))
                b.start(.linkDescription)
                scan(description, into: &b, inLink: true)
                b.finish()
                b.token(.marker, string(description.upperBound..<whole.upperBound))
            } else {
                b.token(.marker, string(path.upperBound..<whole.upperBound))
            }
            b.finish()
        case .object(let kind, let range):
            b.start(kind)
            emitText(range, into: &b)
            b.finish()
        }
    }

    func string(_ range: Range<Int>) -> String {
        String(source[starts[range.lowerBound]..<starts[range.upperBound]])
    }

    func hasPrefix(_ s: [Unicode.Scalar], at i: Int, _ limit: Int) -> Bool {
        guard i + s.count <= limit else { return false }
        for (offset, c) in s.enumerated() where chars[i + offset] != c { return false }
        return true
    }

    func hasPrefix(_ s: String, at i: Int, _ limit: Int) -> Bool {
        hasPrefix(Array(s.unicodeScalars), at: i, limit)
    }

    // MARK: - Recognizers

    func match(at i: Int, in range: Range<Int>, inLink: Bool) -> InlineMatch? {
        let limit = range.upperBound
        let previous: Unicode.Scalar? = i > range.lowerBound ? chars[i - 1] : nil
        let afterWord = previous.map(isWordScalar) ?? false

        switch chars[i] {
        case "[":
            if !inLink, let link = bracketLink(i, limit) { return link }
            if let end = footnoteReference(i, limit) { return .object(.footnoteReference, i..<end) }
            if let end = scanTimestamp(chars, at: i, limit: limit)?.end { return .object(.timestamp, i..<end) }
            if let end = statisticsCookie(i, limit) { return .object(.statisticsCookie, i..<end) }
        case "<":
            if let end = scanTimestamp(chars, at: i, limit: limit)?.end { return .object(.timestamp, i..<end) }
            if let end = target(i, limit) { return .object(.target, i..<end) }
            if !inLink, let end = angleLink(i, limit) { return .object(.link, i..<end) }
        case "{":
            if let end = macro(i, limit) { return .object(.macro, i..<end) }
        case "\\":
            if let end = lineBreak(i, limit) { return .object(.lineBreak, i..<end) }
            if let end = latexFragment(i, limit) { return .object(.latexFragment, i..<end) }
        case "^":
            if afterWord, let end = superscript(i, limit) { return .object(.superscript, i..<end) }
        case "s":
            if !afterWord, let end = inlineSourceBlock(i, limit) { return .object(.inlineSourceBlock, i..<end) }
        case "h", "m", "f":
            if !inLink, !afterWord, let end = plainLink(i, limit) { return .object(.link, i..<end) }
        default:
            break
        }

        if let kind = emphasisKind(chars[i]),
           previous.map({ isSpace($0) || emphasisPre.contains($0) }) ?? true,
           let close = emphasisClose(i, limit) {
            return .emphasis(kind, open: i, close: close)
        }
        return nil
    }

    /// org's emphasis rules: the body neither starts nor ends with whitespace, spans at most
    /// one line break, and the closer is followed by whitespace, punctuation or the end.
    func emphasisClose(_ i: Int, _ limit: Int) -> Int? {
        let marker = chars[i]
        guard i + 1 < limit, !isSpace(chars[i + 1]) else { return nil }
        var newlines = 0
        var j = i + 1
        while j < limit {
            if isNewline(chars[j]) {
                newlines += 1
                if newlines > 1 { return nil }
            } else if chars[j] == marker, j > i + 1, !isSpace(chars[j - 1]) {
                if j + 1 == limit || isSpace(chars[j + 1]) || emphasisPost.contains(chars[j + 1]) { return j }
            }
            j += 1
        }
        return nil
    }

    /// `[[path]]` or `[[path][description]]`.
    func bracketLink(_ i: Int, _ limit: Int) -> InlineMatch? {
        guard i + 1 < limit, chars[i + 1] == "[" else { return nil }
        var j = i + 2
        while j < limit, chars[j] != "]" {
            if chars[j] == "[" || isNewline(chars[j]) { return nil }
            if chars[j] == "\\", j + 1 < limit { j += 1 }
            j += 1
        }
        guard j > i + 2, j + 1 < limit else { return nil }
        let path = (i + 2)..<j
        if chars[j + 1] == "]" { return .link(path: path, description: nil, whole: i..<(j + 2)) }
        guard chars[j + 1] == "[" else { return nil }
        let descriptionStart = j + 2
        var depth = 0
        var k = descriptionStart
        while k < limit {
            if chars[k] == "[" {
                depth += 1
            } else if chars[k] == "]" {
                if depth == 0 { break }
                depth -= 1
            }
            k += 1
        }
        guard k > descriptionStart, k + 1 < limit, chars[k + 1] == "]" else { return nil }
        return .link(path: path, description: descriptionStart..<k, whole: i..<(k + 2))
    }

    /// `[fn:label]`, `[fn:label:definition]` or `[fn::definition]`.
    func footnoteReference(_ i: Int, _ limit: Int) -> Int? {
        guard hasPrefix("[fn:", at: i, limit) else { return nil }
        var j = i + 4
        while j < limit, isWordScalar(chars[j]) || chars[j] == "_" || chars[j] == "-" { j += 1 }
        guard j < limit else { return nil }
        if chars[j] == "]" { return j > i + 4 ? j + 1 : nil }
        guard chars[j] == ":" else { return nil }
        var depth = 0
        j += 1
        while j < limit {
            if chars[j] == "[" {
                depth += 1
            } else if chars[j] == "]" {
                if depth == 0 { return j + 1 }
                depth -= 1
            }
            j += 1
        }
        return nil
    }

    /// `[1/3]`, `[/]`, `[50%]` or `[%]`.
    func statisticsCookie(_ i: Int, _ limit: Int) -> Int? {
        var j = i + 1
        while j < limit, isASCIIDigit(chars[j]) { j += 1 }
        guard j < limit else { return nil }
        if chars[j] == "%" {
            j += 1
        } else if chars[j] == "/" {
            j += 1
            while j < limit, isASCIIDigit(chars[j]) { j += 1 }
        } else {
            return nil
        }
        guard j < limit, chars[j] == "]" else { return nil }
        return j + 1
    }

    /// `<<target>>`.
    func target(_ i: Int, _ limit: Int) -> Int? {
        guard hasPrefix("<<", at: i, limit), i + 2 < limit, chars[i + 2] != "<" else { return nil }
        let start = i + 2
        var j = start
        while j < limit, chars[j] != ">" {
            if chars[j] == "<" || isNewline(chars[j]) { return nil }
            j += 1
        }
        guard j > start, j + 1 < limit, chars[j + 1] == ">",
              !isSpace(chars[start]), !isSpace(chars[j - 1]) else { return nil }
        return j + 2
    }

    /// `<scheme:path>` for a known scheme.
    func angleLink(_ i: Int, _ limit: Int) -> Int? {
        var j = i + 1
        while j < limit, chars[j].properties.isAlphabetic { j += 1 }
        guard j < limit, chars[j] == ":", angleLinkSchemes.contains(string((i + 1)..<j).lowercased()) else { return nil }
        j += 1
        let bodyStart = j
        while j < limit, chars[j] != ">" {
            if chars[j] == "<" || isNewline(chars[j]) { return nil }
            j += 1
        }
        guard j < limit, j > bodyStart else { return nil }
        return j + 1
    }

    /// A bare URL. Trailing sentence punctuation stays outside the link.
    func plainLink(_ i: Int, _ limit: Int) -> Int? {
        guard let prefix = plainLinkPrefixes.first(where: { hasPrefix($0, at: i, limit) }) else { return nil }
        let bodyStart = i + prefix.count
        var j = bodyStart
        while j < limit, !isSpace(chars[j]), !"()<>[]\"".unicodeScalars.contains(chars[j]) { j += 1 }
        while j > bodyStart, ".,;:!?'".unicodeScalars.contains(chars[j - 1]) { j -= 1 }
        return j > bodyStart ? j : nil
    }

    /// `{{{name}}}` or `{{{name(arguments)}}}`.
    func macro(_ i: Int, _ limit: Int) -> Int? {
        guard hasPrefix("{{{", at: i, limit) else { return nil }
        var j = i + 3
        guard j < limit, chars[j].properties.isAlphabetic else { return nil }
        while j < limit, isWordScalar(chars[j]) || chars[j] == "-" || chars[j] == "_" { j += 1 }
        if j < limit, chars[j] == "(" {
            var k = j + 1
            while k < limit, !hasPrefix(")}}}", at: k, limit) {
                if isNewline(chars[k]) { return nil }
                k += 1
            }
            return k < limit ? k + 4 : nil
        }
        return hasPrefix("}}}", at: j, limit) ? j + 3 : nil
    }

    /// `\\` at the end of a line, before optional trailing blanks. The line break stays outside.
    func lineBreak(_ i: Int, _ limit: Int) -> Int? {
        guard hasPrefix("\\\\", at: i, limit) else { return nil }
        var j = i + 2
        while j < limit, chars[j] == " " || chars[j] == "\t" { j += 1 }
        if j + 1 < limit, chars[j] == "\r", chars[j + 1] == "\n" { return j }
        guard j == limit || isNewline(chars[j]) else { return nil }
        return j
    }

    /// `\(...\)` or `\[...\]`.
    func latexFragment(_ i: Int, _ limit: Int) -> Int? {
        guard i + 1 < limit else { return nil }
        let closer: String
        switch chars[i + 1] {
        case "(": closer = "\\)"
        case "[": closer = "\\]"
        default: return nil
        }
        let closing = Array(closer.unicodeScalars)
        var j = i + 2
        while j < limit {
            if hasPrefix(closing, at: j, limit) { return j + 2 }
            j += 1
        }
        return nil
    }

    /// `^word` or `^{group}` after a letter or digit.
    func superscript(_ i: Int, _ limit: Int) -> Int? {
        var j = i + 1
        guard j < limit else { return nil }
        if chars[j] == "{" {
            j += 1
            while j < limit, chars[j] != "}" {
                if isNewline(chars[j]) { return nil }
                j += 1
            }
            return j < limit ? j + 1 : nil
        }
        let start = j
        while j < limit, isWordScalar(chars[j]) { j += 1 }
        return j > start ? j : nil
    }

    /// `src_lang{body}` or `src_lang[headers]{body}`, on one line, with balanced braces.
    func inlineSourceBlock(_ i: Int, _ limit: Int) -> Int? {
        guard hasPrefix("src_", at: i, limit) else { return nil }
        var j = i + 4
        let languageStart = j
        while j < limit, !isSpace(chars[j]), chars[j] != "[", chars[j] != "{" { j += 1 }
        guard j > languageStart, j < limit else { return nil }
        if chars[j] == "[" {
            while j < limit, chars[j] != "]" {
                if isNewline(chars[j]) { return nil }
                j += 1
            }
            guard j < limit else { return nil }
            j += 1
        }
        guard j < limit, chars[j] == "{" else { return nil }
        var depth = 0
        while j < limit {
            if isNewline(chars[j]) { return nil }
            if chars[j] == "{" {
                depth += 1
            } else if chars[j] == "}" {
                depth -= 1
                if depth == 0 { return j + 1 }
            }
            j += 1
        }
        return nil
    }
}

extension Parser {
    mutating func inline(_ text: Substring) {
        let scanner = InlineScanner(text)
        scanner.scan(0..<scanner.chars.count, into: &builder)
    }
}
