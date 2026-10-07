import Foundation
import Testing
@testable import OrgCore

/// C-c C-o on timestamps and date ranges: the agenda days `org-follow-timestamp-link` shows.
struct TimestampLinkTests {
    static let text = """
        * TODO Task
        SCHEDULED: <2026-10-08 Thu> DEADLINE: <2026-10-12 Mon 9:00>
        :LOGBOOK:
        CLOCK: [2026-10-05 Mon 10:00]--[2026-10-06 Tue 11:30] => 25:30
        :END:
        Trip <2026-10-20 Tue>--<2026-10-23 Fri> and [2026-11-01 Sun] then <2026-12-24 Thu 18:00-20:00>.
        No date here.

        """

    @Test func opensTheAgendaLikeOrg() throws {
        let ns = Self.text as NSString
        var offsets: [Int] = []
        for needle in ["<2026-10-08", "Thu>", "<2026-10-12", "9:00>", "[2026-10-05", "Tue 11:30]", "=> 25", "<2026-10-20", "--<2026-10-23", "Fri>", "[2026-11-01", "Sun]", "18:00-20", "No date"] {
            let at = ns.range(of: needle).location
            offsets += [at, at + 1, at + 3]
        }
        let range = ns.range(of: "Sun]")
        offsets.append(range.location + range.length)
        let form = """
            (let (r) (require 'org-agenda) (condition-case nil
                         (cl-letf (((symbol-function 'org-agenda-list) (lambda (&optional _ start span &rest _) (setq r (format "%s %s" start span)))))
                           (org-open-at-point))
                       (error nil))
                     (erase-buffer) (insert (or r "nil")))
            """
        let results = try EmacsOracle.run(offsets.map { EmacsOracle.Case(text: Self.text, point: EmacsOracle.point($0, in: Self.text), form: form) })
        for (offset, theirs) in zip(offsets, results) {
            let ours = Links.timestampDays(at: offset, text: Self.text).map { "\($0.start) \($0.count)" } ?? "nil"
            #expect(ours == theirs.text, "at \(offset) \(ns.substring(with: NSRange(location: offset, length: min(8, ns.length - offset))).debugDescription): ours \(ours), emacs \(theirs.text) \(theirs.error)")
        }
    }
}
