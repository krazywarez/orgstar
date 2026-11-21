import Foundation
import Testing
@testable import OrgCore

/// `elisp:` links evaluated in `Elisp`, with the message `org-link--open-elisp` shows.
struct ElispLinkTests {
    static let forms = [
        "(+ 1 2)", "(list 1 \"a\" 'b 2.5)", "(concat \"a\" \"b\")", "(message \"hi\")", "(let ((x 2)) (* x x))",
        "(mapcar (lambda (n) (* n 10)) '(1 2 3))", "nil", "(car 1)", "(/ 1 0)", "(error \"Nope %d\" 3)", "(format \"%S\" \"q\")",
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func matchesEmacs() throws {
        let list = "(list " + Self.forms.map { form in
            let quoted = form.debugDescription
            return "(condition-case e (format \"%s => %s\" \(quoted) (eval (read \(quoted)))) (error (error-message-string e)))"
        }.joined(separator: " ") + ")"
        let emacs = try EmacsOracle.evaluate("", list)
        #expect(emacs.count == Self.forms.count)
        for (form, expected) in zip(Self.forms, emacs) {
            #expect(Links.evaluateElisp(form) == expected, "\(form)")
        }
    }

    @Test func refusesWhatOnlyEmacsHas() {
        #expect(Links.evaluateElisp("(org-agenda nil \"a\")") == "This link uses Emacs Lisp that runs only in Emacs.")
    }
}
