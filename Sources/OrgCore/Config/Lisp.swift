import Foundation

/// Emacs Lisp read without evaluating: for importing settings from an Emacs configuration.
public indirect enum Sexp: Equatable, Sendable {
    case symbol(String)
    case string(String)
    case integer(Int)
    case float(Double)
    /// `?a`, as its code point.
    case character(Int)
    case list([Sexp])
    /// `(a b . c)`: the elements, then the final cdr.
    case dotted([Sexp], Sexp)
    case vector([Sexp])

    public static let `nil` = Sexp.symbol("nil")

    public var symbol: String? { if case .symbol(let s) = self { return s } else { return nil } }
    public var string: String? { if case .string(let s) = self { return s } else { return nil } }
    public var integer: Int? { if case .integer(let i) = self { return i } else { return nil } }

    /// A list's elements; `nil` is the empty list.
    public var elements: [Sexp]? {
        switch self {
        case .list(let items): items
        case .symbol("nil"): []
        default: nil
        }
    }

    /// The symbol a list starts with: `setq` for `(setq ...)`.
    public var head: String? { elements?.first?.symbol }

    /// Written back as Lisp, for reports.
    public var description: String {
        switch self {
        case .symbol(let s): return s
        case .string(let s): return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
        case .integer(let i): return String(i)
        case .float(let d): return String(d)
        case .character(let c): return "?" + (Unicode.Scalar(c).map { String(Character($0)) } ?? "")
        case .list(let items):
            if items.count == 2, let head = items[0].symbol {
                switch head {
                case "quote": return "'" + items[1].description
                case "function": return "#'" + items[1].description
                case "\\`": return "`" + items[1].description
                case ",": return "," + items[1].description
                case ",@": return ",@" + items[1].description
                default: break
                }
            }
            return "(" + items.map(\.description).joined(separator: " ") + ")"
        case .dotted(let items, let last): return "(" + items.map(\.description).joined(separator: " ") + " . " + last.description + ")"
        case .vector(let items): return "[" + items.map(\.description).joined(separator: " ") + "]"
        }
    }
}

public enum LispReader {
    public struct Form: Sendable {
        public let sexp: Sexp
        /// 1-based line where the form starts.
        public let line: Int
    }

    public struct ReadError: Error, Equatable, CustomStringConvertible {
        public let line: Int
        public let message: String
        public var description: String { "line \(line): \(message)" }
    }

    /// The top-level forms of `text`.
    public static func read(_ text: String) throws -> [Form] {
        var reader = Reader(Array(text.unicodeScalars))
        var forms: [Form] = []
        while true {
            reader.skipSpace()
            guard !reader.atEnd else { break }
            let line = reader.line
            forms.append(Form(sexp: try reader.form(), line: line))
        }
        return forms
    }

    struct Reader {
        let chars: [Unicode.Scalar]
        var index = 0
        var line = 1

        init(_ chars: [Unicode.Scalar]) { self.chars = chars }

        var atEnd: Bool { index >= chars.count }
        var peek: Unicode.Scalar? { index < chars.count ? chars[index] : nil }

        mutating func next() -> Unicode.Scalar? {
            guard index < chars.count else { return nil }
            let c = chars[index]
            index += 1
            if c == "\n" { line += 1 }
            return c
        }

        mutating func skipSpace() {
            while let c = peek {
                if c == ";" {
                    while let d = peek, d != "\n" { _ = next() }
                } else if c.properties.isWhitespace {
                    _ = next()
                } else {
                    return
                }
            }
        }

        func error(_ message: String) -> ReadError { ReadError(line: line, message: message) }

        static let delimiters: Set<Unicode.Scalar> = ["(", ")", "[", "]", "\"", "'", "`", ",", ";"]

        mutating func form() throws -> Sexp {
            skipSpace()
            guard let c = next() else { throw error("unexpected end of file") }
            switch c {
            case "(": return try list(close: ")")
            case "[":
                guard case .list(let items) = try list(close: "]") else { throw error("bad vector") }
                return .vector(items)
            case ")", "]": throw error("unexpected \(c)")
            case "\"": return .string(try string())
            case "'": return .list([.symbol("quote"), try form()])
            case "`": return .list([.symbol("\\`"), try form()])
            case ",":
                if peek == "@" {
                    _ = next()
                    return .list([.symbol(",@"), try form()])
                }
                return .list([.symbol(","), try form()])
            case "?": return .character(try character())
            case "#":
                if peek == "'" {
                    _ = next()
                    return .list([.symbol("function"), try form()])
                }
                return .symbol("#" + atom())
            default:
                index -= 1
                if c == "\n" { line -= 1 }
                return number(atom())
            }
        }

        mutating func list(close: Unicode.Scalar) throws -> Sexp {
            var items: [Sexp] = []
            while true {
                skipSpace()
                guard let c = peek else { throw error("unclosed list") }
                if c == close {
                    _ = next()
                    return .list(items)
                }
                if c == ".", index + 1 < chars.count, chars[index + 1].properties.isWhitespace || Self.delimiters.contains(chars[index + 1]) {
                    _ = next()
                    let last = try form()
                    skipSpace()
                    guard next() == close else { throw error("bad dotted list") }
                    return .dotted(items, last)
                }
                items.append(try form())
            }
        }

        mutating func string() throws -> String {
            var out = ""
            while let c = next() {
                switch c {
                case "\"": return out
                case "\\":
                    guard let e = next() else { break }
                    switch e {
                    case "n": out += "\n"
                    case "t": out += "\t"
                    case "\n": break
                    default: out.unicodeScalars.append(e)
                    }
                default:
                    out.unicodeScalars.append(c)
                }
            }
            throw error("unclosed string")
        }

        mutating func character() throws -> Int {
            guard let c = next() else { throw error("bad character") }
            guard c == "\\" else { return Int(c.value) }
            guard let e = next() else { throw error("bad character") }
            switch e {
            case "n": return 10
            case "t": return 9
            case "s": return 32
            case "e": return 27
            case "C", "M", "S", "s", "H", "A":
                if peek == "-" { _ = next(); return try character() }
                return Int(e.value)
            default: return Int(e.value)
            }
        }

        mutating func atom() -> String {
            var out = ""
            while let c = peek, !c.properties.isWhitespace, !Self.delimiters.contains(c) {
                _ = next()
                if c == "\\", let escaped = next() { out.unicodeScalars.append(escaped) } else { out.unicodeScalars.append(c) }
            }
            return out
        }

        func number(_ text: String) -> Sexp {
            if let i = Int(text.hasPrefix("+") ? String(text.dropFirst()) : text) { return .integer(i) }
            if text.contains(where: { $0 == "." || $0 == "e" }), text.first.map({ $0.isNumber || $0 == "-" || $0 == "+" || $0 == "." }) == true,
               let d = Double(text) { return .float(d) }
            return .symbol(text)
        }
    }
}
