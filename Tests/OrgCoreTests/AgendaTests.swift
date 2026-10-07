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

    static func script(files: [String], form: String, seconds: Int) -> String {
        let fileList = files.map { "\"\($0)\"" }.joined(separator: " ")
        let words = keywords.split(separator: " ").map { "\"\($0)\"" }.joined(separator: " ")
        return #"""
        ;;; -*- lexical-binding: t -*-
        (require 'org)
        (require 'org-agenda)
        (require 'org-habit)
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
                 ((get-text-property p 'org-filter-type))
                 ((or header hd)
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
            (when (or header items) (push `((header . ,(or header "")) (items . ,(vconcat (nreverse items)))) days))
            (vconcat (nreverse days))))
        \#(frozenClock(seconds, """
          (progn
            \(form)
            (let ((result (with-current-buffer org-agenda-buffer-name (orgstar-dump))))
              (let ((coding-system-for-write 'utf-8-unix))
                (with-temp-file (getenv "ORACLE_OUTPUT")
                  (insert (json-encode result))))))
        """))
        """#
    }

    static func run(files: [(name: String, text: String)], form: String, today: Int, hour: Int, minute: Int) throws -> [Day] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-agenda-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var paths: [String] = []
        for file in files {
            let url = folder.appendingPathComponent(file.name)
            try file.text.write(to: url, atomically: true, encoding: .utf8)
            paths.append(url.resolvingSymlinksInPath().path)
        }
        let seconds = (today - 719163) * 86400 + hour * 3600 + minute * 60
        let scriptURL = folder.appendingPathComponent("agenda.el")
        let output = folder.appendingPathComponent("output.json")
        try script(files: paths, form: form, seconds: seconds)
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

    /// `org-agenda-prefix-format` as Lisp.
    static func prefixLisp(_ formats: [String: String]) -> String {
        "'(" + formats.sorted { $0.key < $1.key }.map { "(\($0.key) . \"\($0.value)\")" }.joined(separator: " ") + ")"
    }

    static func compare(
        files: [(name: String, text: String)], start: Int, span: Int, today: Int, hour: Int = 9, minute: Int = 30,
        prefix: [String: String]? = nil, logMode: Bool = false
    ) throws {
        let date = Days.date(start)
        var form = "(org-agenda-list nil \"\(String(format: "%04d-%02d-%02d", date.year, date.month, date.day))\" \(span))"
        if let prefix { form = "(let ((org-agenda-prefix-format \(prefixLisp(prefix)))) \(form))" }
        if logMode { form = "(let ((org-agenda-start-with-log-mode t)) \(form))" }
        let emacs = try run(files: files, form: form, today: today, hour: hour, minute: minute)
        let defaults = OrgSettings.default.withTodoKeywords(keywords)!
        let sources = files.map { AgendaSource(path: $0.name, text: $0.text, defaults: defaults) }
        var options = AgendaOptions.terminal
        if let prefix { options.prefixFormat = prefix }
        options.logMode = logMode
        let ours = Agenda.list(sources, start: start, days: span, today: today, now: (hour, minute), options: options)
        #expect(ours.count == emacs.count)
        for (o, e) in zip(ours, emacs) {
            #expect(o.header == e.header)
            #expect(describe(o.items, today: today) == describe(e.items), "\(e.header) today \(Days.date(today))")
        }
    }

    static func describe(_ items: [Line]) -> [String] {
        items.map { item in
            "\(normalize(item.line)) | \(item.type ?? "-") \(item.category ?? "") \(item.tod.map(String.init) ?? "-") [\(item.extra ?? "")] \(item.urgency ?? 0) \(item.file ?? "-")@\(item.pos.map(String.init) ?? "-")"
        }
    }

    static func describe(_ items: [AgendaItem], today: Int = 0) -> [String] {
        items.map { item in
            let line = item.habit.map { Habit.insertGraph($0.graph(today: today), into: item.line) } ?? item.line
            let type: String = switch item.kind {
            case .timeGrid, .currentTime: "-"
            default: item.kind.rawValue
            }
            return "\(normalize(line)) | \(type) \(item.category) \(item.timeOfDay.map(String.init) ?? "-") [\(item.extra)] \(item.urgency) \(item.headingOffset == nil ? "-" : item.path ?? "-")@\(item.headingOffset.map(String.init) ?? "-")"
        }
    }

    /// A TODO list or tags view: `form` runs it in Emacs, `ours` builds ours from the sources.
    static func compareList(files: [(name: String, text: String)], form: String, today: Int, _ ours: ([AgendaSource]) -> [AgendaItem]) throws {
        let emacs = try run(files: files, form: form, today: today, hour: 9, minute: 30)
        let defaults = OrgSettings.default.withTodoKeywords(keywords)!
        let mine = ours(files.map { AgendaSource(path: $0.name, text: $0.text, defaults: defaults) })
        #expect(describe(mine) == describe(emacs.first?.items ?? []), "\(form)")
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
    SCHEDULED: <2026-10-05 Mon>
    <2026-10-05 Mon>
    ** TODO Under archived
    DEADLINE: <2026-10-05 Mon>
    * COMMENT Commented
    DEADLINE: <2026-10-05 Mon>
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

    static let third = """
    #+FILETAGS: :proj:
    * TODO Alpha :work:urgent:
    :PROPERTIES:
    :EFFORT: 2:00
    :SIZE: 3
    :OWNER: alice
    :DUE: <2026-10-10 Sat>
    :END:
    ** NEXT Beta :boss:
    :PROPERTIES:
    :SIZE: 10
    :END:
    *** Gamma :work:
    * DONE Delta :home:
    CLOSED: [2026-10-01 Thu 10:00] SCHEDULED: <2026-09-30 Wed>
    * WAIT [#A] Epsilon 10:30
    :PROPERTIES:
    :OWNER: Bob
    :END:
    <2026-10-03 Sat> [2026-10-02 Fri]
    * HOLD Zeta :x@y:
    * Eta with category
    :PROPERTIES:
    :CATEGORY: cat
    :END:
    ** KILL Theta
    * IDEA [#C] Iota
    * Archived :ARCHIVE:work:
    ** TODO Kappa :work:
    """

    static let matches = [
        "work", "+work-urgent", "work|home", "proj", "{^w}", "-work", "LEVEL>1", "LEVEL=2+boss", "SIZE>5", "SIZE<5",
        "OWNER=\"alice\"", "OWNER={^b}", "OWNER<>\"alice\"", "OWNER<\"b\"", "TODO=\"WAIT\"", "PRIORITY=\"A\"",
        "CATEGORY=\"cat\"", "DUE<\"<2026-10-15>\"", "DUE>\"<today>\"", "SCHEDULED<\"<today>\"", "TIMESTAMP=\"<2026-10-03 Sat>\"",
        "ITEM={lph}", "work/TODO", "/!", "+work/!TODO|WAIT", "EFFORT>\"1:00\"", "ALLTAGS={proj}", "TAGS=\":work:urgent:\"",
        "x@y", "/-TODO", "/!{^[HW]}", "work&urgent", "SIZE>=3+SIZE<=3", "LEVEL<>1",
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func listsMatchEmacs() throws {
        let files = [("a.org", Self.synthetic), ("b.org", Self.second), ("c.org", Self.third)]
        let today = Days.absolute(year: 2026, month: 10, day: 5)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: Double((today - 719163) * 86400 + 9 * 3600 + 30 * 60))
        func lisp(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        try AgendaOracle.compareList(files: files, form: "(org-todo-list nil)", today: today) { Agenda.todoList($0) }
        for keywords in ["WAIT|HOLD", "DONE", "KILL|TODO"] {
            try AgendaOracle.compareList(files: files, form: "(org-todo-list \(lisp(keywords)))", today: today) { Agenda.todoList($0, keywords: keywords) }
        }
        for match in Self.matches {
            for todoOnly in [false, true] {
                try AgendaOracle.compareList(files: files, form: "(org-tags-view \(todoOnly ? "t" : "nil") \(lisp(match)))", today: today) {
                    Agenda.tagsMatch($0, match: match, todoOnly: todoOnly, now: now, calendar: utc)
                }
            }
        }
    }

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
        let today = Days.absolute(Date(), calendar: .current)
        try AgendaOracle.compareList(files: files, form: "(org-todo-list nil)", today: today) { Agenda.todoList($0) }
        for match in ["finance|home", "LEVEL=2", "/!", "PRIORITY=\"A\""] {
            let lisp = "\"" + match.replacingOccurrences(of: "\"", with: "\\\"") + "\""
            try AgendaOracle.compareList(files: files, form: "(org-tags-view nil \(lisp))", today: today) { Agenda.tagsMatch($0, match: match) }
        }
    }
}

struct ReminderTests {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func timedEntriesWithTheirWarnings() {
        let text = """
        * TODO Call
        SCHEDULED: <2026-10-05 Mon 14:00>
        * Meeting
        :PROPERTIES:
        :APPT_WARNTIME: 30
        :END:
        <2026-10-06 Tue 10:00-11:00>
        * DONE Finished
        SCHEDULED: <2026-10-05 Mon 15:00>
        * Untimed
        SCHEDULED: <2026-10-05 Mon>
        * Earlier
        <2026-10-05 Mon 08:00>
        * Soon
        <2026-10-05 Mon 09:35>
        * TODO Report due
        DEADLINE: <2026-10-07 Wed 17:00>
        """
        let source = AgendaSource(path: "/n/a.org", text: text)
        let now = Self.date(5, 9, 30)
        let reminders = Reminders.upcoming([source], now: now, calendar: Self.utc)
        #expect(reminders.map(\.title) == ["Soon", "TODO Call", "Meeting", "TODO Report due"])
        #expect(reminders[0].fireDate == now.addingTimeInterval(1))
        #expect(reminders[1].fireDate == Self.date(5, 13, 48))
        #expect(reminders[1].body == "14:00 · Scheduled: · a")
        #expect(reminders[2].fireDate == Self.date(6, 9, 30))
        #expect(reminders[3].eventDate == Self.date(7, 17, 0))
        #expect(Reminders.upcoming([source], now: now, calendar: Self.utc, limit: 2).count == 2)
        #expect(Reminders.upcoming([source], now: now, calendar: Self.utc, days: 1).map(\.title) == ["Soon", "TODO Call"])
    }

    @Test func repeatsFillTheWeek() {
        let source = AgendaSource(path: "/n/a.org", text: "* Standup\n<2026-10-01 Thu 09:00 +1d>\n")
        let reminders = Reminders.upcoming([source], now: Self.date(5, 9, 30), calendar: Self.utc)
        #expect(reminders.count == 6)
        #expect(Set(reminders.map(\.id)).count == 6)
    }
}

struct AgendaPrefixFormatTests {
    static let file = """
    #+TODO: TODO NEXT | DONE
    * Projects [1/2] :proj:
    ** TODO [#A] Write report :work:
    :PROPERTIES:
    :Effort:   1:30
    :END:
    SCHEDULED: <2026-10-05 Mon 10:00>
    *** NEXT Outline [[https://x.org][the plan]]
    DEADLINE: <2026-10-06 Tue>
    * Errands
    :PROPERTIES:
    :CATEGORY: averyverylongcategory
    :END:
    ** TODO Groceries 14:00
    SCHEDULED: <2026-10-05 Mon>
    """

    static let formats = [
        "agenda": " %i %-12:c%?-12t%-6e% s%l%b", "todo": " %-8.6c %e %?-4l|", "tags": "%c %?-5:l %b", "search": " %i %-12:c",
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func agendaMatchesEmacs() throws {
        let today = Days.absolute(year: 2026, month: 10, day: 5)
        try AgendaOracle.compare(files: [("p.org", Self.file)], start: today, span: 2, today: today, prefix: Self.formats)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func listsMatchEmacs() throws {
        let today = Days.absolute(year: 2026, month: 10, day: 5)
        var options = AgendaOptions()
        options.prefixFormat = Self.formats
        let lisp = AgendaOracle.prefixLisp(Self.formats)
        try AgendaOracle.compareList(files: [("p.org", Self.file)], form: "(let ((org-agenda-prefix-format \(lisp))) (org-todo-list))", today: today) {
            Agenda.todoList($0, options: options)
        }
        try AgendaOracle.compareList(files: [("p.org", Self.file)], form: "(let ((org-agenda-prefix-format \(lisp))) (org-tags-view nil \"work|proj\"))", today: today) {
            Agenda.tagsMatch($0, match: "work|proj", options: options)
        }
    }

    @Test func compilesFields() {
        let format = PrefixFormat(" %-8.6c|%?-4t%e")
        #expect(format.render(["c": "category", "e": "1:00"]) == " categ   |1:00")
        #expect(format.render(["c": "cat", "t": "9:00"]) == " cat     |9:00")
    }
}

struct AgendaLogModeTests {
    static let file = """
    #+TODO: TODO NEXT | DONE
    * DONE Ship release :work:
    CLOSED: [2026-10-05 Mon 16:20] SCHEDULED: <2026-10-05 Mon>
    :LOGBOOK:
    CLOCK: [2026-10-05 Mon 14:00]--[2026-10-05 Mon 15:30] =>  1:30
    - Fixed the build
    CLOCK: [2026-10-04 Sun 22:00]--[2026-10-05 Mon 01:15] =>  3:15
    :END:
    * TODO Writing
    :LOGBOOK:
    CLOCK: [2026-10-06 Tue 09:00]--[2026-10-06 Tue 09:45] =>  0:45
    CLOCK: [2026-10-06 Tue 11:00]
    :END:
    ** DONE Draft [1/1]
    CLOSED: [2026-10-06 Tue]
    * Archived :ARCHIVE:
    CLOSED: [2026-10-05 Mon 10:00]
    * Plain
    Mentions CLOSED: [2026-10-05 Mon 09:00] in text.
    """

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func logModeMatchesEmacs() throws {
        let today = Days.absolute(year: 2026, month: 10, day: 5)
        try AgendaOracle.compare(files: [("log.org", Self.file)], start: today - 1, span: 3, today: today, logMode: true)
        try AgendaOracle.compare(files: [("log.org", Self.file)], start: today - 1, span: 3, today: today, prefix: ["agenda": " %-8:c%?-12t%s %l"], logMode: true)
    }
}

struct AgendaFilterTests {
    static let file = """
    #+TODO: TODO NEXT | DONE
    #+CATEGORY: home
    * TODO Groceries :errand:
    :PROPERTIES:
    :Effort:   0:20
    :END:
    SCHEDULED: <2026-10-05 Mon>
    * Work stuff
    :PROPERTIES:
    :CATEGORY: work
    :END:
    ** TODO Write Report :writing:urgent:
    :PROPERTIES:
    :Effort:   2:00
    :END:
    SCHEDULED: <2026-10-05 Mon 10:00>
    ** NEXT Call Bob :phone:
    DEADLINE: <2026-10-06 Tue>
    ** TODO Review PR :urgent:
    :PROPERTIES:
    :Effort:   1h
    :END:
    SCHEDULED: <2026-10-05 Mon>
    """

    static let filters = ["+urgent", "-urgent", "work", "-work", "+home+work", "<0:30", ">1:00", "=1:00", "/report/", "-/call/", "+work-phone<2:00", "nonexistent", "urgent-writing/review/"]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func filtersLikeOrgAgendaFilter() throws {
        let today = Days.absolute(year: 2026, month: 10, day: 5)
        let defaults = OrgSettings.default.withTodoKeywords(AgendaOracle.keywords)!
        let sources = [AgendaSource(path: "f.org", text: Self.file, defaults: defaults)]
        let days = Agenda.list(sources, start: today, days: 2, today: today, now: (9, 30), options: .terminal)
        let all = days.flatMap(\.items)
        let tags = Set(all.flatMap(\.tags))
        let categories = Set(all.filter { $0.path != nil }.map(\.category))
        for filterText in Self.filters {
            let emacs = try AgendaOracle.run(files: [("f.org", Self.file)], form: """
                (progn
                  (org-agenda-list nil "2026-10-05" 2)
                  (with-current-buffer org-agenda-buffer-name
                    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) \(lispString(filterText)))))
                      (org-agenda-filter))))
                """, today: today, hour: 9, minute: 30)
            let filter = AgendaFilter().parse(filterText, tags: tags, categories: categories).filter
            let ours = days.map { day in day.items.filter(filter.keeps) }
            #expect(ours.map { AgendaOracle.describe($0, today: today) } == emacs.map { AgendaOracle.describe($0.items) }, "\(filterText)")
        }
    }

    @Test func parsesAndDescribes() {
        let (filter, ignored) = AgendaFilter().parse("+work-phone<2:00/rep/ zzz", tags: ["phone"], categories: ["work"])
        #expect(filter.categories == ["+work"] && filter.tags == ["-phone"] && filter.efforts == ["+<2:00"] && filter.regexps == ["+rep"])
        #expect(ignored == ["+zzz"])
        #expect(filter.description == "+work-phone<2:00/rep/")
        #expect(AgendaFilter.durationMinutes("1h 30min") == 90 && AgendaFilter.durationMinutes("0:45") == 45)
        let kept = filter.parse("++urgent", tags: ["urgent"], categories: []).filter
        #expect(kept.tags == ["-phone", "+urgent"])
    }
}
