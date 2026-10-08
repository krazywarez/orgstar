import Foundation
import Testing
@testable import OrgCore

struct TableFormulaEntryTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    @Test(.enabled(if: oracle))
    func evaluatesTypedFormulasLikeOrg() throws {
        let plain = "| a | b |\n|---+---|\n| 1 | =$1*2 |\n| 3 |   |\nAfter\n"
        let named = "| a | b |\n|---+---|\n| 1 | :=$1+10 |\n| 3 |   |\nAfter\n"
        let stored = "| a | b | c |\n|---+---+---|\n| 1 | 2 | =$1+$2 |\n| 3 | 4 |   |\n#+TBLFM: @2$1=7::$2=$1*2\n"
        let replaced = "| a | b |\n| 1 | =$1*5 |\n#+TBLFM: $2=$1*2::@1$2=x\n"
        let reuse = "| a | b |\n| 2 | = |\n#+TBLFM: $2=$1*2\n\nText\n"
        let last = "| 1 | =$1+1 |\n"
        let prompt = { (arg: String) in "(cl-letf (((symbol-function 'read-string) (lambda (&rest _) \"\"))) (org-table-eval-formula \(arg)))" }
        let cases: [(String, String, any OrgCommand, [String: String], String)] = [
            (plain, "*2", TableCommand(.nextField), [:], "(org-table-next-field)"),
            (plain, "*2", TableCommand(.nextRow), [:], "(org-table-next-row)"),
            (plain, "*2", CtrlCCtrlC(), [:], "(org-ctrl-c-ctrl-c)"),
            (named, "+10", TableCommand(.nextField), [:], "(org-table-next-field)"),
            (stored, "+$2", TableCommand(.nextField), [:], "(org-table-next-field)"),
            (replaced, "*5", TableCommand(.nextField), [:], "(org-table-next-field)"),
            (reuse, "= ", TableCommand(.nextField), [:], "(org-table-next-field)"),
            (last, "+1", CtrlCCtrlC(), [:], "(org-ctrl-c-ctrl-c)"),
            (stored, "| 3", TableEvalFormula(named: false), ["formula": "$1*3"], "(org-table-eval-formula nil \"$1*3\")"),
            (stored, "| 3", TableEvalFormula(named: true), ["formula": "99"], "(org-table-eval-formula '(4) \"99\")"),
            (stored, "| 1 | 2", CtrlCCtrlC(), [:], "(org-ctrl-c-ctrl-c)"),
            (stored, "| 3 | 4", TableEvalFormula(named: false), ["formula": ""], prompt("nil")),
            (stored, "| 1", TableEvalFormula(named: true), ["formula": ""], prompt("'(4)")),
        ]
        let emacs = try EmacsOracle.run(cases.map { c in
            let caret = NSMaxRange((c.0 as NSString).range(of: c.1))
            return EmacsOracle.Case(text: c.0, point: EmacsOracle.point(caret, in: c.0), form: c.4)
        })
        for (c, theirs) in zip(cases, emacs) {
            let caret = NSMaxRange((c.0 as NSString).range(of: c.1))
            let ours = runCommand(c.2, c.0, caret: caret, answers: c.3)
            let theirCaret = EmacsOracle.offset(theirs.point, in: theirs.text)
            #expect(ours.text == theirs.text && ours.caret == theirCaret && ours.failure == nil,
                    "\(c.4) at \(c.1)\nours:  \(ours.text.debugDescription) @\(ours.caret) \(ours.failure ?? "")\nemacs: \(theirs.text.debugDescription) @\(theirCaret) \(theirs.error)")
        }
    }
}

