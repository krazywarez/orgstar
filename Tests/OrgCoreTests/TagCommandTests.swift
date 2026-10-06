import Foundation
import Testing
@testable import OrgCore

struct TagCommandTests {
    @Test func promptsWithCurrentTags() {
        let text = "* a :x:y:\n"
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [0..<0])
        #expect(SetTags().run(in: context) == .prompt(Prompt(key: "tags", message: "Tags:", initial: ":x:y:", choices: ["x", "y"], requireMatch: false, completionSeparator: ":")))
    }

    @Test func setsAndClears() {
        let set = runCommand(SetTags(), "* a\n", caret: 0, answers: ["tags": "x y"]).text
        #expect(set == "* a" + String(repeating: " ", count: 77 - 3 - 5) + ":x:y:\n")
        #expect(runCommand(SetTags(), "* a :x:\n", caret: 0, answers: ["tags": ""]).text == "* a\n")
        #expect(runCommand(SetTags(), "text\n", caret: 0, answers: ["tags": "x"]).failure != nil)
    }

    static let variants = ["* a\n", "* a :x:\n", "* TODO a  :x:y:\nbody\n", "* \n", "* :x:\n", "** long " + String(repeating: "word ", count: 15) + ":t:\n"]
    static let answers = ["x", "x:y", ":a:b:", "", "a b", "x"]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func setTagsMatchesEmacs() throws {
        try #require(EmacsOracle.isAvailable)
        var cases: [EmacsOracle.Case] = []
        var ours: [(label: String, text: String, caret: Int)] = []
        for text in Self.variants {
            for offset in EmacsOracle.positions(text) {
                for answer in Self.answers {
                    let list = SetTags.tags(from: answer).map { "\"\($0)\"" }.joined(separator: " ")
                    let form = "(cl-letf (((symbol-function 'completing-read-multiple) (lambda (&rest _) '(\(list))))) (org-set-tags-command))"
                    cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(offset, in: text), form: form))
                    let result = runCommand(SetTags(), text, caret: offset, answers: ["tags": answer])
                    ours.append(("\(answer.debugDescription) at \(offset) in \(text.debugDescription)", result.text, result.caret))
                }
            }
        }
        var mismatches = 0
        for (mine, emacs) in zip(ours, try EmacsOracle.run(cases)) {
            let caret = EmacsOracle.offset(emacs.point, in: emacs.text)
            guard !emacs.error.isEmpty || mine.text != emacs.text || mine.caret != caret else { continue }
            mismatches += 1
            if mismatches <= 10 {
                Issue.record("\(mine.label)\n  ours:  \(mine.text.debugDescription) @\(mine.caret)\n  emacs: \(emacs.error.isEmpty ? "\(emacs.text.debugDescription) @\(caret)" : emacs.error)")
            }
        }
        #expect(mismatches == 0)
    }
}

struct ToggleTagTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func togglesLikeOrgToggleTag() throws {
        let texts = ["* TODO Task\n", "* Task :a:b:\nbody\n", "* Task :x:\n", "* A longer heading title here :a:\n"]
        var cases: [EmacsOracle.Case] = []
        var ours: [String] = []
        for text in texts {
            for (tag, on) in [("x", true), ("a", false), ("x", false), ("new", true)] {
                cases.append(EmacsOracle.Case(text: text, point: 3, form: "(org-toggle-tag \"\(tag)\" '\(on ? "on" : "off"))"))
                ours.append(runCommand(ToggleTag(tag: tag, on: on), text, caret: 2).text)
            }
        }
        for (i, (mine, theirs)) in zip(ours, try EmacsOracle.run(cases)).enumerated() {
            #expect(mine == theirs.text, "\(cases[i].form) on \(cases[i].text.debugDescription)")
        }
    }
}
