import Foundation

/// `org-agenda-prefix-format` for one view, compiled as `org-compile-prefix-format` does:
/// `%c` category, `%t` time, `%l` level, `%s` extra, `%e` effort, `%b` breadcrumbs, `%T` last
/// tag (Org's regexp lists only lower-case keys but matches `T` under `case-fold-search`),
/// `%i` icon (none in Orgstar), each with an optional `?` (empty when the value is), a `%-12`-style
/// width with an optional `.N` limit on categories, and a punctuation character added after a
/// non-empty value. `%(…)` forms run Lisp; they are empty here.
public struct PrefixFormat: Sendable, Equatable {
    static let directiveRegex = try! NSRegularExpression(pattern: "%(\\?)?([-+]?[0-9.]*)([ .;,:!?=|/<>]?)([cltseibT]|\\(.+?\\))")

    enum Piece: Sendable, Equatable {
        case literal(String)
        case field(key: Character, optional: Bool, width: String, punctuation: String)
    }

    let pieces: [Piece]
    /// `org-prefix-has-time`: times move out of the heading into the prefix.
    let hasTime: Bool
    /// `.N` in the category width: categories this long or longer are cut to N - 1.
    let categoryMaxLength: Int?

    public init(_ format: String) {
        let regex = Self.directiveRegex
        let ns = format as NSString
        var pieces: [Piece] = []
        var hasTime = false
        var maxLength: Int?
        var at = 0
        for m in regex.matches(in: format, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > at { pieces.append(.literal(ns.substring(with: NSRange(location: at, length: m.range.location - at)))) }
            let key = ns.substring(with: m.range(at: 4))
            let width = ns.substring(with: m.range(at: 2))
            if key.hasPrefix("(") {
                pieces.append(.field(key: "(", optional: false, width: width, punctuation: ""))
            } else {
                let k = key.first!
                if k == "t" { hasTime = true }
                if k == "c", let dot = width.firstIndex(of: ".") { maxLength = Int(width[width.index(after: dot)...].prefix { $0.isNumber }) }
                pieces.append(.field(key: k, optional: m.range(at: 1).location != NSNotFound, width: width, punctuation: ns.substring(with: m.range(at: 3))))
            }
            at = NSMaxRange(m.range)
        }
        if at < ns.length { pieces.append(.literal(ns.substring(from: at))) }
        self.pieces = pieces
        self.hasTime = hasTime
        self.categoryMaxLength = maxLength
    }

    /// The prefix for these values, by field key.
    func render(_ values: [Character: String]) -> String {
        var out = ""
        for piece in pieces {
            switch piece {
            case .literal(let s): out += s
            case .field(let key, let optional, let width, let punctuation):
                var value = values[key] ?? ""
                if key == "c", let max = categoryMaxLength, value.count >= max { value = String(value.prefix(max - 1)) }
                if value.isEmpty {
                    out += optional ? "" : Self.format("", width)
                } else {
                    out += Self.format(value + punctuation, width)
                }
            }
        }
        return out
    }

    /// Emacs `format` with `%WIDTHs` or `%-WIDTH.PRECISIONs`.
    static func format(_ s: String, _ spec: String) -> String {
        var spec = Substring(spec)
        let left = spec.first == "-"
        if left || spec.first == "+" { spec = spec.dropFirst() }
        let parts = spec.split(separator: ".", omittingEmptySubsequences: false)
        let width = Int(parts.first ?? "") ?? 0
        var value = s
        if parts.count > 1, let precision = Int(parts[1]) { value = String(value.prefix(precision)) }
        let padding = String(repeating: " ", count: max(0, width - displayWidth(value)))
        return left ? value + padding : padding + value
    }

    public static let defaults: [String: String] = [
        "agenda": " %i %-12:c%?-12t% s", "todo": " %i %-12:c", "tags": " %i %-12:c", "search": " %i %-12:c",
    ]
}