extension TableFormulaEntryTests {
    @Test(.enabled(if: oracle))
    func editsFormulasLikeOrg() throws {
        let text = "| a | b | c |\n|---+---+---|\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |\n#+TBLFM: @3$1=7::$3=$1+$2::$>=$1::@2$2=vsum(@2..@3)::$2=$1*2\n"
        let inTable = (text as NSString).range(of: "| 5").location + 2
        let onTblfm = (text as NSString).range(of: "#+TBLFM").location + 3
        for offset in [inTable, onTblfm] {
            let point = EmacsOracle.point(offset, in: text)
            let emacs = try EmacsOracle.evaluate(text, "(list (with-current-buffer (find-file-noselect \"oracle.org\") (goto-char \(point)) (org-table-edit-formulas) (buffer-substring-no-properties (point-min) (point-max))))")
            #expect(BlockEdit.formulas(at: offset, text: text)?.content == emacs.first)
        }
        let edited = "# Column Formulas\n$2 = $1 * 3\n$3 = $1+\n   $2\n\n@2$2 = 9\n$> = \n"
        let cases = [inTable, onTblfm].map { offset in
            EmacsOracle.Case(text: text, point: EmacsOracle.point(offset, in: text), form: """
                (let ((b (current-buffer)))
                  (org-table-edit-formulas) (erase-buffer) (insert \(lispString(edited)))
                  (cl-letf (((symbol-function 'set-window-configuration) (lambda (&rest _) (set-buffer b))) ((symbol-function 'select-window) #'ignore)) (org-table-fedit-finish))
                  (set-buffer b))
                """)
        }
        for (offset, theirs) in zip([inTable, onTblfm], try EmacsOracle.run(cases)) {
            let edit = try #require(BlockEdit.formulas(at: offset, text: text))
            let ours = runCommand(ReplaceBlockLines(edit: edit, content: edited), text, caret: offset)
            #expect(ours.text == theirs.text, "ours:  \(ours.text.debugDescription) \(ours.failure ?? "")\nemacs: \(theirs.text.debugDescription) \(theirs.error)")
        }
    }
}

extension TableFormulaEntryTests {
    /// Runs a command that should commit: the new text, the caret and the message.
    func committed(_ command: any OrgCommand, _ text: String, after needle: String, answers: [String: String] = [:]) -> (text: String, caret: Int, message: String?)? {
        let caret = NSMaxRange((text as NSString).range(of: needle))
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret], answers: answers)
        guard case .commit(let result) = command.run(in: context) else { return nil }
        var new = text
        for edit in result.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { new = edit.apply(to: new) }
        let message = result.effects.compactMap { effect -> String? in if case .message(let m) = effect { m } else { nil } }.first
        return (new, result.selection?.first?.lowerBound ?? caret, message)
    }

    @Test func formulaEditsAreKeptWithTheirMessage() throws {
        let text = "| a | b |\n|---+---|\n| 1 | 2 |\n#+TBLFM: $2=$1*2\n"
        let removed = try #require(committed(TableEvalFormula(named: false), text, after: "| 1 | 2", answers: ["formula": ""]))
        #expect(removed.text == "| a | b |\n|---+---|\n| 1 | 2 |\n#+TBLFM: \n" && removed.message == "Formula removed", "\(removed)")
        // Text in a field is a Calc symbol, which needs Emacs: the formula is stored and TAB
        // still moves on.
        let symbolic = "| a | b |\n| x | =$1*2 |\n| y |   |\n"
        let tab = try #require(committed(TableCommand(.nextField), symbolic, after: "*2"))
        #expect(tab.text == "| a | b     |\n| x | =$1*2 |\n| y |       |\n#+TBLFM: $2=$1*2\n", "\(tab.text.debugDescription)")
        #expect(tab.caret == (tab.text as NSString).range(of: "| y").location + 2)
        #expect(tab.message?.hasPrefix("The formula was stored; recalculating it needs Emacs") == true)
        let prompted = try #require(committed(TableEvalFormula(named: false), symbolic, after: "| x", answers: ["formula": "$1+1"]))
        #expect(prompted.text.hasSuffix("#+TBLFM: $1=$1+1\n") && prompted.message != nil, "\(prompted)")
    }
}
