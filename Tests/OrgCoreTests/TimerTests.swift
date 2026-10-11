import Foundation
import Testing
@testable import OrgCore

/// org-timer against Emacs with the clock frozen: the text the commands insert, and the
/// messages and timers the others leave.
struct TimerOracleTests {
    static let now = 1_789_000_000
    static func date(_ seconds: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }

    /// The timer as Lisp sets it, and as ours.
    static let timers: [(lisp: String, timer: OrgTimer?)] = [
        ("", nil),
        ("(setq org-timer-start-time (seconds-to-time \(now - 75)))", OrgTimer(start: date(now - 75))),
        ("(setq org-timer-start-time (seconds-to-time \(now - 100)) org-timer-pause-time (seconds-to-time \(now - 40)))",
         OrgTimer(start: date(now - 100), paused: date(now - 40))),
        ("(setq org-timer-start-time (seconds-to-time \(now + 3725)) org-timer-countdown-timer (run-with-timer 3725 nil #'ignore) org-timer-countdown-timer-title \"T\")",
         OrgTimer(start: date(now + 3725), isCountdown: true, title: "T")),
    ]

    static func context(_ text: String, caret: Int, timer: OrgTimer?, selection: Range<Int>? = nil, answers: [String: String] = [:]) -> EditContext {
        var options = EditingOptions.org
        options.timer = timer
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [selection ?? caret..<caret],
                           now: date(now), calendar: utc, answers: answers, options: options)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func insertingMatchesEmacs() throws {
        let texts = ["* H\n\n", "* H\nfoo\n", "- 0:00:05 :: a\n- 0:01:00 :: b\n", "- a\n- b\n", "  text\n", "1. 0:00:03 :: x\n", "- [ ] 0:00:01 :: c\n"]
        let commands: [(command: any OrgCommand, form: String)] = [
            (InsertTimer(), "(org-timer)"),
            (InsertTimerItem(), "(org-timer-item)"),
            (InsertItem(), "(or (org-insert-item) (error \"Not in an item\"))"),
        ]
        var cases: [EmacsOracle.Case] = []
        var ours: [(label: String, text: String, caret: Int, failed: Bool)] = []
        for text in texts {
            for offset in EmacsOracle.positions(text) {
                for (lisp, timer) in Self.timers {
                    for (command, form) in commands {
                        cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(offset, in: text),
                                                      form: frozenClock(Self.now, "(progn (require 'org-timer) (setq org-timer-start-time nil org-timer-pause-time nil org-timer-countdown-timer nil) \(lisp) \(form))")))
                        let label = "\(command.id) at \(offset) with \(lisp) in \(text.debugDescription)"
                        switch command.run(in: Self.context(text, caret: offset, timer: timer)) {
                        case .commit(let result):
                            let new = result.edits.sorted { $0.range.lowerBound > $1.range.lowerBound }.reduce(text) { $1.apply(to: $0) }
                            ours.append((label, new, result.selection?.first?.lowerBound ?? offset, false))
                        default:
                            ours.append((label, text, offset, true))
                        }
                    }
                }
            }
        }
        let results = try EmacsOracle.run(cases)
        var mismatches = 0
        for (mine, theirs) in zip(ours, results) {
            let theirCaret = theirs.text.unicodeScalars.prefix(theirs.point - 1).reduce(0) { $0 + $1.utf16.count }
            let same = mine.failed ? !theirs.error.isEmpty : theirs.error.isEmpty && mine.text == theirs.text && mine.caret == theirCaret
            if !same {
                mismatches += 1
                if mismatches <= 15 { Issue.record("\(mine.label)\n ours:  \(mine.failed ? "failed" : mine.text.debugDescription) @\(mine.caret)\n emacs: \(theirs.error.isEmpty ? theirs.text.debugDescription : theirs.error) @\(theirCaret)") }
            }
        }
        #expect(mismatches == 0, "\(mismatches) of \(cases.count) cases differ")
    }

    /// What a command leaves: its message, and the timer as `start paused countdown title`.
    static let report = """
        (format "%s|%s" msg
          (if org-timer-start-time
              (format "%s %s %s %s" (format-time-string "%s" org-timer-start-time)
                      (if org-timer-pause-time (format-time-string "%s" org-timer-pause-time) "nil")
                      (if org-timer-countdown-timer "t" "nil")
                      (if org-timer-countdown-timer org-timer-countdown-timer-title "nil"))
            "none"))
        """

    static func ourReport(_ step: CommandStep, before: OrgTimer?) -> String {
        var message = ""
        var timer = before
        switch step {
        case .commit(let result):
            for effect in result.effects {
                if case .message(let m) = effect { message = m }
                if case .timer(let t) = effect { timer = t }
            }
        case .failed(let m): message = m
        default: message = "prompt"
        }
        let state = timer.map { t in
            "\(Int(t.start.timeIntervalSince1970)) \(t.paused.map { String(Int($0.timeIntervalSince1970)) } ?? "nil") \(t.isCountdown ? "t" : "nil") \(t.isCountdown ? (t.title ?? "nil") : "nil")"
        } ?? "none"
        return message + "|" + state
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func timerStateMatchesEmacs() throws {
        let text = "* TODO Write :work:\n:PROPERTIES:\n:Effort:   0:25\n:END:\n* Plain\n- 0:02:10 :: x\n"
        let plain = (text as NSString).range(of: "* Plain").location
        let stamp = (text as NSString).range(of: "0:02:10").location + 3
        // Command, Lisp, caret, answers, and the stubbed minibuffer answer.
        let commands: [(command: any OrgCommand, form: String, caret: Int, answers: [String: String])] = [
            (TimerStart(), "(org-timer-start)", 0, [:]),
            (TimerStart(offset: true), "(org-timer-start '(4))", 0, ["offset": "1:30"]),
            (TimerStart(offset: true), "(org-timer-start '(4))", stamp, ["offset": ""]),
            (TimerPauseOrContinue(), "(org-timer-pause-or-continue)", 0, [:]),
            (TimerStop(), "(org-timer-stop)", 0, [:]),
            (TimerShowRemaining(), "(org-timer-show-remaining-time)", 0, [:]),
            (TimerSetCountdown(), "(org-timer-set-timer)", 0, ["replace": "n"]),
            (TimerSetCountdown(), "(org-timer-set-timer)", plain, ["minutes": "10", "replace": "y"]),
            (TimerSetCountdown(), "(org-timer-set-timer)", plain, ["minutes": "1:02:03", "replace": "n"]),
            (InsertTimer(), "(org-timer)", 0, [:]),
        ]
        var cases: [EmacsOracle.Case] = []
        var ours: [String] = []
        for (lisp, timer) in Self.timers {
            for (command, form, caret, answers) in commands {
                let minibuffer = answers["minutes"] ?? answers["offset"] ?? ""
                let yes = answers["replace"] == "y" ? "t" : "nil"
                let body = """
                    (progn (require 'org-timer)
                      (let ((msg ""))
                        (cl-letf (((symbol-function 'message) (lambda (f &rest a) (setq msg (if f (apply #'format f a) ""))))
                                  ((symbol-function 'read-string) (lambda (&rest _) \(minibuffer.debugDescription)))
                                  ((symbol-function 'read-from-minibuffer) (lambda (&rest _) \(minibuffer.debugDescription)))
                                  ((symbol-function 'y-or-n-p) (lambda (&rest _) \(yes)))
                                  )
                          (setq org-timer-start-time nil org-timer-pause-time nil org-timer-countdown-timer nil)
                          \(lisp)
                          (condition-case e \(form) (error (setq msg (error-message-string e))))
                          (let ((r \(Self.report))) (erase-buffer) (insert r)))))
                    """
                cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text), form: frozenClock(Self.now, body)))
                ours.append(Self.ourReport(command.run(in: Self.context(text, caret: caret, timer: timer, answers: answers)), before: timer))
            }
        }
        let results = try EmacsOracle.run(cases)
        for (index, (mine, theirs)) in zip(ours, results).enumerated() {
            #expect(mine == theirs.text, "case \(index) ours \(mine.debugDescription) emacs \(theirs.text.debugDescription) \(theirs.error)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func changingTimesMatchesEmacs() throws {
        let text = "- 0:01:10 :: a\n- 0:02:00 :: b\n- -0:00:05 x 10:00:00\n"
        let region = 0..<(text as NSString).length
        var cases: [EmacsOracle.Case] = []
        var ours: [String] = []
        for delta in ["", "0:01:00", "-30", "1:00:00:00", "0:00:00"] {
            cases.append(EmacsOracle.Case(text: text, point: 1, form: """
                (progn (require 'org-timer) (org-timer-change-times-in-region (point-min) (point-max) \(delta.debugDescription)))
                """))
            switch TimerChangeTimes().run(in: Self.context(text, caret: 0, timer: nil, selection: region, answers: ["delta": delta])) {
            case .commit(let result): ours.append(result.edits.sorted { $0.range.lowerBound > $1.range.lowerBound }.reduce(text) { $1.apply(to: $0) })
            case .failed(let message): ours.append("error: " + message)
            default: ours.append("prompt")
            }
        }
        let results = try EmacsOracle.run(cases)
        for (mine, theirs) in zip(ours, results) {
            #expect(mine == (theirs.error.isEmpty ? theirs.text : "error: " + theirs.error), "ours \(mine.debugDescription) emacs \(theirs.text.debugDescription)")
        }
    }

    @Test func conversions() {
        #expect(OrgTimer.hms(3725) == "1:02:05")
        #expect(OrgTimer.hms(-65) == "-0:01:05")
        #expect(OrgTimer.seconds("-1:00:01") == -3601)
        #expect(OrgTimer.fixIncomplete("5") == "0:00:05")
        #expect(OrgTimer.fixIncomplete("2:30") == "0:02:30")
        #expect(OrgTimer(start: Self.date(Self.now - 75)).modeLine(now: Self.date(Self.now)) == " <0:01:15>")
    }
}
