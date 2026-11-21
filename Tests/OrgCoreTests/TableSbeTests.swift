import Foundation
import Testing
@testable import OrgCore

/// `org-sbe` in Lisp table formulas, compared with Emacs.
struct TableSbeTests {
    static let blocks = """
        #+NAME: square
        #+begin_src emacs-lisp :var n=2
        (* n n)
        #+end_src

        #+NAME: greet
        #+begin_src emacs-lisp :var who="x"
        (concat "hi " who)
        #+end_src

        #+NAME: lst
        #+begin_src emacs-lisp
        '(a "b" 1 2.5)
        #+end_src

        #+NAME: sym
        #+begin_src emacs-lisp
        'foo
        #+end_src

        #+NAME: tbl
        #+begin_src emacs-lisp
        '((1 2) hline (3 4))
        #+end_src

        #+NAME: rules
        #+begin_src emacs-lisp
        '((1 2) hline (3 4) hline (5 6))
        #+end_src

        #+NAME: two
        #+begin_src emacs-lisp :var a=1 b=2
        (list a b)
        #+end_src

        #+NAME: out
        #+begin_src emacs-lisp :results output :var x=1
        (princ (format "  x is %s\\n" x))
        #+end_src

        #+NAME: quad
        #+begin_src emacs-lisp :var x=square(n=3)
        (* x 2)
        #+end_src

        #+NAME: oops
        #+begin_src emacs-lisp
        (car 1)
        #+end_src

        #+NAME: data
        | k | v |
        |---+---|
        | a | 1 |
        | b | 2.5 |

        #+NAME: items
        - one
        - 2


        """

