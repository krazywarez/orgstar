import Foundation
import Testing
@testable import OrgCore

struct TableTransformTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    static let table = """
        Intro
        | Name   | Qty | When                   | Time |
        |--------+-----+------------------------+------|
        | pear   |  10 | <2026-03-01 Sun>       | 1:30 |
        | Apple  |   2 | [2025-12-24 Thu 10:00] | 0:45 |
        | *fig*  | 2.5 |                        | 2h   |
        | banana |  -1 | <2026-01-15 Thu>       |      |
        |--------+-----+------------------------+------|
        | total  |     |                        |      |
        After
        """ + "\n"

    func compare(_ cases: [(text: String, at: String, command: any OrgCommand, answers: [String: String], form: String)]) throws {
        let emacs = try EmacsOracle.run(cases.map { c in
            EmacsOracle.Case(text: c.text, point: EmacsOracle.point(NSMaxRange((c.text as NSString).range(of: c.at)), in: c.text), form: c.form)
        })
        for (c, theirs) in zip(cases, emacs) {
            let ours = runCommand(c.command, c.text, caret: NSMaxRange((c.text as NSString).range(of: c.at)), answers: c.answers)
            let theirCaret = EmacsOracle.offset(theirs.point, in: theirs.text)
            #expect(ours.text == theirs.text && ours.caret == theirCaret && ours.failure == nil,
                    "\(c.form) at \(c.at)\nours:  \(ours.text.debugDescription) @\(ours.caret) \(ours.failure ?? "")\nemacs: \(theirs.text.debugDescription) @\(theirCaret) \(theirs.error)")
        }
    }

    @Test(.enabled(if: oracle))
    func sortsAndTransposesLikeOrg() throws {
        var cases: [(text: String, at: String, command: any OrgCommand, answers: [String: String], form: String)] = []
        for (at, key) in [("| pea", "a"), ("| pea", "A"), ("|  10", "n"), ("|  10", "N"), ("Sun", "t"), ("1:3", "t"), ("1:3", "T")] {
            cases.append((Self.table, at, SortTableLines(), ["sort": key], "(org-table-sort-lines nil ?\(key))"))
        }
        cases.append((Self.table, "Appl", TransposeTable(), [:], "(org-table-transpose-table-at-point)"))
        cases.append(("| a | b | c |\n| 1 | 2 |\n", "| 1", TransposeTable(), [:], "(org-table-transpose-table-at-point)"))
        try compare(cases)
    }

    @Test(.enabled(if: oracle))
    func convertsRegionsLikeOrg() throws {
        let inputs = [
            "a,b,c\n1,\"x, y\",3\n\"q\"\"r\",,z\n",
            "a\tb\tc\n1\t2\t3\n",
            "alpha  beta gamma\none   two  three\n",
        ]
        for input in inputs {
            let text = "Before\n" + input + "After\n"
            let start = 7
            let end = start + (input as NSString).length
            let emacs = try EmacsOracle.run([EmacsOracle.Case(text: text, point: EmacsOracle.point(start, in: text), form: "(org-table-convert-region \(EmacsOracle.point(start, in: text)) \(EmacsOracle.point(end, in: text)))")])
            let buffer = EmacsBuffer(text, point: start)
            buffer.tableConvertRegion(start, end)
            #expect(buffer.string == emacs[0].text, "ours:  \(buffer.string.debugDescription)\nemacs: \(emacs[0].text.debugDescription)")
        }
    }

    @Test(.enabled(if: oracle))
    func exportsLikeOrg() throws {
        let text = "| a | b, c | \"q\" |\n|---+------+-----|\n| <5> |  |  |\n| 1 | x | y |\n"
        let emacs = try EmacsOracle.evaluate(text, """
            (with-current-buffer (find-file-noselect "oracle.org") (goto-char 3)
              (list (orgtbl-to-csv (org-table-to-lisp) nil) (orgtbl-to-tsv (org-table-to-lisp) nil)))
            """)
        #expect(ImportTable.exportText(text, at: 2, path: "t.csv") == emacs[0] + "\n")
        #expect(ImportTable.exportText(text, at: 2, path: "t.tsv") == emacs[1] + "\n")
    }
}
