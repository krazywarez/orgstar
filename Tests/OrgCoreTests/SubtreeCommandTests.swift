import Foundation
import Testing
@testable import OrgCore

struct SubtreeCommandTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    static let text = """
        Preamble
        * Banana [#B] :fruit:
        SCHEDULED: <2026-10-07 Wed>
        :PROPERTIES:
        :SIZE: 3
        :END:
        ** Child one
        ** Child two
        * TODO apple 10
        DEADLINE: <2026-10-03 Sat>
        :LOGBOOK:
        CLOCK: [2026-10-01 Thu 09:00]--[2026-10-01 Thu 10:30] =>  1:30
        :END:
        * DONE Cherry 2 [#A]
        [2026-09-01 Tue]
        * *Date* 33
        :PROPERTIES:
        :SIZE: 1
        :END:
        <2026-09-20 Sun>
        ** NEXT inner

        """

    static func offsets(_ text: String) -> [Int] {
        let ns = text as NSString
        var result: [Int] = []
        var at = 0
        while at < ns.length {
            let line = ns.lineRange(for: NSRange(location: at, length: 0))
            result.append(line.location)
            result.append(min(line.location + 2, NSMaxRange(line) - 1))
            at = NSMaxRange(line)
        }
        return Array(Set(result)).sorted()
    }

    static func ours(_ command: any OrgCommand, _ text: String, _ caret: Int, answers: [String: String] = [:]) -> (text: String, caret: Int, copied: String?, failed: Bool) {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret],
                                  now: Date(timeIntervalSince1970: 1_789_000_000), calendar: utc, answers: answers)
        guard case .commit(let result) = command.run(in: context) else { return (text, caret, nil, true) }
        var new = text
        for edit in result.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { new = edit.apply(to: new) }
        let copied = result.effects.compactMap { if case .copy(let s) = $0 { s } else { nil } }.first
        return (new, result.selection?.first?.lowerBound ?? caret, copied, false)
    }

    @Test(.enabled(if: oracle))
    func cutsAndCopiesLikeOrg() throws {
        for cut in [true, false] {
            let offsets = Self.offsets(Self.text).filter { $0 >= 9 }
            let forms = offsets.map { offset in
                "(progn (erase-buffer) (insert \(lispString(Self.text))) (goto-char \(EmacsOracle.point(offset, in: Self.text))) (setq kill-ring nil) (org-\(cut ? "cut" : "copy")-subtree) (format \"%s|%d|%s\" (buffer-string) (1- (point)) (car kill-ring)))"
            }
            let emacs = try EmacsOracle.evaluate("", "(list \(forms.joined(separator: " ")))")
            for (offset, expected) in zip(offsets, emacs) {
                let mine = Self.ours(CopySubtree(cut: cut), Self.text, offset)
                #expect("\(mine.text)|\(mine.caret)|\(mine.copied ?? "nil")" == expected, "cut \(cut) at \(offset)")
            }
        }
    }

    static let trees = ["* Pasted\nbody\n** Sub\n", "*** Deep\n**** Deeper", "\n** Two\n* One\n"]

    @Test(.enabled(if: oracle))
    func pastesLikeOrg() throws {
        let offsets = Self.offsets(Self.text) + [(Self.text as NSString).length]
        var forms: [String] = []
        var ours: [String] = []
        for tree in Self.trees {
            for offset in offsets {
                forms.append("(progn (erase-buffer) (insert \(lispString(Self.text))) (goto-char \(EmacsOracle.point(offset, in: Self.text))) (condition-case e (progn (org-paste-subtree nil \(lispString(tree))) (format \"%s|%d\" (buffer-string) (1- (point)))) (error \"error\")))")
                let mine = Self.ours(PasteSubtree(text: tree), Self.text, offset)
                ours.append(mine.failed ? "error" : "\(mine.text)|\(EmacsOracle.point(mine.caret, in: mine.text) - 1)")
            }
        }
        let emacs = try EmacsOracle.evaluate("", "(list \(forms.joined(separator: " ")))")
        for (i, (mine, theirs)) in zip(ours, emacs).enumerated() {
            #expect(mine == theirs, "case \(i)\nours:  \(mine.debugDescription)\nemacs: \(theirs.debugDescription)")
        }
    }

    @Test(.enabled(if: oracle))
    func clonesLikeOrg() throws {
        let texts = [
            "* Task\n:PROPERTIES:\n:ID: old\n:END:\nSCHEDULED: <2026-10-05 Mon>\n:LOGBOOK:\nCLOCK: [2026-10-01 Thu 09:00]--[2026-10-01 Thu 10:00] =>  1:00\n:END:\n* Next\n",
            "* Repeat\nSCHEDULED: <2026-10-05 Mon +1w>\n<2026-10-06 Tue 10:00>\n",
            "* Plain\nbody\n",
        ]
        let runs: [(Int, String)] = [(2, "+1d"), (1, ""), (3, "-2w"), (0, "+1m")]
        var forms: [String] = []
        var ours: [String] = []
        for text in texts {
            for (count, shift) in runs {
                forms.append("(progn (erase-buffer) (insert \(lispString(text))) (goto-char 3) (cl-letf (((symbol-function 'org-id-new) (lambda (&rest _) \"NEW-ID\")) ((symbol-function 'org-id-add-location) #'ignore)) (org-clone-subtree-with-time-shift \(count) \(lispString(shift)))) (buffer-string))")
                let answers = ["count": String(count), "shift": shift]
                ours.append(Self.ours(CloneSubtree(newID: { "NEW-ID" }), text, 2, answers: answers).text)
            }
        }
        let emacs = try EmacsOracle.evaluate("", frozenClock(1_789_000_000, "(list \(forms.joined(separator: " ")))"), prelude: "(require 'org-id) (require 'cl-lib)")
        for (i, (mine, theirs)) in zip(ours, emacs).enumerated() {
            #expect(mine == theirs, "case \(i)\nours:  \(mine.debugDescription)\nemacs: \(theirs.debugDescription)")
        }
    }

    @Test(.enabled(if: oracle))
    func sortsLikeOrgSortEntries() throws {
        let keys = ["a", "n", "p", "o", "t", "s", "d", "c", "k", "r", "A", "N", "P", "O", "T", "R"]
        let starts = [0, (Self.text as NSString).range(of: "* Banana").location, (Self.text as NSString).range(of: "* *Date*").location]
        var forms: [String] = []
        var ours: [String] = []
        for start in starts {
            for key in keys {
                let property = key.lowercased() == "r" ? " nil nil \"SIZE\"" : ""
                forms.append("(progn (erase-buffer) (insert \(lispString(Self.text))) (goto-char \(EmacsOracle.point(start, in: Self.text))) (condition-case e (progn (org-sort-entries nil ?\(key)\(property)) (format \"%s|%d\" (buffer-string) (1- (point)))) (error (error-message-string e))))")
                var answers = ["sort": key]
                if key.lowercased() == "r" { answers["property"] = "SIZE" }
                let mine = Self.ours(SortEntries(), Self.text, start, answers: answers)
                ours.append(mine.failed ? "failed" : "\(mine.text)|\(EmacsOracle.point(mine.caret, in: mine.text) - 1)")
            }
        }
        let emacs = try EmacsOracle.evaluate("", frozenClock(1_789_000_000, "(list \(forms.joined(separator: " ")))"))
        for (i, (mine, theirs)) in zip(ours, emacs).enumerated() {
            #expect(mine == theirs, "case \(i) key \(keys[i % keys.count])\nours:  \(mine.debugDescription)\nemacs: \(theirs.debugDescription)")
        }
    }
}
