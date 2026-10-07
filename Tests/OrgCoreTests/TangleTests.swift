import Foundation
import Testing
@testable import OrgCore

/// `org-babel-tangle` against Emacs: every file written, with its mode.
struct TangleTests {
    static let text = #"""
        #+PROPERTY: header-args:python :tangle script.py

        * Setup
        #+begin_src sh :tangle yes
        echo one
        #+end_src

        #+begin_src sh :tangle yes :padline no
          echo two
            indented

        #+end_src

        #+begin_src python
        x = 1
        #+end_src

        * COMMENT Skipped
        #+begin_src sh :tangle yes
        echo skipped
        #+end_src

        * Archived                                                          :ARCHIVE:
        #+begin_src sh :tangle yes
        echo archived
        #+end_src

        * Tools
        :PROPERTIES:
        :header-args: :tangle bin/tool.sh :mkdirp yes :shebang "#!/bin/sh"
        :END:
        #+begin_src sh :var name="Ann's" n=3
        echo "$name $n"
        #+end_src

        #+begin_src sh -r
        grep x file   (ref:grep)
        #+end_src

        #+name: helper
        #+begin_src elisp :tangle no
        (message "hi")
        #+end_src

        #+begin_src elisp :tangle init.el :noweb yes :var greeting="hello" count=2
        <<helper>>
        (print greeting)
        #+end_src

        #+begin_src python :noweb strip-tangle :var items=3.5 label="a\"b"
        print(1) <<helper>>
        #+end_src

        #+begin_src text :tangle notes.txt :tangle-mode o600 :prologue "start" :epilogue "end"
        middle
        #+end_src

        #+begin_src conf :tangle ~/../../tmp/../tmp/orgstar-never/x.conf :tangle-mode u+x,g-r
        never written: its folder doesn't exist
        #+end_src

        #+begin_src sh :tangle no
        echo never
        #+end_src

