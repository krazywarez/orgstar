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
        "(capitalize \"it's o'neil x_y 3d foo-bar\")",
        #"(aref "\f" 0)"#, #"(string-match "\\s-" "\f")"#, #"(append "\a\b\d\e\f\n\r\s\t\v\ x" nil)"#, #"(list ?\a ?\b ?\d ?\e ?\f ?\r ?\s ?\v)"#,
        "(condition-case err (car 1) (error (car err)))", "(condition-case err (cdr 'a) (error err))", "(condition-case err (/ 1 0) (arith-error err))",
        "(condition-case err void-orgstar-variable (void-variable err))", "(condition-case nil (car 1) (wrong-type-argument 'w) (error 'e))",
        "(condition-case nil (car 1) (arith-error 'a))", #"(condition-case err (error "e %d" 1) (error err))"#,
        #"(condition-case err (user-error "u") (user-error err))"#, "(condition-case nil (aref [1] 5) (args-out-of-range 'r))",
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

    /// Math, strings, regexps, lists, seq and cl-lib, and the macros: each must run here.
    static let library = [
        "(list float-pi pi float-e)", "(expt 2 10)", "(expt 2 -2)", "(expt 2.0 3)", "(expt 0 0)", "(expt 0 -1)", "(expt -8 0.5)",
        "(sqrt 2)", "(sqrt -1)", "(exp 1)", "(log 8 2)", "(log 100 10)", "(log 9 3)", "(log 8 0)", "(log 0)", "(log 8)", "(sin 1)",
        "(cos 0)", "(tan 1)", "(asin 0.5)", "(acos 2)", "(atan 1)", "(atan 1 -1)", "(isnan 1)", "(isnan (/ 0.0 0.0))",
        "(logand 12 10)", "(logand)", "(logior 1 4)", "(logxor 5 1)", "(ash 1 3)", "(ash -8 -1)", "(ash 5 -10)", "(random 0)",
        "(let ((r (random 10))) (and (integerp r) (<= 0 r 9)))",
        #"(string-join '("a" "b") ", ")"#, #"(string-join '("a" "b"))"#, #"(string-to-char "")"#, #"(string-to-char "é")"#,
        "(char-to-string 233)", #"(string-pad "ab" 5)"#, #"(string-pad "ab" 5 ?- t)"#, #"(string-pad "abcdef" 3)"#,
        #"(string-width "abc\t")"#, #"(string-width "é\n")"#, #"(string-search "b" "abcb" 2)"#, #"(string-search "" "abc")"#,
        #"(string-search "z" "abc")"#, #"(string-search "b" "abc" 9)"#, #"(string-replace "ab" "x" "cabab")"#,
        #"(string-replace "" "x" "abc")"#, #"(substring "héllo" 1 3)"#, #"(number-to-string 1.5)"#,
        #"(string-match "a" "XA")"#, #"(let ((case-fold-search nil)) (string-match "a" "XA"))"#,
        #"(list (string-match "\\(b+\\)\\(x\\)?" "abbc") (match-beginning 1) (match-end 1) (match-beginning 2) (match-string 1 "abbc") (match-string 2 "abbc") (match-beginning 7))"#,
        #"(string-match "^b" "a\nb")"#, #"(string-match "a$" "a\nb")"#, #"(string-match "\\`b" "a\nb")"#, #"(string-match "b\\'" "ab\n")"#,
        #"(string-match "x*" "")"#, #"(string-match "\\w+" "_ab")"#, #"(string-match "\\W" "$%'_")"#, #"(string-match "\\bb" "a-b")"#,
        #"(string-match "\\_<b" "a-b")"#, #"(string-match "\\_<b" "a b")"#, #"(string-match "x\\_>" "x-y x")"#,
        #"(string-match "[[:space:]]" "a\tb")"#, #"(progn (string-match "\\s-+" "a \t b") (match-end 0))"#, #"(string-match "\\S-" "  x")"#,
        #"(string-match "\\s_" "ab=c")"#, #"(string-match "*a" "x*a")"#, #"(string-match "^*a" "*a")"#, #"(string-match "\\(*a\\)" "x*a")"#,
        #"(string-match "a\\{2\\}" "caaa")"#, #"(string-match "a\\{,2\\}b" "aaab")"#, #"(progn (string-match "a\\{2,\\}" "caaaa") (match-end 0))"#,
        #"(string-match "a|b" "xa|b")"#, #"(string-match "a{2}" "a{2}")"#, #"(string-match "(a)" "x(a)")"#, #"(string-match "[]a]" "x]")"#,
        #"(string-match "[^]a]" "]ab")"#, #"(string-match "[\\]" "x\\")"#, #"(string-match "[a-]" "x-")"#, #"(string-match "\\(?:ab\\)+" "xabab")"#,
        #"(progn (string-match "a+?" "aaa") (match-end 0))"#, #"(progn (string-match "a*?b" "aab") (match-end 0))"#, #"(string-match "\\Ba" "ba")"#,
        #"(string-match "\\<b" "a b")"#, #"(string-match "a\\>" "ab a")"#, #"(string-match "\\s." "a,b")"#, #"(string-match "\\s(" "a[b")"#,
        #"(string-match "[[:alpha:]]+" "12ab")"#, #"(string-match "[^[:digit:]]" "12ab")"#, #"(string-match "[[:punct:]]" "ab$")"#,
        #"(string-match "[[:word:]]" ",$")"#, #"(string-match "[[:xdigit:]]+" "xyzBEEF")"#, #"(string-match "\\(a\\)\\1" "xaa")"#,
        #"(string-match "[a-z]+" "ABC")"#, #"(let ((case-fold-search nil)) (string-match "[a-z]+" "ABC"))"#, #"(string-match "x\\|y" "zzy")"#,
        #"(string-match "[[:upper:]]" "a")"#, #"(let ((case-fold-search nil)) (string-match "[[:upper:]]" "a"))"#, #"(string-match "a" "bab" 2)"#,
        #"(string-match "a" "bab" -2)"#, #"(string-match "a" "bab" 9)"#, #"(string-match "^a" "ba" 1)"#, #"(string-match "\\." "a.b")"#,
        #"(string-match "a.c" "a\nc abc")"#, #"(string-match "f." "café")"#,
        #"(let ((case-fold-search nil)) (string-match "É" "café"))"#, #"(string-match-p "b" "abc")"#,
        #"(progn (string-match "a" "xa") (string-match-p "b" "bbb") (match-beginning 0))"#,
        #"(progn (string-match "a" "xa") (save-match-data (string-match "b" "bbb")) (match-beginning 0))"#,
        #"(progn (string-match "\\(b\\)c" "abc") (list (replace-match "Z" t t "abc") (replace-match "Z" t t "abc" 1) (replace-match "[\\&]" t nil "abc")))"#,
        #"(replace-regexp-in-string "b" "X" "aBc")"#, #"(replace-regexp-in-string "o" "x" "FOO BAR")"#,
        #"(replace-regexp-in-string "foo" "bar" "Foo FOO foo")"#, #"(replace-regexp-in-string "foo" "bar" "Foo FOO foo" t)"#,
        #"(replace-regexp-in-string "a b" "x y" "A B")"#, #"(replace-regexp-in-string "ab" "x y" "Ab")"#, #"(replace-regexp-in-string "ab" "x-y" "AB")"#,
        #"(replace-regexp-in-string "" "x" "ab")"#, #"(replace-regexp-in-string "$" "x" "ab")"#, #"(replace-regexp-in-string "^" "> " "a\nb")"#,
        #"(replace-regexp-in-string "\\(a\\)\\|b" "[\\1]" "ab")"#, #"(replace-regexp-in-string "a" "\\x" "a")"#, #"(replace-regexp-in-string "a" "\\1" "a")"#,
        #"(replace-regexp-in-string "a" "\\\\" "a")"#, #"(replace-regexp-in-string "a\\(b\\)" "Z" "abab" nil nil 1)"#,
        #"(replace-regexp-in-string "b" "Z" "abab" nil nil nil 2)"#, #"(replace-regexp-in-string "o" "0" "foo" nil t)"#,
        #"(replace-regexp-in-string "\\([0-9]+\\)" "<\\1>" "a1b22")"#, #"(replace-regexp-in-string "[aeiou]" (lambda (m) (upcase m)) "hello world")"#,
        #"(replace-regexp-in-string "[0-9]+" (lambda (m) (number-to-string (* 2 (string-to-number m)))) "a1b22")"#,
        #"(let ((case-fold-search nil)) (replace-regexp-in-string "é" "e" "café"))"#, #"(replace-regexp-in-string "—" "-" "a—b")"#, #"(regexp-quote "a.b*[c]^$+?\\")"#, #"(string-match (regexp-quote "a.b") "axb a.b")"#,
        #"(split-string "a1b22c" "[0-9]+")"#, #"(split-string "  a  b " " +")"#, #"(split-string "a,b,,c" "," t)"#,
        #"(split-string " a , b " "," t " ")"#, #"(split-string "abc" "")"#, #"(split-string "abc" "" t)"#, #"(split-string "a-b_c" "\\W")"#,
        #"(split-string "a,b" "," nil "\\s-*")"#, #"(split-string "a b" nil)"#, #"(split-string "  two words " "[ ]+" t)"#,
        #"(split-string "a\nb" "$")"#, #"(split-string "a\nb\nc" "^")"#, #"(split-string "foo bar" "\\>")"#, #"(split-string "foo bar" "\\<")"#,
        #"(split-string "foo bar" "\\b")"#, #"(split-string "a\nb" "$" t)"#, #"(split-string " a ,, b " "," nil " +")"#, #"(split-string " a ,, b " "," t " +")"#,
        #"(replace-regexp-in-string "a" "\\?" "a")"#, #"(let ((s "abc")) (string-match "b" s) (replace-match "\\?" nil nil s))"#,
        #"(string-pad "ab" -1)"#, "(let* ((a (list 3 1 2)) (b (list 4 5))) (sort a #'<) (list a b))",
        "(last '(1 2 3))", "(last '(1 2 3) 2)", "(last '(1 2 3) 0)", "(last '(1 2 . 3))", "(last nil)", "(butlast '(1 2 3))",
        "(butlast '(1 2 3) 2)", "(butlast '(1 2 3) 0)", "(butlast nil)", "(butlast '(1 2 . 3))", #"(delete-dups (list 1 2 1 "a" "a"))"#,
        "(nreverse (list 1 2 3))", "(nreverse [1 2 3])", #"(nreverse "abc")"#, "(let ((l (list 1 2 3))) (nreverse l) l)",
        "(let ((l (list 1 2 3))) (setq l (nreverse l)) l)", "(sort (list 3 1 2) #'<)", "(let ((l (list 3 1 2))) (sort l #'<) l)",
        "(let ((v [3 1 2])) (sort v #'<) v)", "(let ((v [3 1 2])) (sort v) v)", "(let ((l (list 3 1 2))) (sort l :in-place t) l)",
        "(sort (list 3 1 2))", "(sort [3 1 2] :reverse t)", #"(sort '("b" "a" "c"))"#, "(sort (list 'b 'a))", "(sort (list 3 1 2) :key #'-)",
        "(sort '(3 1 2) :lessp #'>)", "(sort '((b . 2) (a . 1) (c . 1)) :key #'cdr)", "(sort '((1 . a) (0 . b) (1 . c) (0 . d)) (lambda (x y) (< (car x) (car y))))",
        "(seq-reduce #'+ '(1 2 3) 10)", "(seq-reduce #'+ [] 0)", "(seq-filter (lambda (x) (> x 2)) [1 2 3 4])",
        "(seq-remove (lambda (x) (> x 2)) '(1 2 3 4))", "(seq-map #'1+ [1 2])", #"(seq-map #'1+ "ab")"#, "(seq-uniq '(1 2 2 1 3))",
        #"(seq-uniq "abca")"#, "(cl-reduce #'+ '(1 2 3))", "(cl-reduce #'+ '())", "(cl-reduce #'+ '(5))", "(cl-reduce #'list '(1 2 3) :initial-value 0)",
        "(cl-reduce #'+ [1 2 3] :initial-value 4)", "(cl-remove-if (lambda (x) (> x 2)) '(1 2 3 4))", "(cl-remove-if (lambda (x) (> x 2)) [1 2 3 4])",
        #"(cl-remove-if (lambda (c) (= c ?a)) "banana")"#, "(cl-remove-if-not (lambda (x) (> x 2)) '(1 2 3 4))", "(cl-find 2 '(1 2 3))",
        #"(cl-find "a" '("a"))"#, #"(cl-find "a" '("a") :test #'equal)"#, "(cl-find 2 '(1 2 3) :test #'=)", "(cl-position 3 '(1 2 3))",
        "(cl-position 9 '(1 2 3))", #"(cl-position ?b "abc")"#, "(cl-position 2 [1 2])",
        #"(progn (defun orgstar-sq (x) "Square." (* x x)) (orgstar-sq 4))"#, "(defun orgstar-f () 1)", #"(progn (defun orgstar-g () "doc") (orgstar-g))"#,
        "(progn (defun orgstar-h (a) (interactive) (1+ a)) (orgstar-h 1))", "(progn (defun orgstar-fact (n) (if (< n 2) 1 (* n (orgstar-fact (1- n))))) (orgstar-fact 10))",
        "(defvar orgstar-v 3)", "(progn (defvar orgstar-w 3) (defvar orgstar-w 4) orgstar-w)", "(progn (defconst orgstar-c 3) (defconst orgstar-c 4) orgstar-c)",
        "(let-alist '((a . 1) (b . ((c . 2)))) (list .a .b.c .d))", "(let-alist '((a . 1)) (let-alist '((a . 2)) .a))",
        "(let-alist '((a . 1) (b . 2)) (+ .a .b))", "(pcase 3 (1 'one) (3 'three))", #"(pcase "x" ("x" 'ex) (_ 'other))"#, "(pcase 'b ('a 1) ('b 2))",
        "(pcase '(1 2 3) (`(,a ,b . ,c) (list a b c)))", "(pcase '(add 1 2) (`(add ,x ,y) (+ x y)) (`(sub ,x ,y) (- x y)))",
        "(pcase '(sub 5 2) (`(add ,x ,y) (+ x y)) (`(sub ,x ,y) (- x y)))", "(pcase 5 ((pred stringp) 's) ((pred integerp) 'i))",
        "(pcase 5 ((pred (lambda (n) (> n 3))) 'big) (_ 'small))", "(pcase 5 (x (* x 2)))", "(pcase 7 (1 'a))", "(pcase :k (:k 'kw))",
        "(pcase [1 2] (`[,a ,b] (+ a b)))", "(pcase nil ('nil 'isnil))", "(pcase '(1 2) (`(1 ,x) x))", "(pcase '(1 1) (`(,x ,x) 'same) (_ 'differ))",
        "(pcase '(1 2) (`(,x ,x) 'same) (_ 'differ))", "(pcase ?a (?a 'char))", "(cl-loop for x in '(1 2 3) collect (* x x))",
        "(cl-loop for i from 1 to 4 sum i)", "(cl-loop for i from 1 to 3 for x in '(a b) collect (list i x))", "(cl-loop for i from 0 to 2 collect i)",
        "(cl-loop for x in '(1 2.5) sum x)", "(cl-loop for i from 5 to 3 collect i)", "(cl-loop for x in nil sum x)",
        "(with-output-to-string (cl-loop for x in '(1 2) do (princ x) (princ \"-\")))", "(cl-loop for i from 1 to 3 for j from i to 10 collect (+ i j))",
        "(let ((n 1)) (cl-incf n) (cl-incf n 10) n)", "(let ((n 1.5)) (cl-decf n))", "(let ((n 5)) (list (cl-decf n 2) n))",
        "(undefined-orgstar-function (car 1))",
    ]

    /// Forms that use what the evaluator lacks, refused rather than answered differently.
    static let unsupported = [
        "(expt 3 40)", "(ash 1 63)", #"(random "seed")"#, #"(string-match "\\(?2:a\\)" "a")"#, #"(string-match "\\ca" "a")"#,
        #"(string-match "é" "café")"#, #"(let ((case-fold-search nil)) (replace-regexp-in-string "É" "e" "cafÉ"))"#, #"(string-match "\\w" "café")"#, "(string-match \"k\" \"\u{212A}\")", #"(match-string 0)"#,
        #"(string-width "中")"#, #"(sort "cba")"#, "(seq-uniq '(1 2) #'=)", "(cl-find 2 '(1 2 3) :key #'1+)",
        "(pcase 1.0 (1.0 'f))", "(pcase 1 ((or 1 2) 'a))", "(pcase 1 ((pred (< 0)) 'a))", "(cl-loop for x across [1 2] collect x)",
        "(cl-loop for i from 1 to 3 sum i collect i)", "(cl-loop repeat 3 collect 1)", "(let ((l (list 1 2))) (cl-incf (car l)))",
        "(when-let ((x 1)) x)", "(undefined-orgstar-macro (car 1))", "(undefined-orgstar-macro void-orgstar-variable)",
        // In-place changes to a list another value may share.
        "(let* ((a (list 3 1 2)) (b a)) (sort a '<) b)", "(let ((x (list 1 3 2))) (sort (cdr x) '<) x)",
        "(let* ((a (list 3 1 2)) (b (list a))) (sort a '<) b)", "(let* ((a (list 1 2 3)) (b a)) (nreverse a) b)",
        "(let* ((a (list 1 1 2)) (b a)) (delete-dups a) b)", "(let ((a (list 3 1 2))) (list a (sort a '<)))",
        "(let* ((a (list 3 1 2)) (b a)) (funcall #'sort a '<) b)", "(let ((a (list 3 1 2))) (prog1 a (sort a '<)))",
        // Errors whose data, or whose symbol, isn't known here.
        "(condition-case err (aref [1] 5) (error err))", "(condition-case nil (number-sequence 1 2 0) (wrong-type-argument 1))",
        #"(capitalize "café")"#,
    ]

    static func strict(_ form: String) -> String {
        guard let sexp = try? LispReader.readFirst(form).sexp else { return "read-error" }
        do {
            return Elisp.printed(try Elisp().eval(sexp), escape: true)
        } catch is Elisp.Unsupported {
            return "unsupported"
        } catch {
            return "error"
        }
    }

    @Test(.enabled(if: oracle))
    func libraryMatchesEmacs() throws {
        let forms = Self.library.filter { !$0.hasPrefix("(undefined-") }
        let list = "(list " + forms.map { "(condition-case nil (prin1-to-string \($0)) (error \"error\"))" }.joined(separator: " ") + ")"
        let emacs = try EmacsOracle.evaluate("", list, prelude: "(require 'cl-lib) (require 'seq) (require 'let-alist)")
        #expect(emacs.count == forms.count)
        for (form, expected) in zip(forms, emacs) {
            #expect(Self.strict(form) == expected, "\(form): \(Self.strict(form)), Emacs \(expected)")
        }
    }

    @Test func refusesWhatItLacks() {
        for form in Self.unsupported { #expect(Self.strict(form) == "unsupported", "\(form)") }
        // Arguments aren't evaluated for a function it doesn't have.
        #expect(Self.strict("(undefined-orgstar-function (car 1))") == "unsupported")
    }

    /// The syntax classes follow `org-mode-syntax-table`, and for Emacs Lisp blocks, the table
    /// of `*scratch*` in `emacs -Q --batch -l`.
    @Test(.enabled(if: oracle))
    func syntaxTablesMatchEmacs() throws {
        let classes = "(let (r) (dotimes (c 128) (push (string (char-syntax c)) r)) (apply #'concat (nreverse r)))"
        let emacs = try EmacsOracle.evaluate("", "(list \(classes))")
        #expect(emacs == [String(ElispSyntax.org.classes)])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-syntax-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("syntax.el")
        try ";;; -*- lexical-binding: t -*-\n(princ \(classes))\n".write(to: script, atomically: true, encoding: .utf8)
        #expect(try EmacsOracle.run(["-Q", "--batch", "-l", script.path]) == String(ElispSyntax.emacsLisp.classes))
    }

    static let timeForms = [
        #"(org-time-string-to-time "<2026-11-20 Fri 10:30>")"#, #"(org-time-string-to-time "2026-11-20")"#, #"(org-time-string-to-time "[2026-11-20 Fri]")"#,
        #"(org-time-string-to-time "x <2026-11-20 Fri 10:30-11:00> y")"#, #"(org-time-string-to-time "2026-11-20 7:05")"#, #"(org-time-string-to-time "foo")"#,
        #"(org-time-string-to-absolute "<2026-11-20 Fri>")"#, #"(org-time-string-to-absolute "<2026-11-20 Fri 23:59 +1w>")"#,
        #"(time-add (org-time-string-to-time "<2026-11-20 Fri>") 3600)"#, "(time-add 1 2)", "(time-add '(1 2) '(0 5))", "(time-add '(1 2 3 4) 1)",
        "(time-add '(1 2 3) 1)", "(time-add '(0 1 500000 0) '(0 1 600000 0))", "(time-subtract '(0 1 0) '(0 2 500000))", "(time-subtract 5 '(0 2))",
        #"(time-subtract (org-time-string-to-time "<2026-11-21 Sat>") (org-time-string-to-time "<2026-11-20 Fri>"))"#,
        "(float-time '(1 2))", "(float-time '(0 1 500000 0))", "(float-time '(0 1 1))", "(float-time 5)", "(float-time 2.5)",
        #"(float-time (org-time-string-to-time "<2026-11-20 Fri 10:30>"))"#, #"(days-between "2026-11-20" "2026-01-01")"#,
        #"(days-between "2026-11-20 10:00" "2026-01-01 23:00")"#, #"(date-to-time "2026-11-20")"#, #"(date-to-time "2026-11-20 10:30")"#,
        #"(date-to-time "2026-11-20T10:30:05")"#, #"(time-to-days (org-time-string-to-time "<2026-11-20 Fri>"))"#, "(time-to-days 0)",
        "(time-to-days 86399)", "(time-to-days 86400.5)",
        #"(format-time-string "%Y-%m-%d %H:%M:%S %a %A %b %h %B %j %u %w %y %e %p %I %l %k %z %T %D %F %R %s %%" (org-time-string-to-time "<2026-11-20 Fri 15:04>"))"#,
        #"(format-time-string "%Y %e|%k|%l %p" (org-time-string-to-time "<2026-01-05 Mon 00:07>"))"#, #"(format-time-string "%Y" 0)"#,
        #"(format-time-string "%Y-%m-%d %H:%M" 1795170600 t)"#, #"(format-time-string "%H:%M" 1795170600.75)"#,
        "(calendar-day-of-week '(11 20 2026))", "(calendar-absolute-from-gregorian '(11 20 2026))", "(calendar-gregorian-from-absolute 739940)",
        "(calendar-leap-year-p 2028)", "(calendar-last-day-of-month 2 2028)", "(calendar-iso-from-absolute 739940)",
        #"(let ((s (format-time-string "%Y-%m-%d"))) (string-match "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'" s))"#,
        "(let ((t0 (current-time))) (and (consp t0) (= (length t0) 4) (< (abs (- (float-time t0) (float-time))) 5)))",
        "(> (time-to-days (current-time)) 739000)",
        // Proleptic Gregorian dates, before 1582 and before year 1.
        #"(org-time-string-to-time "<1500-01-01>")"#, #"(org-time-string-to-time "<0099-01-01>")"#, #"(date-to-time "1582-10-10")"#,
        #"(format-time-string "%F %a" (date-to-time "1500-01-01"))"#, #"(format-time-string "%F" -15000000000)"#,
        #"(format-time-string "%Y" -100000000000)"#, #"(format-time-string "%Y %y %D %F %j %a" -62200000000)"#,
        #"(format-time-string "%Y %F" -62135596800)"#, "(time-to-days -100000000000)", #"(time-to-days (date-to-time "1500-01-01"))"#,
        #"(days-between "1500-01-01" "1600-01-01")"#, #"(format-time-string "%Y %F" 300000000000 t)"#,
    ]

    static let unsupportedTime = [
        "(time-add 0.1 1)", "(time-add '(5 . 10) 1)", #"(format-time-string "%-d" 0)"#, #"(format-time-string "%c" 0)"#,
        #"(format-time-string "%Y" 0 "EST5")"#, #"(date-to-time "Fri, 20 Nov 2026 10:30:00 +0000")"#,
        #"(org-time-string-to-absolute "<2026-11-20 Fri>" 739940)"#, "(float-time '(0 1 0 1))",
    ]

    static func timed(_ form: String) -> String {
        guard let sexp = try? LispReader.readFirst(form).sexp else { return "read-error" }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let lisp = Elisp()
        lisp.standardTime(calendar: utc)
        do {
            return Elisp.printed(try lisp.eval(sexp), escape: true)
        } catch is Elisp.Unsupported {
            return "unsupported"
        } catch {
            return "error"
        }
    }

    @Test(.enabled(if: oracle))
    func timeFunctionsMatchEmacs() throws {
        let list = "(list " + Self.timeForms.map { "(condition-case nil (prin1-to-string \($0)) (error \"error\"))" }.joined(separator: " ") + ")"
        let emacs = try EmacsOracle.evaluate("", list, prelude: "(require 'calendar) (require 'time-date)")
        #expect(emacs.count == Self.timeForms.count)
        for (form, expected) in zip(Self.timeForms, emacs) {
            #expect(Self.timed(form) == expected, "\(form): \(Self.timed(form)), Emacs \(expected)")
        }
        for form in Self.unsupportedTime { #expect(Self.timed(form) == "unsupported", "\(form)") }
    }
}

/// Inputs that once crashed the evaluator, the diary functions or duration formulas.
struct HostileInputTests {
    static let forms = [
        "(1+ 9223372036854775807)", "(1- -9223372036854775808)", "(- -9223372036854775808)", "(abs -9223372036854775808)",
        "(% -9223372036854775808 -1)", "(mod -9223372036854775808 -1)", "(/ -9223372036854775808 -1)",
        "(upcase -1)", "(downcase -1)", "(concat (list -1))", "(format \"%c\" -1)", "(format \"%c\" 99999999)",
        "(funcall (lambda (f) (funcall f f)) (lambda (f) (funcall f f)))",
        "(dotimes (i 10000000000) nil)", "(number-sequence 1 10000000000)", #"(string-pad "a" 10000000000)"#,
        "(cl-loop for i from 1 to 10000000000 sum i)", "(cl-loop for i from 1 collect i)", "(expt 7 10000000000)",
    ]

    @Test func evaluatorRefusesWithoutCrashing() {
        for form in Self.forms { #expect(ElispTests.ours(form) == "error", "\(form)") }
        // Long lists lose duplicates without comparing every pair.
        #expect(ElispTests.ours("(length (seq-uniq (append (number-sequence 1 50000) (number-sequence 1 50000))))") == "50000")
    }

    /// On a stack the size of a background task's, deep recursion stops with an error.
    @Test func deepRecursionFitsABackgroundStack() async {
        let done = await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: ElispTests.ours("(funcall (lambda (f) (funcall f f)) (lambda (f) (funcall f f)))"))
            }
            thread.stackSize = 512 * 1024
            thread.start()
        }
        #expect(done == "error")
    }

    @Test func diaryFunctionsRefuseWithoutCrashing() throws {
        let day = Days.absolute(year: 2026, month: 10, day: 7)
        for form in ["(calendar-last-day-of-month -20 2024)", "(calendar-gregorian-from-absolute 9223372036854775807)",
                     "(calendar-nth-named-absday -9223372036854775808 1 10 2026)", "(diary-remind '(diary-date 1 1 2027) -9223372036854775808)",
                     "(diary-float 10 3 -9223372036854775808)", "(diary-anniversary 10 7 -9223372036854775808)"] {
            #expect(DiarySexp.entries(try LispReader.readFirst(form).sexp, entry: "E", day: day) == nil, "\(form)")
        }
    }

    @Test func durationsAndHugeNumbersDoNotCrashFormulas() {
        for table in [
            "| 1e300 | |\n#+TBLFM: $2=$1*2;T\n", "| 1e300 | |\n#+TBLFM: $2='(* $1 2);T\n", "| 9999999999999999:00:00 | |\n#+TBLFM: $2=$1;T\n",
            "| 1 | |\n#+TBLFM: $2=$1;p99999999999999999999\n", "| 1 | |\n#+TBLFM: $2=$99999999999999999999\n",
            "| 1 | |\n#+TBLFM: @99999999999999999999$2=1\n", "#+CONSTANTS: a=$a\n| 1 | |\n#+TBLFM: $2=$a\n",
        ] {
            let caret = (table as NSString).range(of: "#+TBLFM").location + 3
            let result = runCommand(TableRecalculate(all: true), table, caret: caret)
            #expect(result.text == table, "\(table)")
        }
    }
}
