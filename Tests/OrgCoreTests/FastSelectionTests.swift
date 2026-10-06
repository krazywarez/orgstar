import Foundation
import Testing
@testable import OrgCore

struct FastSelectionTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    static let todoTexts = [
        // Without log flags: notes are stored after the command, which these cases don't reach.
        "#+TODO: TODO(t) WAIT(w) | DONE(d) CANCELED(c)\n* TODO Task\n",
        "#+TODO: TODO(t) NEXT | DONE(d)\n#+TODO: BUG(b) TRIAGE(t) | FIXED(f)\n* BUG Task\n",
        "#+TODO: TODO(t) NEXT | DONE(d)\n#+TODO: BUG(b) TRIAGE(t) | FIXED(f)\n* Task\n",
        "#+TODO: TODO(t) DOING DONE\n* DOING Task\n",
    ]

    @Test(.enabled(if: oracle))
    func selectsTodoLikeOrgTodo() throws {
        var cases: [EmacsOracle.Case] = []
        var ours: [String] = []
        for text in Self.todoTexts {
            let heading = (text as NSString).range(of: "Task").location
            for key in ["t", "w", "d", " ", "x", "q", "n", "o", "0", "f"] {
                let char = key == " " ? "?\\s" : "?" + key
                cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(heading, in: text), form: """
                    (condition-case nil
                        (cl-letf (((symbol-function 'read-char-exclusive) (lambda (&rest _) \(char)))) (org-todo))
                      (quit nil))
                    """))
                ours.append(runCommand(TodoCycle(), text, caret: heading, answers: ["todo": key]).text)
            }
        }
        let emacs = try EmacsOracle.run(cases)
        for (i, (mine, theirs)) in zip(ours, emacs).enumerated() {
            #expect(mine == theirs.text, "\(mine.debugDescription) vs \(theirs.text.debugDescription) \(cases[i].form) on \(cases[i].text.debugDescription)")
        }
    }

    @Test(.enabled(if: oracle))
    func shiftsLikeOrgShiftRightAndLeft() throws {
        let texts = Self.todoTexts + ["* Task\n", "* TODO Task\n", "* DONE Task\n"]
        var cases: [EmacsOracle.Case] = []
        var ours: [String] = []
        for text in texts {
            let heading = (text as NSString).range(of: "Task").location
            for (right, form) in [(true, "(org-shiftright)"), (false, "(org-shiftleft)"), (true, "(progn (org-shiftright) (org-shiftright))")] {
                cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(heading, in: text), form: form))
                var result = runCommand(TodoShift(right: right), text, caret: heading).text
                if form.contains("progn") { result = runCommand(TodoShift(right: right), result, caret: heading).text }
                ours.append(result)
            }
        }
        let emacs = try EmacsOracle.run(cases)
        for (i, (mine, theirs)) in zip(ours, emacs).enumerated() {
            #expect(mine == theirs.text, "\(mine.debugDescription) vs \(theirs.text.debugDescription) \(cases[i].form) on \(cases[i].text.debugDescription) \(theirs.error)")
        }
    }

    static let tagTexts = [
        "#+TAGS: work(w) home(h) errand\n* Task :home:\n",
        "#+TAGS: { office(o) home(h) } computer(c) phone\n#+TAGS: @read reading\n* Task :phone:\n",
        "#+TAGS: [ Project : alpha(a) beta(b) ] solo(s)\n#+FILETAGS: :top:\n* Parent :solo:\n** Task\n",
        "#+TAGS: alpha(a) apple avocado\n* Task :avocado:alpha:\n",
    ]

    @Test(.enabled(if: oracle))
    func selectsTagsLikeOrgFastTagSelection() throws {
        let sequences = ["\r", "w\r", "wh\r", "o\r", "oh\r", "c o h\r", "!oh\r", " \r", "a\r", "e\r", "r\r", "q", "ap\r", "s\r", "b\r", "AB\r"]
        var cases: [EmacsOracle.Case] = []
        var ours: [String] = []
        for text in Self.tagTexts {
            let heading = (text as NSString).range(of: "Task").location
            for keys in sequences {
                let chars = keys.map { $0 == "\r" ? "?\\r" : $0 == " " ? "?\\s" : "?" + String($0) }.joined(separator: " ")
                cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(heading, in: text), form: """
                    (condition-case nil
                        (let ((keys (list \(chars))))
                          (cl-letf (((symbol-function 'read-char-exclusive) (lambda (&rest _) (if keys (pop keys) (signal 'quit nil)))))
                            (org-set-tags-command)))
                      (quit nil))
                    """))
                let answer = String(keys.prefix { $0 != "\r" })
                ours.append(runCommand(SetTags(), text, caret: heading, answers: ["tags": answer]).text)
            }
        }
        let emacs = try EmacsOracle.run(cases)
        for (i, (mine, theirs)) in zip(ours, emacs).enumerated() {
            #expect(mine == theirs.text, "\(mine.debugDescription) vs \(theirs.text.debugDescription) \(cases[i].form.split(separator: "\n")[1]) on \(cases[i].text.debugDescription) \(theirs.error)")
        }
    }

    @Test func assignsTagKeysAsOrgDoes() {
        let table = FastSelection.tagTable("#+TAGS: alpha(a) apple avocado banana @bread\n")!
        let fast = FastSelection.tags(table: table, current: [], inherited: [])!
        #expect(fast.options.map { "\($0.key)\($0.name)" } == ["aalpha", "bapple", "cavocado", "dbanana", "e@bread"])
    }

    @Test func encodesTypedTags() {
        let inputs: [FastSelection.Input] = [.key("a"), .typed("new tag"), .key(" ")]
        #expect(FastSelection.decode(FastSelection.encode(inputs)) == inputs)
    }
}

struct TodoKeywordSettingsTests {
    @Test func readsOneSequencePerLine() {
        let settings = OrgSettings.default.withTodoKeywords("TODO(t) | DONE(d)\nBUG | FIXED\n")!
        #expect(settings.todoSequences.map { ($0.active + $0.done).map(\.name) } == [["TODO", "DONE"], ["BUG", "FIXED"]])
        #expect(OrgSettings.default.withTodoKeywords("\n") == nil)
    }
}
