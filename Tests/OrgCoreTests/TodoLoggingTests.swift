import Foundation
import Testing
@testable import OrgCore

struct TodoLoggingTests {
    static let texts = [
        "#+TODO: TODO(t) WAIT(w@/!) | DONE(d!) CANCELED(c@)\n* TODO Task\nBody\n",
        "* TODO Task\nSCHEDULED: <2026-10-05 Mon>\n:PROPERTIES:\n:X: 1\n:END:\nBody\n",
        "* TODO Task\n:LOGBOOK:\n- State \"TODO\"       from              [2026-01-01 Thu 10:00]\n:END:\n",
        "* DONE Task\nCLOSED: [2026-01-01 Thu 10:00]\n",
        "#+STARTUP: lognotedone logdrawer\n* TODO Task\n",
        "#+begin_example\n#+STARTUP: lognotedone logdrawer\n#+end_example\n* TODO Task\n",
        "* TODO Task\n:PROPERTIES:\n:LOGGING: DONE(!) logrepeat\n:LOG_INTO_DRAWER: NOTES\n:END:\n",
        "* TODO Task\nSCHEDULED: <2026-10-05 Mon +1w>\n",
        "* TODO Task\n- item one\n",
        "* TODO Task\n** Child\n",
        "* TODO Task",
    ]

    static let options: [(LogHow?, String?)] = [(nil, nil), (.time, nil), (.time, "LOGBOOK"), (.note, nil), (.note, "LOGBOOK")]

    static let note = "Called back\nsecond line"

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func logsLikeOrgTodo() throws {
        let changes: [(any OrgCommand, String)] = [
            (TodoCycle(), "(org-todo)"),
            (SetTodo(keyword: "DONE"), "(org-todo \"DONE\")"),
            (SetTodo(keyword: "TODO"), "(org-todo \"TODO\")"),
            (SetTodo(keyword: nil), "(org-todo 'none)"),
            (SetTodo(keyword: "WAIT"), "(org-todo \"WAIT\")"),
            (SetTodo(keyword: "CANCELED"), "(org-todo \"CANCELED\")"),
        ]
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        var cases: [EmacsOracle.Case] = []
        var ours: [String] = []
        for text in Self.texts {
            let heading = (text as NSString).range(of: "Task").location
            for (done, drawer) in Self.options {
                let options = EditingOptions(logDone: done, logIntoDrawer: drawer, fastTodoSelection: false)
                for (command, form) in changes {
                    let lisp = """
                        (let ((b (current-buffer)) (org-use-fast-todo-selection nil))
                          ;; As the user's settings, under the file's #+STARTUP.
                          (setq-default org-log-done \(done.map { "'" + $0.rawValue } ?? "nil") org-log-into-drawer \(drawer.map { "\"\($0)\"" } ?? "nil"))
                          (org-mode)
                          \(form)
                          (run-hooks 'post-command-hook)
                          (when (get-buffer "*Org Note*")
                            (with-current-buffer "*Org Note*" (goto-char (point-max)) (insert \(lispString(Self.note))) (org-store-log-note)))
                          (set-buffer b))
                        """
                    cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(heading, in: text), form: frozenClock(1_789_000_000, lisp)))
                    var answers: [String: String] = [:]
                    var result = text
                    while true {
                        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [heading..<heading], now: now, calendar: utc, answers: answers, options: options)
                        switch command.run(in: context) {
                        case .commit(let r):
                            for edit in r.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { result = edit.apply(to: result) }
                        case .prompt(let prompt) where prompt.key == "note" && answers["note"] == nil:
                            answers["note"] = Self.note
                            continue
                        default: break
                        }
                        break
                    }
                    ours.append(result)
                }
            }
        }
        let emacs = try EmacsOracle.run(cases)
        for (i, (mine, theirs)) in zip(ours, emacs).enumerated() {
            #expect(mine == theirs.text, "\(cases[i].form.split(separator: "\n")[1...2].joined()) on \(cases[i].text.debugDescription)\nours:  \(mine.debugDescription)\nemacs: \(theirs.text.debugDescription) \(theirs.error)")
        }
    }

    @Test func asksForTheNote() {
        let text = "#+TODO: TODO(t) WAIT(w@/!) | DONE(d!)\n* TODO Task\n"
        let heading = (text as NSString).range(of: "Task").location
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [heading..<heading])
        #expect(SetTodo(keyword: "WAIT").run(in: context) == .prompt(Prompt(key: "note", message: "Note for state change from \"TODO\" to \"WAIT\":")))
    }
}

func lispString(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}
