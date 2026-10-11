import Foundation
import Testing
@testable import OrgCore

struct ICalendarTests {
    static func lisp(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Random UIDs, which differ between runs.
    static func normalized(_ s: String) -> String {
        s.replacing(#/(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/#, with: "UUID")
    }

    static let seconds = 1_791_000_000

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// `org-icalendar-export-to-ics` on each file with `setup`, a `setq` body, in UTC; or with
    /// `combine`, `org-icalendar-combine-agenda-files` over all of them.
    static func emacs(_ files: [String], setup: String, combine: Bool = false) throws -> [String] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-ics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var paths: [String] = []
        for (i, file) in files.enumerated() {
            let path = folder.appendingPathComponent("cal\(i).org").path
            try file.write(toFile: path, atomically: true, encoding: .utf8)
            paths.append(path)
        }
        let combined = folder.appendingPathComponent("combined.ics").path
        let body = combine
            ? "(let ((org-agenda-files '(\(paths.map(lisp).joined(separator: " "))))) (org-icalendar-combine-agenda-files))"
            : paths.map { "(with-current-buffer (find-file-noselect \(lisp($0))) (org-icalendar-export-to-ics))" }.joined(separator: "\n")
        let script = folder.appendingPathComponent("ics.el")
        try """
        ;;; -*- lexical-binding: t -*-
        (require 'org)
        (require 'ox-icalendar)
        (setq org-adapt-indentation nil user-full-name "Ann" org-export-use-babel nil
              org-icalendar-combined-agenda-file \(lisp(combined)))
        (setq \(setup))
        \(frozenClock(seconds, "(progn " + body + ")"))
        """.write(to: script, atomically: true, encoding: .utf8)
        let log = try EmacsOracle.run(["-Q", "--batch", "-l", script.path], environment: ["TZ": "UTC"])
        let outputs = combine ? [combined] : paths.map { ($0 as NSString).deletingPathExtension + ".ics" }
        return try outputs.map { path in
            guard let data = FileManager.default.contents(atPath: path) else { throw EmacsOracle.EvaluateError(log: log) }
            return String(decoding: data, as: UTF8.self)
        }
    }

    static func ours(_ file: String, index: Int, options: ICalendarOptions) -> String {
        var options = options
        options.timezone = "UTC"
        options.userFullName = "Ann"
        return ICalendarExport.calendar(file, name: "cal\(index).org", options: options, now: Date(timeIntervalSince1970: Double(seconds)), calendar: utc)
    }

    static let files = [
        """
        #+TITLE: My /Cal/
        #+AUTHOR: Ann
        * TODO Meeting with *Bob* and [[https://x.org][site]] :work:
        SCHEDULED: <2026-10-12 Mon 10:00>
        :PROPERTIES:
        :ID: abc-1
        :LOCATION: Room 1, floor 2
        :END:
        Short line with /italic/ and =code= and ~verb~.
        A second line that goes on and on and on and on and on and on and on and on past seventy-two columns for sure.

        - item one
        - item two <2026-10-13 Tue>
          continued

        #+begin_src sh
        echo hi
        #+end_src

        | a | b |
        |---+---|
        | 1 | 2 |
        ** DONE Child :home:
        DEADLINE: <2026-10-20 Tue>
        Text with <2026-10-21 Wed 9:00-10:30> and [2026-10-22 Thu].
        * Plain heading <2026-10-25 Sun +1w>
        CLOSED: [2026-10-01 Thu 10:00]
        :LOGBOOK:
        CLOCK: [2026-10-01 Thu 09:00]--[2026-10-01 Thu 10:00] =>  1:00
        :END:
        Body.
        """,
        """
        #+CATEGORY: errands
        #+TODO: TODO NEXT | DONE
        * TODO [#A] Pay rent :home:money:
        DEADLINE: <2026-11-01 Sun -3d +1m>
        :PROPERTIES:
        :ID: rent
        :APPT_WARNTIME: 15
        :END:
        * NEXT Write report
        SCHEDULED: <2026-10-14 Wed 09:30 +1w> DEADLINE: <2026-12-01 Tue>
        :PROPERTIES:
        :ID: report
        :CATEGORY: work
        :SUMMARY: The quarterly report; draft
        :DESCRIPTION: Numbers, charts \\ and text
        :CLASS: PRIVATE
        :TIMEZONE: Europe/Paris
        :END:
        * TODO Project
        :PROPERTIES:
        :ORDERED: t
        :ID: proj
        :END:
        ** TODO First step
        :PROPERTIES:
        :ID: step1
        :END:
        ** TODO Second step
        :PROPERTIES:
        :ID: step2
        :END:
        * Trip <2026-10-30 Fri>--<2026-11-02 Mon>
        :PROPERTIES:
        :ID: trip
        :END:
        Dates --- and ranges... with an entity \\alpha and a footnote[fn:1].
        Also <2026-10-31 Sat 18:00>--<2026-11-01 Sun 02:30> and an e.g. case that must not break after the period because it is near the edge.
        * Hidden :noexport:
        <2026-10-15 Thu>
        * COMMENT Commented
        <2026-10-16 Fri>
        * Old :ARCHIVE:
        SCHEDULED: <2026-10-17 Sat>
        <2026-10-18 Sun>
        * Deep
        :PROPERTIES:
        :ID: deep
        :END:
        ** Deeper
        :PROPERTIES:
        :ID: deeper
        :END:
        *** Deepest
        :PROPERTIES:
        :ID: deepest
        :END:
        **** Low level <2026-10-19 Mon>
        :PROPERTIES:
        :ID: low
        :END:
        A paragraph under a low level heading, which ox-ascii fills to a narrower width than usual, so this wraps.
        1. first
        2. [X] second, done
           - nested
        3. third
        - term :: definition

        #+begin_quote
        A quoted paragraph that is long enough to wrap at the narrower width inside the quote block margins here.
        #+end_quote
        * Footnotes
        [fn:1] The note.
        """,
        """
        #+ICALENDAR_EXCLUDE_TAGS: private
        #+ICAL-TTL: PT1H
        #+OPTIONS: <:t
        * Event <2026-10-20 Tue 14:00>
        :PROPERTIES:
        :ID: ev
        :END:
        Logged [2026-10-21 Wed] as well.
        * Secret :private:
        <2026-10-22 Thu>
        * Noexport stays :noexport:
        :PROPERTIES:
        :ID: stays
        :END:
        <2026-10-23 Fri>
        """,
        """
        * Notes <2026-10-24 Sat 08:00>
        :PROPERTIES:
        :ID: notes
        :TIMEZONE: UTC
        :APPT_WARNTIME: 5
        :END:
        | Item   | Cost |
        |--------+------|
        | Apples |  1.5 |
        | Pears  |   12 |
        |--------+------|
        | Total  | 13.5 |

        -----

        #+begin_example
          indented
        example
        #+end_example

        : fixed width
        :   line

        :NOTES:
        In a drawer, see [[*Other][the other]] and [[file:other.org][other]] and https://example.com/x and [[Other]].
        :END:

        - [ ] open box
        - [-] partial
          1. sub one
          2. sub two

        H_{2}O and x^2 \\
        on a line of its own.

        <2026-10-26 Mon>

        #+begin_verse
          Roses are red
            violets blue
        #+end_verse
        * Other
        """,
    ]

    static let optionSets: [(lisp: String, ours: ICalendarOptions)] = {
        var sets: [(String, ICalendarOptions)] = [("org-icalendar-timezone \"UTC\"", ICalendarOptions())]
        var todo = ICalendarOptions()
        todo.includeTodo = .unfinished
        todo.useScheduled = ["event-if-todo", "event-if-not-todo", "todo-start"]
        todo.useDeadline = ["event-if-todo-not-done", "todo-due"]
        sets.append(("org-icalendar-include-todo t org-icalendar-use-scheduled '(event-if-todo event-if-not-todo todo-start) org-icalendar-use-deadline '(event-if-todo-not-done todo-due)", todo))
        var all = ICalendarOptions()
        all.includeTodo = .all
        all.categories = ["todo-state", "all-tags", "category"]
        all.alarmTime = 10
        all.withTimestamps = "t"
        all.todoUnscheduledStart = "deadline-warning"
        sets.append(("org-icalendar-include-todo 'all org-icalendar-categories '(todo-state all-tags category) org-icalendar-alarm-time 10 org-icalendar-with-timestamps t org-icalendar-todo-unscheduled-start 'deadline-warning", all))
        var unblocked = ICalendarOptions()
        unblocked.includeTodo = .unblocked
        unblocked.dateTimeFormat = ":%Y%m%dT%H%M%SZ"
        unblocked.includeBody = .characters(20)
        unblocked.scheduledSummaryPrefix = "Sched; "
        sets.append(("org-icalendar-include-todo 'unblocked org-icalendar-date-time-format \":%Y%m%dT%H%M%SZ\" org-icalendar-include-body 20 org-icalendar-scheduled-summary-prefix \"Sched; \"", unblocked))
        var keywords = ICalendarOptions()
        keywords.includeTodo = .keywords(["NEXT"])
        keywords.includeBody = .none
        keywords.excludeTags = ["work"]
        keywords.todoUnscheduledStart = "nil"
        sets.append(("org-icalendar-include-todo '(\"NEXT\") org-icalendar-include-body nil org-icalendar-exclude-tags '(\"work\") org-icalendar-todo-unscheduled-start nil", keywords))
        return sets
    }()

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil), arguments: optionSets.indices)
    func filesMatchEmacs(set: Int) throws {
        let (setup, options) = Self.optionSets[set]
        let emacs = try Self.emacs(Self.files, setup: "org-icalendar-timezone \"UTC\" " + setup)
        for (i, (file, expected)) in zip(Self.files, emacs).enumerated() {
            let mine = Self.normalized(Self.ours(file, index: i, options: options))
            let theirs = Self.normalized(expected)
            #expect(mine == theirs, "file \(i), options \(set)\n\(Self.diff(mine, theirs))")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func combinedMatchesEmacs() throws {
        let emacs = try Self.emacs(Self.files, setup: "org-icalendar-timezone \"UTC\" org-icalendar-include-todo t", combine: true)
        var options = ICalendarOptions()
        options.timezone = "UTC"
        options.userFullName = "Ann"
        options.includeTodo = .unfinished
        let mine = ICalendarExport.combined(Self.files.enumerated().map { ("cal\($0.offset).org", $0.element, OrgSettings.default) },
                                            options: options, now: Date(timeIntervalSince1970: Double(Self.seconds)), calendar: Self.utc)
        #expect(Self.normalized(mine) == Self.normalized(emacs[0]), "\(Self.diff(Self.normalized(mine), Self.normalized(emacs[0])))")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func subtreeMatchesEmacs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-ics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = Self.files[1]
        let path = folder.appendingPathComponent("cal1.org").path
        try file.write(toFile: path, atomically: true, encoding: .utf8)
        let offset = (file as NSString).range(of: "* Deep").location
        let script = folder.appendingPathComponent("ics.el")
        try """
        ;;; -*- lexical-binding: t -*-
        (require 'org)
        (require 'ox-icalendar)
        (setq org-adapt-indentation nil user-full-name "Ann" org-icalendar-timezone "UTC")
        \(frozenClock(Self.seconds, "(with-current-buffer (find-file-noselect \(Self.lisp(path))) (goto-char \(offset + 3)) (org-icalendar-export-to-ics nil t))"))
        """.write(to: script, atomically: true, encoding: .utf8)
        let log = try EmacsOracle.run(["-Q", "--batch", "-l", script.path], environment: ["TZ": "UTC"])
        guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent("cal1.ics").path) else { throw EmacsOracle.EvaluateError(log: log) }
        var options = ICalendarOptions()
        options.timezone = "UTC"
        options.userFullName = "Ann"
        let mine = Self.normalized(ICalendarExport.calendar(file, name: "cal1.org", options: options, subtree: offset + 2, now: Date(timeIntervalSince1970: Double(Self.seconds)), calendar: Self.utc))
        let theirs = Self.normalized(String(decoding: data, as: UTF8.self))
        #expect(mine == theirs, "\(Self.diff(mine, theirs))")
    }

    @Test func foldsLongLinesAndEscapes() {
        #expect(ICalendarExport.cleanup("a,b;c\\d\n e") == "a\\,b\\;c\\\\d\\n e")
        let line = String(repeating: "x", count: 160)
        #expect(ICalendarExport.fold(line) == String(repeating: "x", count: 75) + "\n " + String(repeating: "x", count: 74) + "\n " + String(repeating: "x", count: 11) + "\n")
    }

    /// The first lines that differ.
    static func diff(_ a: String, _ b: String) -> String {
        let x = a.components(separatedBy: "\r\n"), y = b.components(separatedBy: "\r\n")
        for i in 0..<max(x.count, y.count) where (i < x.count ? x[i] : nil) != (i < y.count ? y[i] : nil) {
            return "line \(i)\nours:  \((i < x.count ? x[i] : "<none>").debugDescription)\nemacs: \((i < y.count ? y[i] : "<none>").debugDescription)"
        }
        return "same"
    }
}
