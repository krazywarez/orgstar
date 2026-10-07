import Foundation
import Testing
@testable import OrgCore

/// The Lisp evaluator against Emacs: each form's `prin1` text, or `error` when it signals.
struct ElispTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    static let forms = [
        "(+ 1 2 3)", "(- 10)", "(- 10 2.5)", "(* 2 3.0)", "(/ 7 2)", "(/ -7 2)", "(/ 7 2.0)", "(/ 7 0)", "(% -7 2)", "(mod -7 2)",
        "(mod 5.5 2)", "(1+ 4)", "(abs -3.5)", "(max 1 2.0)", "(min 3 1)", "(floor 2.7)", "(floor -7 2)", "(round 2.5)",
        "(round 3.5)", "(truncate -2.7)", "(float 3)", "(= 1 1.0)", "(< 1 2 3)", "(< 1 3 2)", "(/= 1 2)", "(zerop 0.0)",
        "(eq 'a 'a)", "(equal '(1 \"a\") (list 1 \"a\"))", "(null nil)", "(not 0)", "(car '(1 2))", "(cdr '(1 2))",
        "(cdr '(1 . 2))", "(cons 1 2)", "(cons 1 '(2))", "(nth 2 '(a b c))", "(nth 5 '(a))", "(length \"héllo\")",
        "(reverse '(1 2 3))", "(append '(1) '(2) 3)", "(number-sequence 1 5 2)", "(memq 'b '(a b c))", "(member \"b\" '(\"a\" \"b\"))",
        "(assoc \"k\" '((\"k\" . 1)))", "(mapcar #'1+ '(1 2 3))", "(mapconcat #'identity '(\"a\" \"b\") \"-\")",
        "(apply #'+ 1 '(2 3))", "(funcall (lambda (x &optional y) (list x y)) 1)", "(let ((x 1) (y 2)) (+ x y))",
        "(let* ((x 1) (y (1+ x))) y)", "(let ((n 0)) (dotimes (i 4) (setq n (+ n i))) n)", "(let (r) (dolist (x '(1 2)) (push x r)) r)",
        "(cond ((= 1 2) 'a) ((= 1 1) 'b))", "(and 1 2)", "(or nil 3)", "(if nil 1 2 3)", "(when t 1 2)", "(unless t 1)",
        "(concat \"a\" \"b\" '(99))", "(format \"%d|%5.2f|%s|%S|%-4s|%x|%c|%%\" 42 3.14159 \"s\" \"q\" \"ab\" 255 65)",
        "(format \"%s %s\" 1.0 100.5)", "(format \"%d\" 2.9)", "(format \"%03d\" 7)", "(format \"%e\" 12345.678)", "(format \"%g\" 0.0001)",
        "(substring \"hello\" 1 3)", "(substring \"hello\" -3)", "(string-to-number \" 12abc\")", "(string-to-number \"1.5e2\")",
        "(string-to-number \"3.\")", "(string-to-number \"x\")", "(number-to-string 0.1)", "(number-to-string 1e21)", "(upcase \"ab\")",
        "(string= \"a\" \"a\")", "(string< \"a\" \"b\")", "(split-string \" a  b \")", "(split-string \"a,b,,c\" \",\")",
        "(string-prefix-p \"ab\" \"abc\")", "(condition-case nil (/ 1 0) (error 'caught))", "(ignore-errors (car 1))", "(car 1)",
        "(let ((x 0)) (while (< x 5) (setq x (1+ x))) x)", "(elt [1 2 3] 1)", "(aref \"abc\" 1)", "(length [1 2])", "(nthcdr 1 '(1 2 3))",
        "(delq nil '(1 nil 2))", "(cadr '(1 2 3))", "(identity \"x\")", "(capitalize \"hello world\")", "(string-trim \"  x \")",
    ]

    static func ours(_ form: String) -> String {
        guard let sexp = try? LispReader.readFirst(form).sexp else { return "read-error" }
        do {
            return Elisp.printed(try Elisp().eval(sexp), escape: true)
        } catch {
            return "error"
        }
    }

    @Test(.enabled(if: oracle))
    func matchesEmacs() throws {
        let list = "(list " + Self.forms.map { "(condition-case nil (prin1-to-string \($0)) (error \"error\"))" }.joined(separator: " ") + ")"
        let emacs = try EmacsOracle.evaluate("", "(let ((print-escape-newlines t)) \(list))")
        #expect(emacs.count == Self.forms.count)
        for (form, expected) in zip(Self.forms, emacs) {
            #expect(Self.ours(form) == expected, "\(form)")
        }
    }
}
