import Foundation
import Testing
@testable import OrgCore

struct NarrowingTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    static let text = """
        Intro line
        * One
        Body of one
        #+begin_src sh
        echo hi
        #+end_src


        ** Child
        child body
        * Two [[https://x.org][link]]
        #+BEGIN_QUOTE
        quoted
        #+END_QUOTE
        last
        #+begin_example
        tail
        #+end_example
        """

    @Test(.enabled(if: oracle))
    func narrowsLikeOrg() throws {
        let ns = Self.text as NSString
        let offsets = ["Intro", "Body", "echo", "child body", "** Child", "quoted", "last", "#+end_src", "#+BEGIN_QUOTE", "#+END_QUOTE", "\n\n**", "tail"].map { ns.range(of: $0).location + 1 }
        for (form, ours) in [("(org-narrow-to-subtree)", Narrowing.subtree), ("(org-narrow-to-block)", Narrowing.block)] {
            let points = offsets.map { String(EmacsOracle.point($0, in: Self.text)) }.joined(separator: " ")
            let emacs = try EmacsOracle.evaluate(Self.text, """
                (with-current-buffer (find-file-noselect "oracle.org")
                  (mapcar (lambda (p) (widen) (goto-char p)
                            (condition-case e (progn \(form) (format "%d %d" (1- (point-min)) (1- (point-max)))) (error "error")))
                          '(\(points))))
                """)
            let mine = offsets.map { offset -> String in
                guard let r = try? ours(offset, Self.text) else { return "error" }
                return "\(r.lowerBound) \(r.upperBound)"
            }
            #expect(mine == emacs, "\(form)")
        }
    }

    @Test func goesToHeadingsByPath() {
        let context = EditContext(revision: 0, text: Self.text, tree: OrgParser.parse(Self.text), selection: [0..<0])
        #expect(GotoHeading.targets(context).map(\.path) == ["One", "One/Child", "Two link"])
        let caret = runCommand(GotoHeading(), Self.text, caret: 0, answers: ["goto": "One/Child"]).caret
        #expect(caret == (Self.text as NSString).range(of: "** Child").location)
    }
}
