import Foundation
import Testing
@testable import OrgCore

/// Runs `org-agenda-list` over files in `emacs -Q --batch` with the clock frozen.
enum AgendaOracle {
    struct Line: Codable {
        var line: String
        var type: String?
        var category: String?
        var tod: Int?
        var extra: String?
        var urgency: Int?
        var file: String?
        var pos: Int?
    }

    struct Day: Codable {
        var header: String
        var items: [Line]
    }

    static let keywords = "TODO PROJ LOOP STRT WAIT HOLD IDEA | DONE KILL"

    static func script(files: [String], start: String, span: Int, seconds: Int) -> String {
        let fileList = files.map { "\"\($0)\"" }.joined(separator: " ")
        let words = keywords.split(separator: " ").map { "\"\($0)\"" }.joined(separator: " ")
        return #"""
        ;;; -*- lexical-binding: t -*-
        (require 'org)
        (require 'org-agenda)
        (require 'json)
        (setq org-todo-keywords '((sequence \#(words)))
              org-agenda-files '(\#(fileList)))
        (add-to-list 'auto-mode-alist '("\\.org_archive\\'" . org-mode))
        (defun orgstar-dump ()
          (let (days header items)
            (goto-char (point-min))
            (while (not (eobp))
              (let* ((p (line-beginning-position))
                     (line (buffer-substring-no-properties p (line-end-position)))
                     (hd (get-text-property p 'org-hd-marker)))
                (cond
                 ((get-text-property p 'org-agenda-date-header)
                  (when header (push `((header . ,header) (items . ,(vconcat (nreverse items)))) days))
                  (setq header line items nil))
                 (header
                  (push `((line . ,line)
                          (type . ,(get-text-property p 'type))
                          (category . ,(get-text-property p 'org-category))
                          (tod . ,(get-text-property p 'time-of-day))
                          (extra . ,(get-text-property p 'extra))
                          (urgency . ,(get-text-property p 'urgency))
                          (file . ,(and hd (buffer-file-name (marker-buffer hd))))
                          (pos . ,(and hd (marker-position hd))))
                        items))))
              (forward-line 1))
            (when header (push `((header . ,header) (items . ,(vconcat (nreverse items)))) days))
            (vconcat (nreverse days))))
        \#(frozenClock(seconds, """
          (progn
            (org-agenda-list nil "\(start)" \(span))
            (let ((result (with-current-buffer org-agenda-buffer-name (orgstar-dump))))
              (let ((coding-system-for-write 'utf-8-unix))
                (with-temp-file (getenv "ORACLE_OUTPUT")
                  (insert (json-encode result))))))
        """))
        """#
    }

    static func run(files: [(name: String, text: String)], start: Int, span: Int, today: Int, hour: Int, minute: Int) throws -> [Day] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-agenda-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var paths: [String] = []
        for file in files {
            let url = folder.appendingPathComponent(file.name)
            try file.text.write(to: url, atomically: true, encoding: .utf8)
            paths.append(url.resolvingSymlinksInPath().path)
        }
        let date = Days.date(start)
        let seconds = (today - 719163) * 86400 + hour * 3600 + minute * 60
        let scriptURL = folder.appendingPathComponent("agenda.el")
        let output = folder.appendingPathComponent("output.json")
        try script(files: paths, start: String(format: "%04d-%02d-%02d", date.year, date.month, date.day), span: span, seconds: seconds)
            .write(to: scriptURL, atomically: true, encoding: .utf8)
        let log = try EmacsOracle.run(["-Q", "--batch", "-l", scriptURL.path], environment: ["ORACLE_OUTPUT": output.path, "TZ": "UTC"])
        guard let data = try? Data(contentsOf: output) else { throw OracleError(log: log) }
        let days = try JSONDecoder().decode([Day].self, from: data)
        // Positions as UTF-16 offsets, files by name.
        return days.map { day in
            Day(header: day.header, items: day.items.map { line in
                var line = line
                if let file = line.file, let pos = line.pos, let index = paths.firstIndex(of: URL(fileURLWithPath: file).resolvingSymlinksInPath().path) {
                    line.file = files[index].name
                    line.pos = EmacsOracle.offset(pos, in: files[index].text)
                }
                return line
            })
        }
    }

    struct OracleError: Error { let log: String }

    /// Tags realigned to one space, as their column depends on the window.
    static func normalize(_ line: String) -> String {
        line.replacingOccurrences(of: "[ \\t]+(:[^ \\t]+:)[ \\t]*$", with: " $1", options: .regularExpression)
    }

    static func compare(files: [(name: String, text: String)], start: Int, span: Int, today: Int, hour: Int = 9, minute: Int = 30) throws {
        let emacs = try run(files: files, start: start, span: span, today: today, hour: hour, minute: minute)
        let defaults = OrgSettings.default.withTodoKeywords(keywords)!
        let sources = files.map { AgendaSource(path: $0.name, text: $0.text, defaults: defaults) }
        let ours = Agenda.list(sources, start: start, days: span, today: today, now: (hour, minute), options: .terminal)
        #expect(ours.count == emacs.count)
        for (o, e) in zip(ours, emacs) {
            #expect(o.header == e.header)
            let theirs = e.items.map { item in
                "\(normalize(item.line)) | \(item.type ?? "-") \(item.category ?? "") \(item.tod.map(String.init) ?? "-") [\(item.extra ?? "")] \(item.urgency ?? 0) \(item.file ?? "-")@\(item.pos.map(String.init) ?? "-")"
            }
            let mine = o.items.map { item in
                let type: String = switch item.kind {
                case .timeGrid, .currentTime: "-"
                default: item.kind.rawValue
                }
                return "\(normalize(item.line)) | \(type) \(item.category) \(item.timeOfDay.map(String.init) ?? "-") [\(item.extra)] \(item.urgency) \(item.path ?? "-")@\(item.headingOffset.map(String.init) ?? "-")"
            }
            #expect(mine == theirs, "\(e.header) today \(Days.date(today))")
        }
    }
}

struct AgendaTests {
    @Test func days() {
        #expect(Days.absolute(year: 1970, month: 1, day: 1) == 719163)
        #expect(Days.absolute(year: 2026, month: 10, day: 5) - Days.absolute(year: 2026, month: 9, day: 30) == 5)
        #expect(Days.weekday(Days.absolute(year: 2026, month: 10, day: 5)) == 1)
        #expect(Days.isoWeek(Days.absolute(year: 2026, month: 10, day: 5)) == 41)
        #expect(Days.isoWeek(Days.absolute(year: 2027, month: 1, day: 1)) == 53)
        let d = Days.date(Days.absolute(year: 2024, month: 2, day: 29))
        #expect(d.year == 2024 && d.month == 2 && d.day == 29)
        #expect(Days.date(Days.absolute(year: 2026, month: 2, day: 31)) == (2026, 3, 3))
        #expect(Days.date(Days.absolute(year: 2026, month: 13, day: 1)) == (2027, 1, 1))
    }

    static let synthetic = """
    #+TODO: TODO NEXT | DONE
    #+FILETAGS: :ft:
    Before the first heading <2026-10-05 Mon>.
    * TODO [#A] Pay rent :home:
    SCHEDULED: <2026-10-01 Thu>
    * Meeting 10:00 with Bob
    <2026-10-05 Mon 14:00-15:00>
    * DONE Old
    DEADLINE: <2026-10-03 Sat>
    * NEXT Report :work:
    DEADLINE: <2026-10-12 Mon -3d>
    * NEXT Soon
    DEADLINE: <2026-10-09 Fri>
    * TODO Overdue
    DEADLINE: <2026-09-20 Sun 08:15>
    * Trip
    <2026-10-04 Sun>--<2026-10-07 Wed>
    * Same day range
    <2026-10-06 Tue 10:00>--<2026-10-06 Tue 12:30>
    * Gym
    <2026-09-01 Tue 07:00 +1w>
    ** Child
    :PROPERTIES:
    :CATEGORY: kid
    :END:
    SCHEDULED: <2026-10-06 Tue>
    *** Grandchild :x:
    <2026-10-07 Wed 9am>
    * TODO Water plants
    SCHEDULED: <2026-09-28 Mon .+2d>
    * TODO Monthly
    SCHEDULED: <2026-08-31 Mon +1m>
    * TODO Yearly
    DEADLINE: <2025-10-08 Wed +1y>
    * TODO Delayed
    SCHEDULED: <2026-10-02 Fri -2d>
    * Archived :ARCHIVE:
    <2026-10-05 Mon>
    * COMMENT Commented
    <2026-10-05 Mon>
    * Blocks
    #+begin_src sh
    echo <2026-10-05 Mon>
    #+end_src
    # <2026-10-05 Mon>
    =<2026-10-06 Tue>= and [[https://example.com][<2026-10-06 Tue>]]
    * [#C] Low priority <2026-10-06 Tue>
    * TODO Late meeting 23:30
    SCHEDULED: <2026-10-05 Mon>
    * Props
    :PROPERTIES:
    :WHEN: <2026-10-06 Tue 16:00>
    :END:
    * TODO   Spaces   :a:b:
    <2026-10-06 Tue 11:00>
    * Ünïcode tïtle :tag:
    <2026-10-05 Mon 08:00>
    * Range with times <2026-10-05 Mon 10:00-11:00>
    * Hourly
    <2026-10-04 Sun 22:00 +12h>
    """

    static let second = """
    #+CATEGORY: other
    * WAIT Second file
    DEADLINE: <2026-10-05 Mon>
    * Two stamps
    <2026-10-05 Mon 13:00> and <2026-10-06 Tue>
    """

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func matchesEmacs() throws {
        let files = [("a.org", Self.synthetic), ("b.org", Self.second)]
        for today in [(2026, 10, 5), (2026, 10, 1), (2026, 10, 8), (2026, 9, 29)] {
            let day = Days.absolute(year: today.0, month: today.1, day: today.2)
            try AgendaOracle.compare(files: files, start: day - 3, span: 10, today: day)
        }
        let day = Days.absolute(year: 2026, month: 10, day: 6)
        try AgendaOracle.compare(files: files, start: day, span: 1, today: day)
        try AgendaOracle.compare(files: files, start: day + 1, span: 1, today: day)
    }

    /// `ORGSTAR_ORACLE_CORPUS=<folder>`: the top-level files of the folder, ten days around
    /// two dates.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_ORACLE_CORPUS"] != nil))
    func matchesEmacsOnACorpus() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORGSTAR_ORACLE_CORPUS"]!)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "org" }.sorted { $0.path < $1.path }
            .compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).map { (url.lastPathComponent, $0) } }
        for today in [Days.absolute(Date(), calendar: .current), Days.absolute(year: 2025, month: 3, day: 14)] {
            try AgendaOracle.compare(files: files, start: today - 3, span: 10, today: today)
        }
    }
}
