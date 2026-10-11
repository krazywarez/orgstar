import Foundation

// `%(sexp)` in capture templates (`org-capture-expand-embedded-elisp`), evaluated by the Elisp
// subset with what capture templates call most: `format-time-string`, `current-time`,
// `read-string` and `user-full-name`, besides the subset's own functions.

extension Capture {
    /// Where each `%(` that starts a whole sexp ends, by the index of its `%`: the forms
    /// `org-capture-expand-embedded-elisp` marks. Escaped ones are left out by the caller.
    static func embeddedSexps(_ chars: [Character]) -> [Int: Int] {
        var ends: [Int: Int] = [:]
        var i = 0
        while i + 1 < chars.count {
            if chars[i] == "%", chars[i + 1] == "(", let end = sexpEnd(chars, from: i + 1) {
                ends[i] = end
                i = end
            } else {
                i += 1
            }
        }
        return ends
    }

    /// `scan-sexps` over a list starting at `start`: the index after its closing paren.
    static func sexpEnd(_ chars: [Character], from start: Int) -> Int? {
        var depth = 0
        var i = start
        while i < chars.count {
            switch chars[i] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return i + 1 }
            case "\"":
                i += 1
                while i < chars.count, chars[i] != "\"" { i += chars[i] == "\\" ? 2 : 1 }
                guard i < chars.count else { return nil }
            case "?":
                // A character: `?a`, `?\)`.
                i += chars.indices.contains(i + 1) && chars[i + 1] == "\\" ? 2 : 1
            case "\\":
                i += 1
            case ";":
                while i < chars.count, chars[i] != "\n" { i += 1 }
            default: break
            }
            i += 1
        }
        return nil
    }

    /// `org-capture--expand-keyword-in-embedded-elisp`: symbols such as `%:link` become the
    /// link property's value.
    static func expandKeywords(_ sexp: Sexp, _ context: CaptureContext) -> Sexp {
        switch sexp {
        case .list(let items): return .list(items.map { expandKeywords($0, context) })
        case .dotted(let items, let last): return .dotted(items.map { expandKeywords($0, context) }, expandKeywords(last, context))
        case .symbol(let name):
            guard let range = name.range(of: "%:") else { return sexp }
            let key = String(name[range.upperBound...])
            switch key {
            case _ where context.linkProperties[key] != nil: return .string(context.linkProperties[key]!)
            case "annotation": return .string(context.annotation)
            case "initial": return .string(context.initial)
            default: return sexp
            }
        default: return sexp
        }
    }

    /// Evaluates `%(…)` forms, the text from `(` to `)`, in order. `answers` reply to
    /// `read-string` in order; the questions it asks and the answers it took come back.
    final class Embedded {
        let context: CaptureContext
        var answers: ArraySlice<String>
        var questions: [Question] = []
        var used = 0
        let lisp = Elisp()

        init(_ context: CaptureContext, answers: [String]) {
            self.context = context
            self.answers = answers[...]
            lisp.set("user-full-name", .string(context.userName))
            lisp.define("user-full-name") { [context] _, _ in .string(context.userName) }
            lisp.define("current-time") { [context] _, _ in Self.time(context.now) }
            lisp.define("format-time-string") { [context] _, args in
                guard let format = args.first?.string else { throw Elisp.Signal(message: "Wrong type argument: stringp, \(args.first?.description ?? "nil")") }
                let date = try args.count > 1 && !Elisp.isNil(args[1]) ? Self.date(args[1]) : context.now
                var at = context
                at.now = date
                return .string(Capture.strftime(format, at))
            }
            lisp.define("read-string") { [unowned self] _, args in
                let prompt = args.first?.string ?? ""
                let initial = args.count > 1 ? args[1].string : nil
                let fallback = args.count > 3 ? args[3].string : nil
                questions.append(Question(prompt: prompt.replacingOccurrences(of: ":? *$", with: "", options: .regularExpression),
                                          defaultValue: fallback ?? initial ?? "", choices: []))
                guard let answer = self.answers.popFirst() else { return .string(fallback ?? initial ?? "") }
                used += 1
                return .string(answer.isEmpty ? fallback ?? initial ?? "" : answer)
            }
        }

        /// `(HIGH LOW USEC PSEC)`.
        static func time(_ date: Date) -> Sexp {
            let seconds = Int(date.timeIntervalSince1970.rounded(.down))
            let micro = Int((date.timeIntervalSince1970 - Double(seconds)) * 1_000_000)
            return .list([.integer(seconds >> 16), .integer(seconds & 0xFFFF), .integer(micro), .integer(0)])
        }

        static func date(_ time: Sexp) throws -> Date {
            if let seconds = time.integer { return Date(timeIntervalSince1970: Double(seconds)) }
            guard let parts = time.elements, parts.count >= 2, let high = parts[0].integer, let low = parts[1].integer else {
                throw Elisp.Unsupported(what: "time value \(time.description)")
            }
            let micro = parts.count > 2 ? Double(parts[2].integer ?? 0) / 1_000_000 : 0
            return Date(timeIntervalSince1970: Double(high << 16 + low) + micro)
        }

        /// The value to insert for the form `text`: a string, or "" for nil.
        func evaluate(_ text: String) -> Result<String, Failure> {
            let form: Sexp
            do {
                guard let read = try LispReader.read(text).first?.sexp else { return .success("") }
                form = read
            } catch {
                return .failure(.message("Can't read the template's \(text): \(error)"))
            }
            do {
                let result = try lisp.eval(expandKeywords(form, context))
                if Elisp.isNil(result) { return .success("") }
                guard let string = result.string else { return .failure(.message("Capture template sexp `\(form.description)' must evaluate to string or nil")) }
                return .success(string)
            } catch let unsupported as Elisp.Unsupported {
                return .failure(.message("Template %\(form.description) needs \(unsupported.what), which orgstar's Lisp doesn't have."))
            } catch {
                return .failure(.message("Template %\(form.description): \(error)"))
            }
        }
    }
}
