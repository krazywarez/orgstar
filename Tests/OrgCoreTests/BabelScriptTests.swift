import Foundation
import Testing
@testable import OrgCore

/// `:var`, `:prologue` and `:epilogue` for the interpreted languages, and ruby's and js's
/// values, run here and in Emacs.
struct BabelScriptTests {
    static let table = "#+NAME: tbl\n| 1 | 2 |\n| 3 | 4 |\n\n"
    static let headed = "#+NAME: hd\n| a | b |\n|---+---|\n| 1 | 2 |\n\n"

    static let cases: [String] = [
        // Ruby.
        "#+begin_src ruby :var x=3 y=\"hi\"\nx * 2\n#+end_src\n",
        "#+begin_src ruby :var x=3 y=\"hi\" :results output\nputs y * x\n#+end_src\n",
        table + "#+begin_src ruby :var t=tbl\nt.map { |r| r.sum }\n#+end_src\n",
        table + "#+begin_src ruby :var t=tbl\nt.map { |r| r.map { |c| c * 10 } }\n#+end_src\n",
        "#+begin_src ruby :var l='(1 2 3)\nl.reverse\n#+end_src\n",
        "#+begin_src ruby :var s=\"a\\\"b\"\ns.length\n#+end_src\n",
        "#+begin_src ruby\n[[1, 2], nil, [3, 4]]\n#+end_src\n",
        "#+begin_src ruby\n\"plain\"\n#+end_src\n",
        "#+begin_src ruby :prologue x = 5 :epilogue x + 1\nx = x * 2\n#+end_src\n",
        "#+begin_src ruby :results output :prologue puts \"first\" :epilogue puts \"last\"\nputs \"body\"\n#+end_src\n",
        headed + "#+begin_src ruby :var t=hd\nt.length\n#+end_src\n",
        // JavaScript.
        "#+begin_src js :var x=3\nreturn x * 2\n#+end_src\n",
        "#+begin_src js :var x=3 :results output\nconsole.log(x + 1)\n#+end_src\n",
        table + "#+begin_src js :var t=tbl\nreturn t.map(r => r[0] + r[1])\n#+end_src\n",
        table + "#+begin_src js :var t=tbl\nreturn t\n#+end_src\n",
        "#+begin_src js :var s=\"two words\"\nreturn s.length\n#+end_src\n",
        "#+begin_src js :prologue var k = 7; :epilogue return k;\nk = k * 6;\n#+end_src\n",
        "#+begin_src js\nreturn 'abc'\n#+end_src\n",
        "#+begin_src js :results output :epilogue console.log('end')\nconsole.log('body')\n#+end_src\n",
        // awk.
        "#+begin_src awk :var n=5\nBEGIN { print n * 2 }\n#+end_src\n",
        table + "#+begin_src awk :var t=tbl\nBEGIN { print t }\n#+end_src\n",
        "#+begin_src awk :prologue BEGIN { x = 1 } :epilogue BEGIN { print \"end\" }\nBEGIN { print x + 1 }\n#+end_src\n",
        "#+begin_src awk :cmd-line -v y=3\nBEGIN { print y }\n#+end_src\n",
        "#+begin_src awk :results output\nBEGIN { print \"a b\"; print \"c d\" }\n#+end_src\n",
        // Shell, Python and Emacs Lisp prologues.
        "#+begin_src sh :prologue x=1 :epilogue echo end :results output\necho $x\n#+end_src\n",
        "#+begin_src sh :var y=2 :prologue echo start :results output\necho $y\n#+end_src\n",
        "#+begin_src python :prologue import math\nreturn math.floor(2.5)\n#+end_src\n",
        "#+begin_src python :results output :prologue print('a') :epilogue print('c')\nprint('b')\n#+end_src\n",
        "#+begin_src emacs-lisp :var x=1 :prologue \"(setq y 2)\" :epilogue \"(* x 10)\"\n(+ x y)\n#+end_src\n",
        "#+begin_src emacs-lisp :prologue \"(error \\\"never\\\")\"\n1\n#+end_src\n",
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil
        && BabelCompiledTests.installed("ruby") && BabelCompiledTests.installed("node")))
    func scriptsMatchEmacs() throws {
        let folder = FileManager.default.temporaryDirectory
        var emacsCases: [EmacsOracle.Case] = []
        var ours: [(text: String, failure: String?)] = []
        for text in Self.cases {
            let caret = (text as NSString).range(of: "#+begin_src").location + 2
            ours.append(try TestBabelRunner.execute(text, caret: caret, directory: folder))
            emacsCases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text), form: """
            (progn (require 'ob-ruby) (require 'ob-js) (require 'ob-awk) (require 'ob-shell) (require 'ob-python)
              (setq org-confirm-babel-evaluate nil org-babel-js-cmd "node" org-babel-python-command "python3" default-directory temporary-file-directory)
              (org-babel-execute-src-block))
            """))
        }
        let emacs = try EmacsOracle.run(emacsCases)
        for (i, (mine, theirs)) in zip(ours, emacs).enumerated() {
            #expect(mine.text == theirs.text, "case \(i):\n\(Self.cases[i])\nours (\(mine.failure ?? "")):\n\(mine.text)\nemacs (\(theirs.error)):\n\(theirs.text)")
        }
    }

    /// R isn't needed to compare what ob-R sends it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func rExpansionMatchesEmacs() throws {
        let blocks = [
            "#+begin_src R :var x=3 y=1.5 s=\"a \\\"q\\\"\"\nx + y\n#+end_src\n",
            Self.table + "#+begin_src R :var t=tbl :prologue library(stats) :epilogue print(t)\nsummary(t)\n#+end_src\n",
            Self.headed + "#+begin_src R :var t=hd\nt$a\n#+end_src\n",
            "#+NAME: ragged\n| 1 | 2 |\n| 3 |\n\n#+begin_src R :var r=ragged\nr\n#+end_src\n",
            "#+begin_src R :var l='(1 \"two\" 3)\nl\n#+end_src\n",
        ]
        var cases: [EmacsOracle.Case] = []
        var ours: [String] = []
        for text in blocks {
            let caret = (text as NSString).range(of: "#+begin_src").location + 2
            cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text), form: """
                (progn (require 'ob-R)
                  (let* ((info (org-babel-get-src-block-info)) (params (org-babel-process-params (nth 2 info)))
                         (expanded (org-babel-expand-body:R (nth 1 info) params)))
                    (erase-buffer) (insert expanded)))
                """))
            let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret])
            guard case .success(let job) = Babel.plan(context) else { ours.append("no job"); continue }
            ours.append(String(job.input.dropLast()))
        }
        let results = try EmacsOracle.run(cases)
        for (i, (mine, theirs)) in zip(ours, results).enumerated() {
            #expect(mine == theirs.text, "case \(i): \(theirs.error)\nours:\n\(mine)\nemacs:\n\(theirs.text)")
        }
    }
}
