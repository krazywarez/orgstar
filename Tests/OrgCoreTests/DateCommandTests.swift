import Foundation
import Testing
@testable import OrgCore

struct DateCommandTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil
    static let seconds = 1_789_000_000

    static func run(_ command: any OrgCommand, _ text: String, caret: Int, answers: [String: String], options: EditingOptions = .org, lastCommand: String? = nil) -> (text: String, message: String?) {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var answers = answers
        while true {
            let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret], now: Date(timeIntervalSince1970: Double(seconds)),
                                      calendar: utc, answers: answers, options: options, lastCommand: lastCommand)
            switch command.run(in: context) {
            case .commit(let result):
                var new = text
                for edit in result.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { new = edit.apply(to: new) }
                let message = result.effects.compactMap { if case .message(let m) = $0 { m } else { nil } }.first
                return (new, message)
            case .prompt(let prompt) where prompt.key == "note" && answers["note"] == nil:
                answers["note"] = "moved"
            case .failed(let message): return (text, "failed: \(message)")
            default: return (text, "other")
            }
        }
    }

    @Test(.enabled(if: oracle))
    func logsReschedulesLikeOrg() throws {
        let texts = ["* Task\nSCHEDULED: <2026-10-05 Mon>\n", "* Task\nDEADLINE: <2026-10-05 Mon> SCHEDULED: <2026-10-01 Thu>\nbody\n", "* Task\n"]
        let actions: [(any OrgCommand, String, [String: String])] = [
            (SetPlanning(deadline: false), "(org-schedule nil \"2026-10-10\")", ["date": "2026-10-10"]),
            (SetPlanning(deadline: true), "(org-deadline nil \"2026-10-12\")", ["date": "2026-10-12"]),
            (RemovePlanning(deadline: false), "(org-schedule '(4))", [:]),
            (RemovePlanning(deadline: true), "(org-deadline '(4))", [:]),
        ]
        for (how, drawer) in [(LogHow.time, nil as String?), (.note, "LOGBOOK")] {
            var cases: [EmacsOracle.Case] = []
            var ours: [String] = []
            for text in texts {
                for (command, form, answers) in actions {
                    let lisp = """
                        (let ((org-log-reschedule '\(how.rawValue)) (org-log-redeadline '\(how.rawValue)) (org-log-into-drawer \(drawer.map { "\"\($0)\"" } ?? "nil")) (b (current-buffer)))
                          \(form)
                          (run-hooks 'post-command-hook)
                          (when (get-buffer "*Org Note*")
                            (with-current-buffer "*Org Note*" (goto-char (point-max)) (insert "moved") (org-store-log-note)))
                          (set-buffer b))
                        """
                    cases.append(EmacsOracle.Case(text: text, point: 3, form: frozenClock(Self.seconds, lisp)))
                    let options = EditingOptions(logIntoDrawer: drawer, logReschedule: how, logRedeadline: how)
                    ours.append(Self.run(command, text, caret: 2, answers: answers, options: options).text)
                }
            }
            for (i, (mine, theirs)) in zip(ours, try EmacsOracle.run(cases)).enumerated() {
                #expect(mine == theirs.text, "\(how) \(cases[i].form.split(separator: "\n")[2]) on \(cases[i].text.debugDescription)\nours:  \(mine.debugDescription)\nemacs: \(theirs.text.debugDescription) \(theirs.error)")
            }
        }
    }

    @Test(.enabled(if: oracle))
    func insertsRangesLikeOrgTimestamp() throws {
        let text = "Meet <2026-10-05 Mon> then\n"
        let caret = (text as NSString).range(of: " then").location
        let emacs = try EmacsOracle.run([EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text), form: frozenClock(Self.seconds, """
            (let ((last-command 'org-timestamp) (this-command 'org-timestamp) (ord (symbol-function 'org-read-date)))
              (cl-letf (((symbol-function 'org-read-date) (lambda (&optional with-time to-time _from prompt &rest _) (funcall ord with-time to-time "+2d" prompt))))
                (org-timestamp nil)))
            """))])
        let ours = Self.run(InsertTimestamp(), text, caret: caret, answers: ["date": "+2d"], lastCommand: "org.timestamp.active")
        #expect(ours.text == emacs[0].text)
    }

    @Test(.enabled(if: oracle))
    func evaluatesRangesLikeOrg() throws {
        let lines = ["<2026-10-05 Mon>--<2026-10-08 Thu>", "[2026-10-05 Mon 10:00]--[2026-10-07 Wed 12:30]", "x <2026-10-05 Mon 10:00>--<2026-10-05 Mon 10:45> y", "<2026-10-05 Mon>--<2026-10-05 Mon>"]
        let forms = lines.map { "(progn (erase-buffer) (insert \(lispString($0))) (goto-char 1) (org-evaluate-time-range))" }
        let emacs = try EmacsOracle.evaluate("", "(list \(forms.joined(separator: " ")))")
        let ours = lines.map { Self.run(EvaluateTimeRange(), $0, caret: 0, answers: [:]).message ?? "nil" }
        #expect(ours == emacs)
    }
}
