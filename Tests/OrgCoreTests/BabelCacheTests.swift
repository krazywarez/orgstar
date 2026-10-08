import Foundation
import Testing
@testable import OrgCore

struct BabelCacheTests {
    /// A file, and the text before which each run in turn puts the caret.
    struct Case {
        var text: String
        var runs: [String]
        /// Replacements made after the runs before the last, as the user editing.
        var edits: [(String, String)] = []
    }

    static let cases: [Case] = [
        Case(text: "#+begin_src sh :cache yes\necho hi\n#+end_src\n", runs: ["#+begin_src", "#+begin_src"]),
        Case(text: "#+begin_src sh :cache yes\necho there\n#+end_src\n\n#+RESULTS[0000]:\n: old\n\nAfter.\n", runs: ["#+begin_src"]),
        Case(text: "#+begin_src sh :cache yes :results append\necho more\n#+end_src\n\n#+RESULTS[0000]:\n: first\n", runs: ["#+begin_src"]),
        Case(text: "#+begin_src sh :cache yes\necho new\n#+end_src\n\n#+RESULTS:\n: no hash\n", runs: ["#+begin_src"]),
        Case(text: "#+NAME: a\n#+begin_src sh :cache yes\necho named\n#+end_src\n\nText.\n\n#+RESULTS[abc]: a\n: stale\n", runs: ["#+begin_src", "#+begin_src"]),
        Case(text: "#+NAME: a\n#+begin_src sh :cache yes\necho named\n#+end_src\n", runs: ["#+begin_src", "#+begin_src"]),
        Case(text: "#+begin_src sh :cache yes :var x=5 :var y=\"two words\" :height 400 :width \"400\" :exports both\necho $x $y\n#+end_src\n",
             runs: ["#+begin_src", "#+begin_src"]),
        Case(text: "#+begin_src sh :cache yes :results output :exports none :wrap example\nprintf 'a\\nb\\n'\n#+end_src\n", runs: ["#+begin_src", "#+begin_src"]),
        Case(text: "#+NAME: tbl\n| 1 | x |\n| 2 | y |\n\n#+NAME: items\n- a\n- b\n\n#+begin_src python :cache yes :var t=tbl :var n=1.5 :var l=items\nreturn [len(t), n, l]\n#+end_src\n",
             runs: ["#+begin_src", "#+begin_src"]),
        Case(text: "#+begin_src emacs-lisp :cache yes :var x=4 :var s=\"q\\\"z\"\n(list x s)\n#+end_src\n", runs: ["#+begin_src", "#+begin_src"]),
        Case(text: "#+begin_src emacs-lisp :cache yes :lexical yes :results output\n(princ 7)\n#+end_src\n", runs: ["#+begin_src", "#+begin_src"]),
        Case(text: "#+NAME: a\n#+begin_src sh\necho hi\n#+end_src\n\n#+CALL: a() :cache yes\n", runs: ["#+CALL", "#+CALL"]),
        Case(text: "#+PROPERTY: header-args :cache yes\n#+begin_src sh :session none\necho prop\n#+end_src\n", runs: ["#+begin_src", "#+begin_src"]),
        Case(text: "#+NAME: tbl\n| a | b |\n|---+---|\n| 1 | x |\n\n#+begin_src python :cache yes :var t=tbl :colnames yes :rownames yes\nreturn t\n#+end_src\n",
             runs: ["#+begin_src", "#+begin_src"]),
        Case(text: "#+NAME: kv\n| a | 1 |\n| b | 2 |\n\n#+begin_src bash :cache yes :var t=kv :var l='(1 2)\necho ${t[a]} ${l[1]}\n#+end_src\n",
             runs: ["#+begin_src", "#+begin_src"]),
        Case(text: "#+NAME: kv\n| a | 1 |\n| b | 2 |\n\n#+begin_src sh :cache yes :var t=kv :separator ,\necho $t\n#+end_src\n",
             runs: ["#+begin_src", "#+begin_src"]),
        Case(text: "#+begin_src sh :cache yes :dir (concat \"/\" \"usr\") :foo (list 1 \"a\") :bar (+ 1 2)\npwd\n#+end_src\n",
             runs: ["#+begin_src", "#+begin_src"]),
        Case(text: "#+NAME: tbl\n| a | b |\n|---+---|\n| 1 | x |\n\n#+begin_src python :cache yes :var t=tbl :colnames '(\"x\" \"y\")\nreturn t\n#+end_src\n",
             runs: ["#+begin_src", "#+begin_src"]),
        // Edited after the first run, so it runs again.
        Case(text: "#+begin_src sh :cache yes\necho one\n#+end_src\n", runs: ["#+begin_src", "#+begin_src"], edits: [("echo one", "echo two")]),
        // A reference to a cached block takes its result without running it.
        Case(text: "#+begin_src sh :var x=five\necho $((x+1))\n#+end_src\n\n#+NAME: five\n#+begin_src sh :cache yes\necho 5\n#+end_src\n",
             runs: ["#+begin_src sh :cache", "#+begin_src sh :var"], edits: [(": 5\n", ": 50\n")]),
        Case(text: "#+begin_src sh :var x=five\necho $((x+1))\n#+end_src\n\n#+NAME: five\n#+begin_src sh :cache yes\necho 5\n#+end_src\n\n#+RESULTS[0000]: five\n: 50\n",
             runs: ["#+begin_src sh :var"]),
    ]

