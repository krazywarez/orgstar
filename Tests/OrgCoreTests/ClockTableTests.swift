import Foundation
import Testing
@testable import OrgCore

struct ClockTableTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    static let body = """
        * Project Alpha :work:
        :PROPERTIES:
        :Effort:   3:00
        :END:
        ** TODO Design the [[https://x.org][interface]] [1/2]
        :LOGBOOK:
        CLOCK: [2026-09-07 Mon 09:00]--[2026-09-07 Mon 11:30] =>  2:30
        CLOCK: [2026-09-09 Wed 23:00]--[2026-09-10 Thu 01:00] =>  2:00
        :END:
        *** A very long heading title that goes on and on beyond the narrowing width
        CLOCK: [2026-09-10 Thu 08:00]--[2026-09-10 Thu 08:45] =>  0:45
        ** Write code
        CLOCK: [2026-08-30 Sun 10:00]--[2026-08-30 Sun 12:00] =>  2:00
        CLOCK: => 1:15
        * COMMENT Beta
        CLOCK: [2026-09-08 Tue 14:00]--[2026-09-09 Wed 16:00] => 26:00
        * Untouched

        """

    static let params = [
        ":scope file :maxlevel 2", ":maxlevel 3 :emphasize t", ":maxlevel 1", ":block thisweek", ":block lastweek",
        ":block today :maxlevel 3", ":block 2026-09", ":tstart \"<2026-09-08>\" :tend \"<2026-09-10>\"",
        ":link t :maxlevel 3", ":narrow 20! :maxlevel 3", ":tags t :level t :maxlevel 3", ":properties (\"Effort\") :formula %",
        ":indent nil :maxlevel 3", ":block yesterday", ":block 2026-W36 :maxlevel 3", ":fileskip0 t :block 2025",
    ]

    static func ours(_ text: String, caret: Int, command: any OrgCommand, answers: [String: String] = [:]) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret],
                                  now: Date(timeIntervalSince1970: 1_789_000_000), calendar: utc, answers: answers)
        switch command.run(in: context) {
        case .commit(let result):
            var new = text
            for edit in result.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { new = edit.apply(to: new) }
            return new
        case .failed(let message): return "failed: \(message)"
        default: return "other"
        }
    }

    @Test(.enabled(if: oracle))
    func updatesLikeOrgUpdateDblock() throws {
        var cases: [EmacsOracle.Case] = []
        var ours: [String] = []
        for param in Self.params {
            let text = "#+BEGIN: clocktable \(param)\nold contents\n#+END:\n" + Self.body
            cases.append(EmacsOracle.Case(text: text, point: 1, form: frozenClock(1_789_000_000, "(org-update-dblock)")))
            ours.append(Self.ours(text, caret: 0, command: UpdateDynamicBlock()))
        }
        for (i, (mine, theirs)) in zip(ours, try EmacsOracle.run(cases)).enumerated() {
            #expect(mine == theirs.text, "\(Self.params[i])\nours:\n\(mine)\nemacs:\n\(theirs.text) \(theirs.error)")
        }
    }

    @Test(.enabled(if: oracle))
    func reportsLikeOrgClockReport() throws {
        let text = "Intro\n" + Self.body
        let ns = text as NSString
        let points = [ns.range(of: "Intro").location + 2, ns.range(of: "** Write").location + 3, ns.range(of: "CLOCK: [2026-09-07").location]
        let cases = points.map { EmacsOracle.Case(text: text, point: EmacsOracle.point($0, in: text), form: frozenClock(1_789_000_000, "(org-clock-report)")) }
        let ours = points.map { Self.ours(text, caret: $0, command: ClockReportTable()) }
        for (i, (mine, theirs)) in zip(ours, try EmacsOracle.run(cases)).enumerated() {
            #expect(mine == theirs.text, "at \(points[i])\nours:\n\(mine)\nemacs:\n\(theirs.text) \(theirs.error)")
        }
    }

    @Test(.enabled(if: oracle))
    func setsEffortLikeOrgSetEffort() throws {
        let text = "* Task\n* Other\n:PROPERTIES:\n:Effort:   1:00\n:END:\n"
        let cases = [(0, "0:30"), (8, "2:00")].map { EmacsOracle.Case(text: text, point: $0.0 + 1, form: "(org-set-effort nil \"\($0.1)\")") }
        let ours = [(0, "0:30"), (8, "2:00")].map { Self.ours(text, caret: $0.0, command: SetEffort(), answers: ["effort": $0.1]) }
        #expect(ours == (try EmacsOracle.run(cases)).map(\.text))
    }

    @Test func durations() {
        #expect(ClockTable.duration(0) == "0:00" && ClockTable.duration(95) == "1:35" && ClockTable.duration(1560) == "1d 2:00")
    }
}
