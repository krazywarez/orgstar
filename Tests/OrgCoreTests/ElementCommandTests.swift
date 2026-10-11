import Foundation
import Testing
@testable import OrgCore

/// `org-drag-element-*`, `org-insert-drawer` and `org-cycle-list-bullet` against Org.
struct ElementCommandTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    /// Texts with `¶` where the caret is.
    static let drags = [
        "* H\nFirst ¶para\nstill first\n\nSecond para\n\nThird\n",
        "* H\nFirst para\n\nSecond ¶para\n\nThird\n",
        "* H\nFirst para\n\n\nSecond para\n¶\nThird\n",
        "* H\n#+NAME: x\n#+begin_src sh\necho ¶hi\n#+end_src\n\nAfter\n",
        "* H\nBefore\n\n#+NAME: x\n#+begin_src sh\necho ¶hi\n#+end_src\n",
        "* H\nOnly ¶para\n** Child\nbody\n",
        "* H\nLast ¶para\n* Next\n",
        "Pre¶amble\n\nmore\n* H\n",
        "* H\n#+begin_quote\nin ¶quote\n\nsecond in quote\n#+end_quote\n",
        "* H\n:NOTES:\none\n\n¶two\n:END:\nafter\n",
        "* H\nA\nB¶",
    ]

    static func place(_ marked: String) -> (text: String, caret: Int) {
        let ns = marked as NSString
        let at = ns.range(of: "¶").location
        return (ns.replacingCharacters(in: NSRange(location: at, length: 1), with: ""), at)
    }

    static func ours(_ command: any OrgCommand, _ text: String, _ caret: Int, answers: [String: String] = [:], selection: Range<Int>? = nil) -> (text: String, caret: Int, failure: String?) {
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [selection ?? caret..<caret], answers: answers)
        switch command.run(in: context) {
        case .commit(let result):
            let new = result.edits.sorted { $0.range.lowerBound > $1.range.lowerBound }.reduce(text) { $1.apply(to: $0) }
            return (new, result.selection?.first?.lowerBound ?? caret, nil)
        case .failed(let message): return (text, caret, message)
        default: return (text, caret, "other")
        }
    }

    @Test(.enabled(if: oracle))
    func dragsLikeOrg() throws {
        var cases: [EmacsOracle.Case] = []
        var ours: [(String, Int, String?)] = []
        for marked in Self.drags {
            let (text, caret) = Self.place(marked)
            for forward in [true, false] {
                cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text), form: forward ? "(org-drag-element-forward)" : "(org-drag-element-backward)"))
                ours.append(Self.ours(DragElement(forward: forward), text, caret))
            }
        }
        for (i, (mine, theirs)) in zip(ours, try EmacsOracle.run(cases)).enumerated() {
            let failed = !theirs.error.isEmpty
            let label = "\(cases[i].form) on \(cases[i].text.debugDescription)"
            if failed {
                #expect(mine.2 != nil && mine.0 == cases[i].text, "\(label): emacs \(theirs.error), ours \(mine.0.debugDescription)")
            } else {
                #expect(mine.0 == theirs.text && mine.1 == EmacsOracle.offset(theirs.point, in: theirs.text),
                        "\(label)\nours:  \(mine.0.debugDescription) @\(mine.1) \(mine.2 ?? "")\nemacs: \(theirs.text.debugDescription) @\(EmacsOracle.offset(theirs.point, in: theirs.text))")
            }
        }
    }

    @Test(.enabled(if: oracle))
    func insertsDrawersLikeOrg() throws {
        let texts: [(String, Range<Int>?)] = [
            ("* H\nbody¶\n", nil), ("* H\n¶\n", nil), ("* H\nbo¶dy\n", nil),
            ("* H\n¶one\ntwo\n\nafter\n", 4..<12), ("* H\n  ¶indented\n  more\n", 4..<22),
        ]
        var cases: [EmacsOracle.Case] = []
        var ours: [(String, Int, String?)] = []
        for (marked, region) in texts {
            let (text, caret) = Self.place(marked)
            let form = region.map { "(progn (transient-mark-mode 1) (set-mark \(EmacsOracle.point($0.lowerBound, in: text))) (goto-char \(EmacsOracle.point($0.upperBound, in: text))) (activate-mark) (org-insert-drawer nil \"NOTES\"))" }
                ?? "(org-insert-drawer nil \"NOTES\")"
            cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(region?.upperBound ?? caret, in: text), form: form))
            ours.append(Self.ours(InsertDrawer(), text, region?.upperBound ?? caret, answers: ["drawer": "NOTES"], selection: region))
        }
        for (i, (mine, theirs)) in zip(ours, try EmacsOracle.run(cases)).enumerated() {
            #expect(mine.0 == theirs.text && mine.1 == EmacsOracle.offset(theirs.point, in: theirs.text),
                    "\(cases[i].form) on \(cases[i].text.debugDescription)\nours:  \(mine.0.debugDescription) @\(mine.1) \(mine.2 ?? "")\nemacs: \(theirs.text.debugDescription) @\(EmacsOracle.offset(theirs.point, in: theirs.text)) \(theirs.error)")
        }
        #expect(Self.ours(InsertDrawer(), "x\n", 0, answers: ["drawer": "bad name"]).failure == "Invalid drawer name")
    }

    @Test(.enabled(if: oracle))
    func cyclesBulletsBothWaysLikeOrg() throws {
        let texts = ["- a¶\n- b\n", "+ a¶\n+ b\n", "1. a¶\n2. b\n", "1) a¶\n", "  * a¶\n  * b\n"]
        var cases: [EmacsOracle.Case] = []
        var ours: [(String, Int, String?)] = []
        for marked in texts {
            let (text, caret) = Self.place(marked)
            for previous in [false, true] {
                cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text), form: previous ? "(org-cycle-list-bullet 'previous)" : "(org-cycle-list-bullet)"))
                ours.append(Self.ours(CycleBullet(previous: previous), text, caret))
            }
        }
        for (i, (mine, theirs)) in zip(ours, try EmacsOracle.run(cases)).enumerated() {
            #expect(mine.0 == theirs.text, "\(cases[i].form) on \(cases[i].text.debugDescription)\nours:  \(mine.0.debugDescription)\nemacs: \(theirs.text.debugDescription) \(theirs.error)")
        }
    }
}
