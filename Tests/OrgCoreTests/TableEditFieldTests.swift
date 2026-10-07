import Foundation
import Testing
@testable import OrgCore

/// C-c ` (`org-table-edit-field`): what the field editor holds, and the table once it's done.
struct TableEditFieldTests {
    static let text = "Intro\n| Name | Note |\n|------+------|\n| Ann  |   a [[https://x.org][link]] here   |\n| Bob  |      |\n| Cy   | c |\nAfter\n"

    static func offsets() -> [Int] {
        let ns = text as NSString
        return [ns.range(of: "Ann").location + 1, ns.range(of: "link]").location, ns.range(of: "Bob  |").location + 5,
                ns.range(of: "| c").location + 2, ns.range(of: "Note").location]
    }

    @Test func editsTheFieldLikeOrg() throws {
        let offsets = Self.offsets()
        let shown = try offsets.map { offset in
            try EmacsOracle.evaluate(Self.text, "(list (with-current-buffer (find-file-noselect \"oracle.org\") (goto-char \(EmacsOracle.point(offset, in: Self.text))) (org-table-edit-field nil) (buffer-substring-no-properties (point-min) (point-max))))").first
        }
        for (offset, theirs) in zip(offsets, shown) {
            let edit = try #require(BlockEdit.field(at: offset, text: Self.text))
            #expect("#\n# Edit field \(edit.coordinate ?? "") and finish with C-c C-c\n#\n" + edit.content == theirs)
        }
        let edited = "#\n# Edit field and finish with C-c C-c\n#\n  first line\n\n  second\tline  \n"
        let cases = offsets.map { offset in
            EmacsOracle.Case(text: Self.text, point: EmacsOracle.point(offset, in: Self.text), form: """
                (let ((b (current-buffer)))
                  (org-table-edit-field nil) (erase-buffer) (insert \(lispString(edited)))
                  (cl-letf (((symbol-function 'set-window-configuration) (lambda (&rest _) (set-buffer b)))
                            ((symbol-function 'select-window) #'ignore))
                    (org-table-finish-edit-field))
                  (set-buffer b))
                """)
        }
        for (offset, theirs) in zip(offsets, try EmacsOracle.run(cases)) {
            let edit = try #require(BlockEdit.field(at: offset, text: Self.text))
            let ours = runCommand(ReplaceBlockLines(edit: edit, content: edited), Self.text, caret: 0)
            #expect(ours.text == theirs.text, "ours:  \(ours.text.debugDescription) \(ours.failure ?? "")\nemacs: \(theirs.text.debugDescription) \(theirs.error)")
        }
        // Emptied, the field gets a space, as `org-table-get-field` puts one.
        let edit = try #require(BlockEdit.field(at: offsets[0], text: Self.text))
        let emptied = try EmacsOracle.run([EmacsOracle.Case(text: Self.text, point: EmacsOracle.point(offsets[0], in: Self.text), form: """
            (let ((b (current-buffer)))
              (org-table-edit-field nil) (erase-buffer)
              (cl-letf (((symbol-function 'set-window-configuration) (lambda (&rest _) (set-buffer b)))
                        ((symbol-function 'select-window) #'ignore))
                (org-table-finish-edit-field))
              (set-buffer b))
            """)])
        #expect(runCommand(ReplaceBlockLines(edit: edit, content: ""), Self.text, caret: 0).text == emptied[0].text)
        // Outside a data field there's nothing to edit.
        let hline = (Self.text as NSString).range(of: "|---").location + 2
        #expect(BlockEdit.field(at: hline, text: Self.text) == nil)
        #expect(BlockEdit.field(at: 2, text: Self.text) == nil)
    }
}