    static let tables = [
        blocks + "| n | sq | sqN | g | g$ | lst | sym |\n|---+----+-----+---+----+-----+-----|\n| 3 | | | | | | |\n| abc | | | | | | |\n| 2.5 | | | | | | |\n"
            + "#+TBLFM: $2='(org-sbe \"square\" (n $1))::$3='(org-sbe square (n $1));N::$4='(org-sbe greet (who $1))::$5='(org-sbe greet (who $$1))::$6='(org-sbe lst)::$7='(org-sbe sym)\n",
        blocks + "| n | tbl | rules | none | str | noargs |\n|---+-----+-------+------+-----+--------|\n| 3 | | | | | | |\n| abc | | | | | | |\n"
            + "#+TBLFM: $2='(org-sbe tbl)::$3='(org-sbe rules)::$4='(org-sbe nope)::$5='(org-sbe greet (who \"\\\"q r\\\"\"))::$6='(org-sbe square)\n",
        blocks + "| n | out | quad | oops | data | items | verbatim | empty | two |\n|---+-----+------+------+------+-------+----------+-------+-----|\n| 4 | | | | | | | | |\n"
            + "#+TBLFM: $2='(org-sbe out (x $1))::$3='(org-sbe quad)::$4='(org-sbe oops)::$5='(org-sbe data)::$6='(org-sbe items)::$7='(org-sbe greet \":results verbatim\" (who $$1))::$8='(org-sbe \"\")::$9='(org-sbe two (a $1 $1) (b $$1))\n",
        blocks + "| n | sum |\n|---+-----|\n| 2 | |\n| 5 | |\n#+TBLFM: $2='(+ 1 (string-to-number (org-sbe square (n $1))))\n",
        // `:lexical t` and `yes` are lexical; a name under a COMMENT heading, or on a keyword
        // that names nothing, is skipped.
        "#+NAME: lext\n#+begin_src emacs-lisp :lexical t\n(let ((f (let ((y 2)) (lambda () y)))) (let ((y 3)) (funcall f)))\n#+end_src\n\n"
            + "#+NAME: lexy\n#+begin_src emacs-lisp :lexical yes\n(let ((f (let ((y 2)) (lambda () y)))) (let ((y 3)) (funcall f)))\n#+end_src\n\n"
            + "#+NAME: dyn\n#+begin_src emacs-lisp :lexical no\n(let ((f (let ((y 2)) (lambda () y)))) (let ((y 3)) (funcall f)))\n#+end_src\n\n"
            + "#+NAME: orph\n\n#+NAME: orph\n#+begin_src emacs-lisp\n\"real\"\n#+end_src\n\n"
            + "| t | yes | no | cm | orph |\n|---+-----+----+----+------|\n| | | | | |\n"
            + "#+TBLFM: $1='(org-sbe lext)::$2='(org-sbe lexy)::$3='(org-sbe dyn)::$4='(org-sbe cm)::$5='(org-sbe orph)\n\n"
            + "* COMMENT Old\n#+NAME: cm\n| old |\n\n* New\n#+NAME: cm\n#+begin_src emacs-lisp\n\"new\"\n#+end_src\n",
        // A quoted lambda stays a list, a name in another case names nothing, and a lambda
        // can be a lookup's predicate.
        "#+NAME: quo\n#+begin_src emacs-lisp :lexical yes\n(list 1 '(lambda () 1))\n#+end_src\n\n"
            + "| q | up | lk |\n|---+----+----|\n| | | |\n"
            + "#+TBLFM: $1='(org-sbe quo)::$2='(org-sbe x)::$3='(org-lookup-first 2 '(1 2 3) '(a b c) (lambda (a b) (= a b)))\n\n"
            + "#+NAME: X\n| up |\n",
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func matchesEmacs() throws {
        var cases: [EmacsOracle.Case] = []
        var ours: [(text: String, caret: Int, failure: String?)] = []
        for text in Self.tables {
            let caret = (text as NSString).range(of: "#+TBLFM").location + 3
            cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text), form: "(let ((org-confirm-babel-evaluate nil)) (org-ctrl-c-ctrl-c))"))
            ours.append(TableFormulaTests.recalculate(TableRecalculate(all: true), text, caret: caret))
        }
        let emacs = try EmacsOracle.run(cases)
        for (i, (mine, theirs)) in zip(ours, emacs).enumerated() {
            let expected = (theirs.text, EmacsOracle.offset(theirs.point, in: theirs.text), theirs.error.isEmpty ? nil : theirs.error)
            #expect(mine.text == expected.0 && mine.caret == expected.1 && mine.failure == expected.2,
                    "case \(i)\nours:\n\(mine.text.components(separatedBy: "\n\n").last ?? "") \(mine.failure ?? "")\nemacs:\n\(theirs.text.components(separatedBy: "\n\n").last ?? "") \(theirs.error)")
        }
    }

    /// The reason a table with `org-sbe` in `formula` goes to Emacs; nil when it doesn't.
    static func reason(_ head: String, _ formula: String) -> String? {
        let text = head + "| n | f |\n|---+---|\n| 3 | |\n#+TBLFM: $2=" + formula + "\n"
        let caret = (text as NSString).range(of: "#+TBLFM").location + 3
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret])
        guard case .external(.emacsTable(_, _, _, let reason, _, _, _)) = TableRecalculate(all: true).run(in: context) else { return nil }
        return reason
    }

    /// Values Emacs 31 prints or reads as interpreted-function objects, `:lexical` values Emacs reads as
    /// Lisp, and a name whose first use is skipped and that doesn't name a src block go to Emacs.
    @Test func refusesWhatPrintsOrReadsDifferently() {
        let lambda = "#+NAME: lam\n#+begin_src emacs-lisp\n(lambda () 1)\n#+end_src\n\n"
        let printed = "#+NAME: lam\n#+begin_src emacs-lisp\n(format \"%S\" (lambda () 1))\n#+end_src\n\n"
        let car = "#+NAME: lam\n#+begin_src emacs-lisp\n(car (lambda () 1))\n#+end_src\n\n"
        let lexical = "#+NAME: lam\n#+begin_src emacs-lisp :lexical (identity t)\n1\n#+end_src\n\n"
        let twice = "* COMMENT Old\n#+NAME: lam\n| a |\n\n* New\n#+NAME: lam\n| b |\n\n"
        #expect(Self.reason(lambda, "'(org-sbe lam)") == "Lisp org-sbe with a function value")
        #expect(Self.reason(printed, "'(org-sbe lam)") == "Lisp format on a closure")
        #expect(Self.reason(car, "'(org-sbe lam)") == "Lisp car on a closure")
        #expect(Self.reason("", "'(format \"%S\" (lambda () 1))") == "Lisp format on a closure")
        #expect(Self.reason("", "'(lambda () 1)") == "Lisp formula with a function value")
        #expect(Self.reason(lexical, "'(org-sbe lam)") == "Lisp org-sbe with this :lexical")
        #expect(Self.reason(twice, "'(org-sbe lam)") == "Lisp org-sbe with a name used more than once")
        #expect(Self.reason("#+NAME: lam\n| a |\n\n", "'(org-sbe lam)") == nil)
    }

    @TaskLocal static var locked = false

    /// Without the app's leave to run blocks, `org-sbe` goes to the app with `lockedReason`.
    @Test func lockedWithoutBabel() {
        TableBlocks.allowed = { !TableSbeTests.locked }
        let square = "#+NAME: f\n#+begin_src emacs-lisp :var n=2\n(* n n)\n#+end_src\n\n"
        Self.$locked.withValue(true) {
            #expect(Self.reason(square, "'(org-sbe f (n $1))") == TableBlocks.lockedReason)
        }
        #expect(Self.reason(square, "'(org-sbe f (n $1))") == nil)
    }

    /// Other languages, and references only Emacs follows, go to Emacs.
    @Test func otherLanguagesNeedEmacs() {
        let python = "#+NAME: f\n#+begin_src python :var n=2\nreturn n\n#+end_src\n\n"
        let id = "* Data\n:PROPERTIES:\n:CUSTOM_ID: f\n:END:\n\n"
        for (head, expected) in [(python, "Lisp org-sbe with python blocks"), (id, "Lisp org-sbe with an ID reference")] {
            let text = head + "| n | f |\n|---+---|\n| 3 | |\n#+TBLFM: $2='(org-sbe f (n $1))\n"
            let caret = (text as NSString).range(of: "#+TBLFM").location + 3
            let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret])
            guard case .external(.emacsTable(_, _, _, let reason, let lisp, _, _)) = TableRecalculate(all: true).run(in: context) else {
                Issue.record("not sent to Emacs: \(expected)")
                continue
            }
            #expect(reason == expected)
            #expect(lisp)
        }
    }
}