        """#

    static func describe(_ output: Tangle.Output, root: String) -> String {
        output.files.sorted { $0.path < $1.path }.map { file in
            let relative = file.path.hasPrefix(root + "/") ? String(file.path.dropFirst(root.count + 1)) : file.path
            return "== \(relative) \(String(file.mode ?? 0o644, radix: 8))\n" + file.contents
        }.joined()
    }

    @Test func tanglesLikeOrg() throws {
        // The conf block's folder doesn't exist, so Emacs stops there; tangling it alone shows
        // the rest, and the error is checked apart.
        let text = Self.text.replacingOccurrences(of: ":tangle ~/../../tmp/../tmp/orgstar-never/x.conf", with: ":tangle no")
        let ns = text as NSString
        let cases: [(offset: Int, arg: String, scope: Tangle.Scope)] = [
            (0, "nil", .all),
            (ns.range(of: "echo two").location, "'(4)", .block(ns.range(of: "echo two").location)),
            (ns.range(of: "grep x").location, "'(16)", .target(ns.range(of: "grep x").location)),
            (ns.range(of: "echo never").location, "'(4)", .block(ns.range(of: "echo never").location)),
        ]
        let form = { (arg: String) in """
            (let* ((dir (file-truename (make-temp-file "orgstar-tangle" t)))
                   (src (expand-file-name "notes.org" dir))
                   (text (buffer-string)) (pt (point)) out)
              (require 'ob-shell) (require 'ob-python)
              (with-temp-file src (insert text))
              (with-current-buffer (find-file-noselect src)
                (goto-char pt)
                (let ((files (org-babel-tangle \(arg))))
                  (setq out (mapconcat (lambda (f) (format "== %s %o\\n%s" (file-relative-name f dir) (file-modes f)
                                                           (with-temp-buffer (insert-file-contents f) (buffer-string))))
                                       (sort (copy-sequence files) #'string<) ""))))
              (erase-buffer) (insert out))
            """ }
        let results = try EmacsOracle.run(cases.map { EmacsOracle.Case(text: text, point: EmacsOracle.point($0.offset, in: text), form: form($0.arg)) })
        for (c, theirs) in zip(cases, results) {
            let ours = try Tangle.run(text: text, path: "/oracle/notes.org", scope: c.scope).get()
            #expect(Self.describe(ours, root: "/oracle") == theirs.text, "\(c.arg)\nours:\n\(Self.describe(ours, root: "/oracle"))\nemacs:\n\(theirs.text)\n\(theirs.error)")
        }
    }

    static let comments = """
        #+PROPERTY: header-args :comments link
        Before any heading.
        #+begin_src sh :tangle top.sh
        echo top
        #+end_src
        * Setup section :tag:
        Some prose before the block.
          Indented prose.
        #+begin_src emacs-lisp :tangle out.el
        (setq x 1)
        #+end_src
        Between text.
        #+NAME: named-py
        #+begin_src python :tangle out.py :comments both
        print(1)
        #+end_src
        * TODO [#A] Other [1/2]
        #+begin_src sh :tangle sub/out.sh :comments org :mkdirp yes
        echo hi
        #+end_src
        C prose one.
        C prose two.
        #+begin_src c :tangle out.c :comments both
        int x;
        #+end_src
        #+begin_src js :tangle out.js
        let y;
        #+end_src
        #+begin_src conf :tangle out.conf :comments noweb :noweb yes
        a=<<named-py>>
        #+end_src
        #+begin_src lua :tangle out.lua
        x = 1
        #+end_src
        #+begin_src sh :tangle out.el :comments no
        not commented
        #+end_src
        ** Child
        :PROPERTIES:
        :CUSTOM_ID: kid
        :END:
        #+begin_src ruby :tangle out.rb
        puts 1
        #+end_src
        #+begin_src sql :tangle out.sql
        select 1;
        #+end_src
        #+begin_src css :tangle out.css
        a {}
        #+end_src
        #+begin_src java :tangle out.java
        class A {}
        #+end_src
        #+begin_src perl :tangle out.pl
        print 1;
        #+end_src
        #+begin_src latex :tangle out.tex
        \\relax
        #+end_src
        #+begin_src scheme :tangle out.scm
        (display 1)
        #+end_src
        #+begin_src makefile :tangle Makefile
        all:
        #+end_src
        #+begin_src toml :tangle out.toml
        a = 1
        #+end_src
        #+begin_src cpp :tangle out.cpp
        int y;
        #+end_src
        #+begin_src bash :tangle out.bash
        echo b
        #+end_src
        """ + "\n"

    @Test func commentsLikeOrg() throws {
        let form = """
            (let* ((dir (file-truename (make-temp-file "orgstar-tangle" t)))
                   (src (expand-file-name "notes.org" dir))
                   (text (buffer-string)) out)
              (require 'ob-shell) (require 'ob-python)
              (with-temp-file src (insert text))
              (with-current-buffer (find-file-noselect src)
                (let ((files (org-babel-tangle)))
                  (setq out (mapconcat (lambda (f) (format "== %s %o\\n%s" (file-relative-name f dir) (file-modes f)
                                                           (with-temp-buffer (insert-file-contents f) (buffer-string))))
                                       (sort (copy-sequence files) #'string<) ""))))
              (erase-buffer) (insert out))
            """
        let theirs = try EmacsOracle.run([EmacsOracle.Case(text: Self.comments, point: 1, form: form)])[0]
        let ours = try Tangle.run(text: Self.comments, path: "/oracle/notes.org").get()
        #expect(Self.describe(ours, root: "/oracle") == theirs.text, "ours:\n\(Self.describe(ours, root: "/oracle"))\nemacs:\n\(theirs.text)\n\(theirs.error)")
    }

    @Test func refusesWhatItCantDo() {
        for (language, header) in [("haskell", ":comments link"), ("sh", ":tangle (concat \"a\" \".sh\")"), ("sh", ":tangle-mode go+q")] {
            let text = "#+begin_src \(language) :tangle yes \(header)\necho\n#+end_src\n"
            guard case .failure = Tangle.run(text: text, path: "/x/a.org") else { Issue.record("tangled with \(header)"); continue }
        }
        let modes = ["(identity #o755)": 0o755, "o700": 0o700, "rw-r-----": 0o640, "u+x": 0o744, "a=r,u+w": 0o644, "go-r": 0o600]
        for (value, mode) in modes { #expect((try? Tangle.fileMode(value)) == mode, "\(value)") }
    }
}
