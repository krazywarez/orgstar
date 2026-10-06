import Foundation
import Testing
@testable import OrgCore

struct NowebTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    static let text = """
        * Code
        #+NAME: greet
        #+begin_src sh
        echo hello
        echo world
        #+end_src

        #+begin_src sh :noweb-ref parts
        part one
        #+end_src

        #+begin_src sh :noweb-ref parts :noweb-sep "\\n# --\\n"
          part two
        #+end_src

        #+NAME: nested
        #+begin_src sh :noweb yes
        start
        <<greet>>
        #+end_src

        #+begin_src sh :noweb yes
        # <<greet>>
        x <<nested>> y
        <<parts>>
        <<missing>> after
        <<notes>>
        #+end_src

        #+begin_src sh :noweb yes :noweb-prefix no
          # <<greet>>
        #+end_src
        * Notes
        :PROPERTIES:
        :ID: notes
        :END:
        Some text
        here.
        * COMMENT hidden
        #+begin_src sh :noweb-ref parts
        hidden part
        #+end_src
        """ + "\n"

    @Test(.enabled(if: oracle))
    func expandsLikeOrg() throws {
        let tree = OrgParser.parse(Self.text)
        let model = DocumentModel(tree: tree)
        let ns = Self.text as NSString
        let blocks = model.srcBlocks.filter { $0.body.contains("<<") }
        let forms = blocks.map { "(progn (goto-char \(EmacsOracle.point($0.range.lowerBound, in: Self.text) + 2)) (org-babel-expand-noweb-references))" }
        let emacs = try EmacsOracle.evaluate(Self.text, "(with-current-buffer (find-file-noselect \"oracle.org\") (list \(forms.joined(separator: " "))))")
        let ours = try blocks.map { try Babel.expandNoweb($0, params: try Babel.Params(block: $0, model: model, text: ns), model: model, text: ns) }
        #expect(ours == emacs)
        #expect(ours.count == 3 && ours[1].contains("# echo world") && ours[1].contains("x echo world y\npart one\npart two") && ours[1].contains("Some text"))
    }
}