    static func caret(_ marker: String, in text: String) -> Int {
        (text as NSString).range(of: marker).location + 2
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func matchesEmacs() throws {
        let folder = FileManager.default.temporaryDirectory
        var emacsCases: [EmacsOracle.Case] = []
        var ours: [(text: String, failure: String?)] = []
        for c in Self.cases {
            var text = c.text
            var failure: String?
            for (i, marker) in c.runs.enumerated() {
                if i == c.runs.count - 1, c.runs.count > 1 { for (old, new) in c.edits { text = text.replacingOccurrences(of: old, with: new) } }
                (text, failure) = try TestBabelRunner.execute(text, caret: Self.caret(marker, in: text), directory: folder)
            }
            ours.append((text, failure))
            let steps = c.runs.enumerated().map { i, marker in
                let edits = i == c.runs.count - 1 && c.runs.count > 1
                    ? c.edits.map { "(goto-char (point-min)) (while (search-forward \(Babel.lispString($0.0)) nil t) (replace-match \(Babel.lispString($0.1)) t t))" }.joined(separator: " ")
                    : ""
                return "\(edits) (goto-char (point-min)) (search-forward \(Babel.lispString(marker))) (goto-char (+ (match-beginning 0) 2)) (org-babel-execute-maybe)"
            }
            emacsCases.append(EmacsOracle.Case(text: c.text, point: 1, form: """
            (progn
              (require 'ob-shell)
              (require 'ob-python)
              (require 'ob-emacs-lisp)
              (setq org-confirm-babel-evaluate nil
                    org-babel-python-command "python3"
                    default-directory temporary-file-directory)
              \(steps.joined(separator: "\n  ")))
            """))
        }
        let emacs = try EmacsOracle.run(emacsCases)
        for (i, (mine, theirs)) in zip(ours, emacs).enumerated() {
            #expect(mine.text == theirs.text, "case \(i):\n\(Self.cases[i].text)\nours (\(mine.failure ?? "")):\n\(mine.text)\nemacs (\(theirs.error)):\n\(theirs.text)")
        }
    }

    @Test func cachedRunSaysSo() throws {
        let text = "#+begin_src sh :cache yes\necho hi\n#+end_src\n"
        let folder = FileManager.default.temporaryDirectory
        let first = try TestBabelRunner.execute(text, caret: 2, directory: folder)
        #expect(first.failure == nil)
        let second = try TestBabelRunner.execute(first.text, caret: 2, directory: folder)
        #expect(second.text == first.text)
        #expect(second.failure == "Cached: \"hi\"")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func fileLispMatchesEmacs() throws {
        let text = "#+begin_src sh :cache yes :dir (file-name-directory buffer-file-name) :foo (file-name-nondirectory buffer-file-name)\npwd\n#+end_src\n"
        let emacs = try EmacsOracle.evaluate(text, """
            (progn (require 'ob-shell) (goto-char (point-min))
              (let ((info (org-babel-get-src-block-info)))
                (setf (nth 2 info) (org-babel-process-params (nth 2 info)))
                (list buffer-file-name (org-babel-sha1-hash info :eval))))
            """)
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [2..<2])
        guard case .success(let first) = Babel.plan(context) else {
            Issue.record("not planned")
            return
        }
        #expect(first.needsFile)
        #expect(first.finish.hash == nil)
        guard case .success(let job) = Babel.replan(first, file: emacs[0], text: text, tree: context.tree) else {
            Issue.record("not replanned")
            return
        }
        #expect(!job.needsFile)
        #expect(job.finish.hash == emacs[1])
        #expect(job.directory == (emacs[0] as NSString).deletingLastPathComponent + "/")
    }

    /// Languages that don't run hash the body as their `org-babel-expand-body:LANG` writes it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func expandedLanguagesHashLikeEmacs() throws {
        let texts = [
            "#+NAME: tbl\n| a | b |\n|---+---|\n| 1 | 2 |\n\n#+begin_src C :cache yes :includes <stdio.h> :defines N 1 :var t=tbl n=2\nprintf(\"%d\", n);\n#+end_src\n",
            "#+begin_src C++ :cache yes :namespaces std :main no\nint f();\n#+end_src\n",
            "#+begin_src D :cache yes :var s=\"x\"\nwriteln(s);\n#+end_src\n",
            "#+begin_src fortran :cache yes :var n=3\nprint *, n\n#+end_src\n",
            "#+begin_src clojure :cache yes :var n=3\n(+ n 1)\n#+end_src\n",
        ]
        for text in texts {
            let emacs = try EmacsOracle.evaluate(text, """
                (progn (require 'ob-C) (require 'ob-fortran) (require 'ob-clojure) (setq org-babel-clojure-backend 'babashka)
                  (goto-char (point-min)) (search-forward "#+begin_src")
                  (list (org-babel-sha1-hash)))
                """)
            let cached = text + "\n#+RESULTS[\(emacs[0])]:\n: 42\n"
            let caret = (cached as NSString).range(of: "#+begin_src").location + 2
            let context = EditContext(revision: 0, text: cached, tree: OrgParser.parse(cached), selection: [caret..<caret])
            guard case .failure(.message(let message)) = Babel.plan(context) else {
                Issue.record("planned:\n\(text)")
                continue
            }
            #expect(message == "Cached: 42", "\(text)")
        }
    }

    @Test func lispHeadersAreRefused() {
        let text = "#+begin_src sh :cache yes :dir (user-full-name)\necho hi\n#+end_src\n"
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [2..<2])
        var options = Babel.Options()
        options.file = "/tmp/a.org"
        guard case .failure(.message(let message)) = Babel.plan(context, options: options) else {
            Issue.record("planned")
            return
        }
        #expect(message.hasPrefix(":cache with :dir (user-full-name)"))
    }
}
