import Foundation
import Testing
@testable import OrgCore

/// `elisp:` links evaluated in `Elisp`, with the message `org-link--open-elisp` shows.
struct ElispLinkTests {
    static let forms = [
        "(+ 1 2)", "(list 1 \"a\" 'b 2.5)", "(concat \"a\" \"b\")", "(message \"hi\")", "(let ((x 2)) (* x x))",
        "(mapcar (lambda (n) (* n 10)) '(1 2 3))", "nil", "(car 1)", "(/ 1 0)", "(error \"Nope %d\" 3)", "(format \"%S\" \"q\")",
        "(org-lookup-first 2 '(1 2 3) '(a b c))", "(org-lookup-all 1 '(1 2 1) '(x y z))", "(format \"%S\" '(lambda () 1))",
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
        // Emacs 31 prints a function made under dynamic binding as `#[nil (1) nil]`.
        for form in ["(let ((f (lambda () 1))) f)", "(prin1-to-string (lambda () 1))", "(format \"%S\" (lambda () 1))", "(car (lambda () 1))"] {
            #expect(Links.evaluateElisp(form) == "This link uses Emacs Lisp that runs only in Emacs.", "\(form)")
        }
    }
}
