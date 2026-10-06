import Foundation
import Testing
@testable import OrgCore

struct ToggleCommandTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    static let text = """
        Intro line
        # a comment
        * TODO [#A] Task :tag:
        SCHEDULED: <2026-10-05 Mon>
        :PROPERTIES:
        :X: 1
        :END:
        Body text
          indented body
        - plain item
        - [ ] open box
        - [X] done box
          - nested item
        ** COMMENT Commented
        *** Deep
        1. first
        2) second
        * DONE Closed one
        last

        """

    /// Runs `command` with `selection` (a caret when empty) and returns the text and caret.
    static func ours(_ command: any OrgCommand, _ text: String, _ selection: Range<Int>) -> (String, Int) {
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [selection], options: .org)
        guard case .commit(let result) = command.run(in: context) else { return (text, selection.upperBound) }
        var new = text
        for edit in result.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { new = edit.apply(to: new) }
        return (new, result.selection?.first?.lowerBound ?? selection.upperBound)
    }

    static func compare(_ command: any OrgCommand, _ form: String, regions: [(String, String)] = []) throws {
        let text = Self.text
        let ns = text as NSString
        var cases: [EmacsOracle.Case] = []
        var mine: [(String, Int)] = []
        var labels: [String] = []
        // Each line's start and a point inside it.
        var lineStart = 0
        while lineStart < ns.length {
            let line = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            for offset in Set([line.location, min(line.location + 3, NSMaxRange(line) - 1)]).sorted() {
                cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(offset, in: text), form: form))
                mine.append(ours(command, text, offset..<offset))
                labels.append("at \(offset)")
            }
            lineStart = NSMaxRange(line)
        }
        for (from, to) in regions {
            let start = ns.range(of: from).location
            let end = NSMaxRange(ns.range(of: to))
            cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(end, in: text), form: "(progn (transient-mark-mode 1) (set-mark \(EmacsOracle.point(start, in: text))) (activate-mark) \(form))"))
            mine.append(ours(command, text, start..<end))
            labels.append("region \(from.debugDescription)…\(to.debugDescription)")
        }
        let emacs = try EmacsOracle.run(cases)
        for (i, (ours, theirs)) in zip(mine, emacs).enumerated() {
            let expectedText = theirs.error.isEmpty ? theirs.text : text
            #expect(ours.0 == expectedText, "\(form) \(labels[i])\nours:  \(ours.0.debugDescription)\nemacs: \(theirs.text.debugDescription) \(theirs.error)")
            if ours.0 == expectedText, theirs.error.isEmpty {
                #expect(ours.1 == EmacsOracle.offset(theirs.point, in: theirs.text), "\(form) \(labels[i]) caret")
            }
        }
    }

    @Test(.enabled(if: oracle))
    func commentsLikeOrg() throws {
        try Self.compare(ToggleComment(), "(org-toggle-comment)")
    }

    @Test(.enabled(if: oracle))
    func togglesHeadingsLikeOrg() throws {
        try Self.compare(ToggleHeading(), "(org-toggle-heading)", regions: [("Body text", "indented body"), ("* TODO", "Body"), ("1. first", "2) second"), ("Intro", "comment")])
    }

    @Test(.enabled(if: oracle))
    func togglesItemsLikeOrgCtrlCMinus() throws {
        try Self.compare(ToggleItem(), "(org-ctrl-c-minus)", regions: [("Body text", "indented body"), ("- plain", "open box"), ("** COMMENT", "Deep"), ("* DONE", "last")])
    }

    @Test(.enabled(if: oracle))
    func marksSubtreesLikeOrg() throws {
        let text = Self.text
        let offsets = [(text as NSString).range(of: "Body").location, (text as NSString).range(of: "*** Deep").location + 2]
        let emacs = try EmacsOracle.evaluate(text, "(mapcar (lambda (p) (goto-char p) (transient-mark-mode 1) (org-mark-subtree) (format \"%d %d\" (1- (region-beginning)) (1- (region-end)))) '(\(offsets.map { String(EmacsOracle.point($0, in: text)) }.joined(separator: " "))))")
        let ours = offsets.map { offset -> String in
            let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [offset..<offset])
            guard case .commit(let result) = MarkSubtree().run(in: context), let range = result.selection?.first else { return "none" }
            return "\(range.lowerBound) \(range.upperBound)"
        }
        #expect(ours == emacs)
    }
}
