import Foundation
import Testing
@testable import OrgCore

struct PrioritySetTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    @Test(.enabled(if: oracle))
    func setsPrioritiesLikeOrg() throws {
        let texts = ["* TODO Task :tag:\nbody\n", "* [#B] Plain\n", "* DONE [#A] Done one   :x:y:\n", "* Heading\n"]
        // Org reads SPC and lower case only at its prompt.
        let values: [(Character, String)] = [("A", "(org-priority ?A)"), ("C", "(org-priority ?C)"),
                                             (" ", "(cl-letf (((symbol-function 'read-char-exclusive) (lambda (&rest _) ?\\s))) (org-priority))"),
                                             ("b", "(cl-letf (((symbol-function 'read-char-exclusive) (lambda (&rest _) ?b))) (org-priority))")]
        var cases: [EmacsOracle.Case] = []
        var ours: [(String, String?)] = []
        for text in texts {
            for (value, form) in values {
                cases.append(EmacsOracle.Case(text: text, point: 3, form: form))
                let result = runCommand(SetPriority(), text, caret: 2, answers: ["priority": String(value)])
                ours.append((result.text, result.failure))
            }
            cases.append(EmacsOracle.Case(text: text, point: 3, form: "(org-priority ?D)"))
            let result = runCommand(SetPriority(), text, caret: 2, answers: ["priority": "D"])
            ours.append((result.text, result.failure))
        }
        for (i, theirs) in try EmacsOracle.run(cases).enumerated() {
            #expect(ours[i].0 == theirs.text, "\(cases[i].form) on \(cases[i].text.debugDescription)")
            #expect((ours[i].1 != nil) == !theirs.error.isEmpty, "\(cases[i].form): \(ours[i].1 ?? "") vs \(theirs.error)")
        }
    }

    @Test func speedKeysHoldAtHeadingStarts() {
        let text = "* One\nbody\n** Two\n"
        func holds(_ caret: Int, _ on: Bool) -> Bool {
            KeyContext.holds("speed", in: EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret], options: EditingOptions(useSpeedCommands: on)))
        }
        #expect(holds(0, true))
        #expect(holds(11, true))
        #expect(!holds(1, true))
        #expect(!holds(6, true))
        #expect(!holds(0, false))
    }
}
