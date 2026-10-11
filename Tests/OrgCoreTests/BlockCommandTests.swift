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
        let key = StructureTemplate.defaults.first { $0.type == type }?.key ?? "\t"
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [selection], answers: ["template": key, "type": type])
        guard case .commit(let result) = InsertStructureTemplate().run(in: context) else { return (text, 0) }
        var new = text
        for edit in result.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { new = edit.apply(to: new) }
        return (new, result.selection?.first?.lowerBound ?? 0)
    }

    /// Keys of two letters take a second stroke; Tab picks the one-letter key of the same letter.
    @Test func configuredTemplatesTakeTwoStrokes() throws {
        var options = EditingOptions.org
        options.structureTemplates = StructureTemplate.merged([.init(key: "el", type: "src emacs-lisp"), .init(key: "q", type: "QUOTE")])
        func step(_ answers: [String: String]) -> CommandStep {
            InsertStructureTemplate().run(in: EditContext(revision: 0, text: "x\n", tree: OrgParser.parse("x\n"), selection: [0..<0], answers: answers, options: options))
        }
        guard case .prompt(let top) = step([:]) else { Issue.record("no prompt"); return }
        #expect(top.fast?.items.contains(.option(key: "e", name: "example, src emacs-lisp")) == true)
        #expect(top.fast?.items.contains(.option(key: "q", name: "QUOTE")) == true)
        guard case .prompt(let second) = step(["template": "e"]) else { Issue.record("no second prompt"); return }
        #expect(second.key == "template2" && second.fast?.items == [.option(key: "\t", name: "example"), .option(key: "l", name: "src emacs-lisp")])
        guard case .commit(let result) = step(["template": "e", "template2": "l"]) else { Issue.record("no commit"); return }
        #expect(result.edits.reduce("x\n") { $1.apply(to: $0) } == "#+begin_src emacs-lisp\n#+end_src\nx\n")
        guard case .commit(let quote) = step(["template": "q"]) else { Issue.record("no commit"); return }
        #expect(quote.edits.reduce("x\n") { $1.apply(to: $0) }.hasPrefix("#+BEGIN_QUOTE\n"))
    }

    /// `org--insert-structure-template-unique-keys`.
    @Test(.enabled(if: oracle))
    func secondKeysLikeOrg() throws {
        let sets = [["e", "el"], ["e", "el", "elisp", "ex"], ["py", "pl", "p"], ["abc", "abd", "ab"]]
        for keys in sets {
            let ours = InsertStructureTemplate.secondKeys(keys.map { StructureTemplate(key: $0, type: "x") })
                .map { zip(keys, $0).map { String($0.first!) + String($1) } }
            let form = "(list (mapconcat #'identity (org--insert-structure-template-unique-keys '(\(keys.map { lispString($0) }.joined(separator: " ")))) \"|\"))"
            let theirs = try EmacsOracle.evaluate("", form)
            #expect(ours?.joined(separator: "|") == theirs.first, "\(keys)")
        }
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
