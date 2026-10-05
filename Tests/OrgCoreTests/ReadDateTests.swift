import Foundation
import Testing
@testable import OrgCore

/// Emacs Lisp that runs `body` with the clock stopped at `seconds` (UTC in the oracle).
func frozenClock(_ seconds: Int, _ body: String) -> String {
    """
    (cl-letf* ((frozen (seconds-to-time \(seconds)))
               (odt (symbol-function 'decode-time))
               (oft (symbol-function 'format-time-string))
               (otl (symbol-function 'time-less-p))
               ((symbol-function 'current-time) (lambda () frozen))
               ((symbol-function 'org-today) (lambda () (time-to-days frozen)))
               ((symbol-function 'time-less-p) (lambda (a b) (funcall otl (or a frozen) (or b frozen))))
               ((symbol-function 'decode-time) (lambda (&optional time zone form) (funcall odt (or time frozen) zone form)))
               ((symbol-function 'format-time-string) (lambda (f &optional time zone) (funcall oft f (or time frozen) zone))))
      \(body))
    """
}

struct ReadDateTests {
    /// Thu 2026-09-10 00:26 UTC.
    static let now = Date(timeIntervalSince1970: 1_789_000_000)
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func format(_ answer: ReadDate.Answer) -> String {
        let c = answer.components(utc)
        let date = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        return (answer.timeGiven ? date + String(format: " %02d:%02d", c.hour!, c.minute!) : date) + "|" + (answer.endTime ?? "nil")
    }

    static let inputs = [
        "", ".", "+0", "+1", "+2d", "-3d", "+1w", "+2m", "-1y", "++3", "fri", "+fri", "-fri", "+2fri", "mon",
        "2026-10-07", "2026-10-7", "10-7", "7.10.", "7.10.2027", "10/7", "10/7/27", "12/31",
        "3", "15", "sep 15", "15 sep", "jan", "dec 25", "2027",
        "10:00", "9:30", "10am", "3pm", "12am", "12:30pm", "10h", "10h30", "h45",
        "10:00-11:30", "10:00+1:30", "fri 10:00", "2026-10-07 14:15", "+2d 9:00", "+3h",
        "w42", "2027-w01", "w3-5", "tomorrow", "nonsense",
    ]

    @Test func examples() {
        let answer = ReadDate.analyze("fri 10:00", default: Self.now, now: Self.now, calendar: Self.utc)
        #expect(Self.format(answer) == "2026-09-11 10:00|nil")
        #expect(Self.format(ReadDate.analyze("10:00-11:30", default: Self.now, now: Self.now, calendar: Self.utc)) == "2026-09-10 10:00|11:30")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func readDateMatchesEmacs() throws {
        try #require(EmacsOracle.isAvailable)
        let cases = Self.inputs.map { input in
            EmacsOracle.Case(text: "", point: 1, form: frozenClock(1_789_000_000, """
                (eval '(let ((org-time-was-given nil) (org-end-time-was-given nil))
                         (let ((d (org-read-date nil nil "\(input)")))
                           (insert d "|" (or org-end-time-was-given "nil"))))
                      nil)
                """))
        }
        var mismatches = 0
        for (input, emacs) in zip(Self.inputs, try EmacsOracle.run(cases)) {
            let ours = Self.format(ReadDate.analyze(input, default: Self.now, now: Self.now, calendar: Self.utc))
            let theirs = emacs.error.isEmpty ? emacs.text : "error: \(emacs.error)"
            if ours != theirs {
                mismatches += 1
                Issue.record("\(input.debugDescription): ours \(ours), emacs \(theirs)")
            }
        }
        #expect(mismatches == 0)
    }
}
