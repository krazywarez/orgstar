import Foundation
import Testing
@testable import OrgCore

struct CtrlCCtrlCTests {
    static let text = """
        #+TITLE: Test
        * TODO Task [1/3] :old:
        SCHEDULED: <2026-10-05 Tue>
        :LOGBOOK:
        CLOCK: [2026-10-01 Fri 09:00]--[2026-10-01 Fri 11:30] =>  1:00
        CLOCK: [2026-10-01 Thu 12:00]--[2026-10-01 Thu 12:45]
        :END:
        - [X] one
        - [ ] two
        - three
        1. first
        3. second
        Text with <2026-10-07 Mon> stamp.

        ** DONE Child [50%]
        - [ ] a
        - [X] b
        | a | b |
        |-+-|

        """

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func actsLikeOrgCtrlCCtrlC() throws {
        let ns = Self.text as NSString
        var offsets: [Int] = []
        var at = 0
        while at < ns.length {
            let line = ns.lineRange(for: NSRange(location: at, length: 0))
            offsets += [line.location, min(line.location + 8, NSMaxRange(line) - 1)]
            at = NSMaxRange(line)
        }
        offsets = Array(Set(offsets)).sorted()
        // Cookies and timestamps under the caret.
        offsets += [ns.range(of: "[1/3]").location + 1, ns.range(of: "[50%]").location + 2, ns.range(of: "<2026-10-07").location + 3, ns.range(of: "Fri 09").location]
        var cases: [EmacsOracle.Case] = []
        var ours: [String] = []
        for offset in offsets {
            cases.append(EmacsOracle.Case(text: Self.text, point: EmacsOracle.point(offset, in: Self.text), form: frozenClock(1_789_000_000, """
                (cl-letf (((symbol-function 'completing-read-multiple) (lambda (&rest _) '("x"))))
                  (org-ctrl-c-ctrl-c))
                """)))
            ours.append(runCommand(CtrlCCtrlC(), Self.text, caret: offset, answers: ["tags": "x"]).text)
        }
        for (i, (mine, theirs)) in zip(ours, try EmacsOracle.run(cases)).enumerated() {
            #expect(mine == theirs.text, "at \(offsets[i]) (\(ns.substring(with: ns.lineRange(for: NSRange(location: offsets[i], length: 0)))).debugDescription))\nours:  \(mine.debugDescription)\nemacs: \(theirs.text.debugDescription) \(theirs.error)")
        }
    }
}
