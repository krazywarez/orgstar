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
        if what == "integer size" { return fixed(what) }
        func value(_ prefix: String) -> String? { what.hasPrefix(prefix) ? String(what.dropFirst(prefix.count)) : nil }
        if let name = value("function ") { return String(localized: "function \(name)", comment: "Why a table needs Emacs: a Calc function") }
        if let time = value("time value ") { return String(localized: "time value \(time)", comment: "Why a table needs Emacs: a Lisp time value") }
        if let number = value("date number ") { return String(localized: "date number \(number)", comment: "Why a table needs Emacs: a Lisp date number") }
        if what.hasSuffix(" on a place") {
            let name = String(what.dropLast(" on a place".count))
            return String(localized: "\(name) on a place", comment: "Why a table needs Emacs: a Lisp function used on a variable")
        }
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
