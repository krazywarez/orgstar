import Foundation
import Testing
@testable import OrgCore

/// A literate configuration's Emacs Lisp, against `org-babel-tangle-file` with a target file
/// and `emacs-lisp\|elisp`, as `org-babel-load-file` calls it.
struct LiterateConfigTests {
    static let texts = [
        "#+title: Config\n\n* Org\n#+begin_src emacs-lisp\n(setq org-tags-column 0)\n#+end_src\n\n#+begin_src emacs-lisp :tangle no\n(setq org-log-done 'time)\n#+end_src\n",
        "* Shell\n#+begin_src sh\necho no\n#+end_src\n* Lisp\n#+begin_src elisp\n  (setq a 1)\n  (setq b 2)\n#+end_src\n",
        "* COMMENT Off\n#+begin_src emacs-lisp\n(setq off t)\n#+end_src\n* On\n#+begin_src emacs-lisp\n(setq on t)\n#+end_src\n",
        "* Skipped\n:PROPERTIES:\n:header-args:emacs-lisp: :tangle no\n:END:\n#+begin_src emacs-lisp\n(setq skipped t)\n#+end_src\n* Kept\n#+begin_src emacs-lisp\n(setq kept t)\n#+end_src\n",
        "#+PROPERTY: header-args :tangle no\n#+begin_src emacs-lisp\n(setq none t)\n#+end_src\n#+begin_src emacs-lisp :tangle yes\n(setq yes t)\n#+end_src\n",
        "#+header: :tangle no\n#+begin_src emacs-lisp\n(setq header t)\n#+end_src\n* Archived :ARCHIVE:\n#+begin_src emacs-lisp\n(setq archived t)\n#+end_src\n",
    ]

    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func matchesEmacs() throws {
        let cases = Self.texts.map { text in
            EmacsOracle.Case(text: text, point: 1, form: """
                (let* ((dir (make-temp-file "literate" t)) (org (expand-file-name "config.org" dir)) (el (expand-file-name "config.el" dir)))
                  (write-region (point-min) (point-max) org)
                  (org-babel-tangle-file org el "emacs-lisp\\\\|elisp")
                  (erase-buffer)
                  (when (file-exists-p el) (insert-file-contents el)))
                """)
        }
        let results = try EmacsOracle.run(cases)
        #expect(Self.lines(results[0].text) == ["(setq org-tags-column 0)"])
        for (text, theirs) in zip(Self.texts, results) {
            #expect(Self.lines(Tangle.literateLisp(text)) == Self.lines(theirs.text), "\(text)\n\(theirs.error)")
        }
    }

    @Test func keepsLineNumbers() {
        let text = Self.texts[0]
        let lisp = Tangle.literateLisp(text).components(separatedBy: "\n")
        #expect(lisp.count == text.components(separatedBy: "\n").count)
        #expect(lisp[4] == "(setq org-tags-column 0)")
        #expect(lisp.filter { !$0.isEmpty } == ["(setq org-tags-column 0)"])
    }
}
