import Foundation
import OrgCore

/// Why a table's formulas go to Emacs, `Calc.Unsupported`'s reason, in the app's language.
public enum TableReason {
    /// The reason translated, or as it is when it's one this doesn't know.
    public static func localized(_ reason: String) -> String { translated(reason) ?? reason }

    /// Nil for a reason not known here.
    static func translated(_ reason: String) -> String? {
        if reason.hasPrefix("Lisp ") {
            let inner = String(reason.dropFirst("Lisp ".count))
            guard let what = lisp(inner) else { return nil }
            return String(localized: "Lisp \(what)", comment: "Why a table needs Emacs: something its Lisp formula does")
        }
        if let fixed = fixed(reason) { return fixed }
        func value(_ prefix: String) -> String? { reason.hasPrefix(prefix) ? String(reason.dropFirst(prefix.count)) : nil }
        if let name = value("function ") { return String(localized: "function \(name)", comment: "Why a table needs Emacs: a Calc function") }
        if let name = value("variable ") { return String(localized: "variable \(name)", comment: "Why a table needs Emacs: a Calc variable") }
        if let text = value("non-numeric field ") { return String(localized: "non-numeric field \(text)", comment: "Why a table needs Emacs") }
        if let number = value("number size ") { return String(localized: "number size \(number)", comment: "Why a table needs Emacs: a number too large") }
        if let flag = value("format flag ") { return String(localized: "format flag \(flag)", comment: "Why a table needs Emacs: a format specifier flag") }
        return nil
    }

    /// `Elisp.Unsupported`'s reasons.
    static func lisp(_ what: String) -> String? {
        let comment: StaticString = "Why a table needs Emacs: something a Lisp formula does"
        switch what {
        case "integer size": return fixed(what)
        case "case folding past ASCII": return String(localized: "case folding past ASCII", comment: comment)
        case "cl-loop destructuring": return String(localized: "cl-loop destructuring", comment: comment)
        case "cl-loop with collect and sum": return String(localized: "cl-loop with collect and sum", comment: comment)
        case "cl-loop without for": return String(localized: "cl-loop without for", comment: comment)
        case "float times": return String(localized: "float times", comment: comment)
        case "float-time of picoseconds": return String(localized: "float-time of picoseconds", comment: comment)
        case "org-time-string-to-absolute with a day": return String(localized: "org-time-string-to-absolute with a day", comment: comment)
        case "random with a seed": return String(localized: "random with a seed", comment: comment)
        case "regexp classes on text past ASCII": return String(localized: "regexp classes on text past ASCII", comment: comment)
        case "replace-match case past ASCII": return String(localized: "replace-match case past ASCII", comment: comment)
        case "replace-match in a buffer": return String(localized: "replace-match in a buffer", comment: comment)
        case "replace-regexp-in-string from the end": return String(localized: "replace-regexp-in-string from the end", comment: comment)
        case "seq-uniq with a test": return String(localized: "seq-uniq with a test", comment: comment)
        case "sort on a string": return String(localized: "sort on a string", comment: comment)
        default: break
        }
        func value(_ prefix: String) -> String? { what.hasPrefix(prefix) ? String(what.dropFirst(prefix.count)) : nil }
        func split(_ text: String, _ separator: String) -> (String, String)? {
            guard let range = text.range(of: separator) else { return nil }
            return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
        }
        if let name = value("function ") { return String(localized: "function \(name)", comment: "Why a table needs Emacs: a Calc function") }
        if let time = value("time value ") { return String(localized: "time value \(time)", comment: "Why a table needs Emacs: a Lisp time value") }
        if let number = value("date number ") { return String(localized: "date number \(number)", comment: "Why a table needs Emacs: a Lisp date number") }
        if let text = value("date-to-time of ") { return String(localized: "date-to-time of \(text)", comment: comment) }
        if let parts = value("date ") { return String(localized: "date \(parts)", comment: comment) }
        if let text = value("time string ") { return String(localized: "time string \(text)", comment: comment) }
        if let zone = value("format-time-string zone ") { return String(localized: "format-time-string zone \(zone)", comment: comment) }
        if let code = value("format-time-string ") { return String(localized: "format-time-string \(code)", comment: comment) }
        if let clause = value("cl-loop ") { return String(localized: "cl-loop \(clause)", comment: comment) }
        if let pattern = value("pcase pattern ") { return String(localized: "pcase pattern \(pattern)", comment: comment) }
        if let name = value("let-alist ") { return String(localized: "let-alist \(name)", comment: comment) }
        if let text = value("string-width of ") { return String(localized: "string-width of \(text)", comment: comment) }
        if let rest = value("regexp "), let parts = split(rest, " in ") {
            return String(localized: "regexp \(parts.0) in \(parts.1)", comment: "Why a table needs Emacs: part of a Lisp regular expression")
        }
        if let rest = value("value< on "), let parts = split(rest, " and ") {
            return String(localized: "value< on \(parts.0) and \(parts.1)", comment: comment)
        }
        if what.hasSuffix(" on a place") {
            let name = String(what.dropLast(" on a place".count))
            return String(localized: "\(name) on a place", comment: "Why a table needs Emacs: a Lisp function used on a variable")
        }
        if what.hasSuffix(" on a list another value shares") {
            let name = String(what.dropLast(" on a list another value shares".count))
            return String(localized: "\(name) on a list another value shares", comment: "Why a table needs Emacs: a Lisp function that changes a shared list")
        }
        if what.hasSuffix(" in a buffer") {
            let name = String(what.dropLast(" in a buffer".count))
            return String(localized: "\(name) in a buffer", comment: comment)
        }
        if let parts = split(what, " with ") { return String(localized: "\(parts.0) with \(parts.1)", comment: comment) }
        return nil
    }

