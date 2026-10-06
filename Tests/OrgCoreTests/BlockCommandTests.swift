import Foundation
import Testing
@testable import OrgCore

struct BlockCommandTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    static let text = """
        * Heading
        Some text here.
          Indented line
        * Starred
        #+keyword
        last
        """

    @Test(.enabled(if: oracle))
    func insertsTemplatesLikeOrg() throws {
        let ns = Self.text as NSString
        let points = [ns.range(of: "Some").location, ns.range(of: "text").location, ns.range(of: "Indented").location, ns.length]
        let regions = [("Some", "here."), ("Indented", "#+keyword"), ("Some", "line\n")]
        let types = ["src", "quote", "EXAMPLE", "export html", "verse"]
        var cases: [EmacsOracle.Case] = []
        var ours: [(String, Int)] = []
        for type in types {
            for offset in points {
                cases.append(EmacsOracle.Case(text: Self.text, point: EmacsOracle.point(offset, in: Self.text), form: "(org-insert-structure-template \(lispString(type)))"))
                ours.append(Self.run(type, offset..<offset))
            }
            for (from, to) in regions {
                let start = ns.range(of: from).location
                let end = NSMaxRange(ns.range(of: to))
                cases.append(EmacsOracle.Case(text: Self.text, point: EmacsOracle.point(end, in: Self.text), form: "(progn (transient-mark-mode 1) (set-mark \(EmacsOracle.point(start, in: Self.text))) (activate-mark) (org-insert-structure-template \(lispString(type))))"))
                ours.append(Self.run(type, start..<end))
            }
        }
        for (i, (mine, theirs)) in zip(ours, try EmacsOracle.run(cases)).enumerated() {
            #expect(mine.0 == theirs.text, "\(cases[i].form)\nours:  \(mine.0.debugDescription)\nemacs: \(theirs.text.debugDescription)")
            if mine.0 == theirs.text { #expect(mine.1 == EmacsOracle.offset(theirs.point, in: theirs.text), "\(cases[i].form) caret") }
        }
    }

    static func run(_ type: String, _ selection: Range<Int>) -> (String, Int) {
        let key = InsertStructureTemplate.templates.first { $0.type == type }.map { String($0.key) } ?? "\t"
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [selection], answers: ["template": key, "type": type])
        guard case .commit(let result) = InsertStructureTemplate().run(in: context) else { return (text, 0) }
        var new = text
        for edit in result.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { new = edit.apply(to: new) }
        return (new, result.selection?.first?.lowerBound ?? 0)
    }

    static let blocks = """
        * Code
        #+begin_src python :results output
        def f():
            return 1
        ,* not a heading
        ,#+not a keyword
        #+end_src
        #+begin_example
          indented
        #+end_example
        #+begin_src sh
        #+end_src
        """

    @Test(.enabled(if: oracle))
    func editsBlocksLikeOrgEditSpecial() throws {
        let ns = Self.blocks as NSString
        let points = [ns.range(of: "def f").location, ns.range(of: "#+begin_example").location, ns.range(of: "#+begin_src sh").location + 3]
        let added = "* new star\n#+new keyword\nplain"
        let forms = points.map { point in
            """
            (progn (erase-buffer) (insert \(lispString(Self.blocks))) (goto-char \(EmacsOracle.point(point, in: Self.blocks)))
              (org-edit-special)
              (let ((content (buffer-string)))
                (goto-char (point-max)) (insert \(lispString(added)))
                (org-edit-src-exit)
                (format "%s|%s" content (buffer-string))))
            """
        }
        let emacs = try EmacsOracle.evaluate("", "(list \(forms.joined(separator: " ")))", prelude: "(setq org-src-preserve-indentation t org-src-window-setup 'current-window)")
        let tree = OrgParser.parse(Self.blocks)
        for (point, expected) in zip(points, emacs) {
            guard let edit = BlockEdit.at(point, text: Self.blocks, tree: tree) else {
                Issue.record("no block at \(point)")
                continue
            }
            let context = EditContext(revision: 0, text: Self.blocks, tree: tree, selection: [point..<point])
            var after = Self.blocks
            if case .commit(let result) = ReplaceBlockLines(edit: edit, content: edit.content + added).run(in: context) {
                for e in result.edits { after = e.apply(to: after) }
            }
            #expect("\(edit.content)|\(after)" == expected, "at \(point)")
        }
    }
}