    static func fixed(_ reason: String) -> String? {
        let comment: StaticString = "Why a table needs Emacs"
        switch reason {
        case "arguments": return String(localized: "arguments", comment: comment)
        case "calc precision": return String(localized: "calc precision", comment: comment)
        case "chained comparison": return String(localized: "chained comparison", comment: comment)
        case "comparison with nan": return String(localized: "comparison with nan", comment: comment)
        case "complex result": return String(localized: "complex result", comment: comment)
        case "condition": return String(localized: "condition", comment: comment)
        case "constants that refer to themselves": return String(localized: "constants that refer to themselves", comment: comment)
        case "date arithmetic": return String(localized: "date arithmetic", comment: comment)
        case "date syntax": return String(localized: "date syntax", comment: comment)
        case "division by zero": return String(localized: "division by zero", comment: comment)
        case "duration size": return String(localized: "duration size", comment: comment)
        case "empty vector": return String(localized: "empty vector", comment: comment)
        case "formula range": return String(localized: "formula range", comment: comment)
        case "formula syntax": return String(localized: "formula syntax", comment: comment)
        case "infinite result": return String(localized: "infinite result", comment: comment)
        case "integer size": return String(localized: "integer size", comment: comment)
        case "logarithm domain": return String(localized: "logarithm domain", comment: comment)
        case "number": return String(localized: "number", comment: comment)
        case "number size": return String(localized: "number size", comment: comment)
        case "range outside row": return String(localized: "range outside row", comment: comment)
        case "reference outside table": return String(localized: "reference outside table", comment: comment)
        case "remote table name from a range": return String(localized: "remote table name from a range", comment: comment)
        case "row out of range": return String(localized: "row out of range", comment: comment)
        case "table position": return String(localized: "table position", comment: comment)
        case "variance of one value": return String(localized: "variance of one value", comment: comment)
        case "vector argument": return String(localized: "vector argument", comment: comment)
        case "vector arithmetic": return String(localized: "vector arithmetic", comment: comment)
        case "vector result": return String(localized: "vector result", comment: comment)
        default: return nil
        }
    }
}
