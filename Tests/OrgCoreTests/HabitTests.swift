import Foundation
import Testing
@testable import OrgCore

struct HabitTests {
    static let habits = """
    * TODO Exercise
    SCHEDULED: <2026-10-05 Mon .+1d>
    :PROPERTIES:
    :STYLE:    habit
    :END:
    :LOGBOOK:
    - State "DONE"       from "TODO"       [2026-10-04 Sun 08:00]
    - State "DONE"       from "TODO"       [2026-10-02 Fri 08:10]
    - State "DONE"       from "TODO"       [2026-09-28 Mon 07:00]
    - State "DONE"       from "TODO"       [2026-09-10 Thu 07:00]
    :END:
    * TODO Water plants
    SCHEDULED: <2026-10-01 Thu .+2d/4d>
    :PROPERTIES:
    :STYLE:    habit
    :END:
    - State "DONE"       from "TODO"       [2026-09-29 Tue 18:00]
    - State "DONE"       from "TODO"       [2026-09-24 Thu 18:00]
    - State "KILL"       from "TODO"       [2026-09-20 Sun 18:00]
    * TODO Weekly review
    SCHEDULED: <2026-10-08 Thu +1w>
    :PROPERTIES:
    :STYLE:    habit
    :END:
    :LOGBOOK:
    - State "DONE"       from "TODO"       [2026-10-01 Thu 17:00]
    - State "DONE"       from "TODO"       [2026-09-24 Thu 17:00]
    - State "DONE"       from "TODO"       [2026-09-16 Wed 17:00]
    :END:
    * TODO Stretch
    SCHEDULED: <2026-10-02 Fri 07:30 ++1d>
    :PROPERTIES:
    :STYLE:    habit
    :END:
    :LOGBOOK:
    - State "DONE"       from "TODO"       [2026-10-01 Thu 07:40]
    - State "DONE"       from "TODO"       [2026-09-29 Tue 07:35]
    :END:
    * TODO Read
    SCHEDULED: <2026-10-03 Sat ++3d/5d>
    :PROPERTIES:
    :STYLE:    habit
    :END:
    - CLOSING NOTE [2026-09-30 Wed 21:00] \\\\
      finished a chapter
    * TODO New habit
    SCHEDULED: <2026-10-06 Tue .+1d>
    :PROPERTIES:
    :STYLE:    habit
    :END:
    * DONE Done habit
    SCHEDULED: <2026-10-05 Mon .+1d>
    :PROPERTIES:
    :STYLE:    habit
    :END:
    * TODO Plain task
    SCHEDULED: <2026-10-05 Mon>
    * TODO Late task
    SCHEDULED: <2026-10-03 Sat>
    """

    static let broken = """
    * TODO No repeat
    SCHEDULED: <2026-10-05 Mon>
    :PROPERTIES:
    :STYLE:    habit
    :END:
    * TODO Short deadline
    SCHEDULED: <2026-10-05 Mon .+3d/2d>
    :PROPERTIES:
    :STYLE:    habit
    :END:
    """

    struct Graph: Codable, Equatable {
        var pos: Int
        var parse: String?
        var glyphs: String?
        var faces: [String]?
    }

    /// `org-habit-parse-todo` and `org-habit-build-graph` for each heading, as Emacs gives them.
    static func emacs(_ text: String, today: Int) throws -> [Graph] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-habit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("h.org")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let output = folder.appendingPathComponent("out.json")
        let script = folder.appendingPathComponent("habit.el")
        let words = AgendaOracle.keywords.split(separator: " ").map { "\"\($0)\"" }.joined(separator: " ")
        try #"""
        ;;; -*- lexical-binding: t -*-
        (require 'org)
        (require 'org-habit)
        (require 'json)
        (setq org-todo-keywords '((sequence \#(words))))
        \#(frozenClock((today - 719163) * 86400 + 9 * 3600, """
          (with-current-buffer (find-file-noselect "\(file.path)")
            (let (result (moment (current-time)))
              (org-map-entries
               (lambda ()
                 (let* ((habit (condition-case nil (org-habit-parse-todo) (error nil)))
                        (graph (and habit (org-habit-build-graph habit
                                                                 (time-subtract moment (days-to-time org-habit-preceding-days))
                                                                 moment
                                                                 (time-add moment (days-to-time org-habit-following-days))))))
                   (push `((pos . ,(point))
                           (parse . ,(and habit (prin1-to-string habit)))
                           (glyphs . ,graph)
                           (faces . ,(and graph (vconcat (mapcar (lambda (i) (symbol-name (get-text-property i 'face graph)))
                                                                 (number-sequence 0 (- (length graph) 2)))))))
                         result))))
              (let ((coding-system-for-write 'utf-8-unix))
                (with-temp-file (getenv "ORACLE_OUTPUT")
                  (insert (json-encode (vconcat (nreverse result))))))))
        """))
        """#.write(to: script, atomically: true, encoding: .utf8)
        let log = try EmacsOracle.run(["-Q", "--batch", "-l", script.path], environment: ["ORACLE_OUTPUT": output.path, "TZ": "UTC"])
        guard let data = try? Data(contentsOf: output) else { throw AgendaOracle.OracleError(log: log) }
        return try JSONDecoder().decode([Graph].self, from: data).map { graph in
            var graph = graph
            graph.pos = EmacsOracle.offset(graph.pos, in: text)
            return graph
        }
    }

    static func ours(_ text: String, today: Int) -> [Graph] {
        let defaults = OrgSettings.default.withTodoKeywords(AgendaOracle.keywords)!
        let source = AgendaSource(path: "h.org", text: text, defaults: defaults)
        return source.headings.map { heading in
            guard let habit = heading.habit else { return Graph(pos: heading.start) }
            let deadline = habit.deadlineDay.map(String.init) ?? "nil"
            let repeat_ = habit.deadlineRepeatDays.map(String.init) ?? "nil"
            let done = habit.doneDates.isEmpty ? "nil" : "(" + habit.doneDates.map(String.init).joined(separator: " ") + ")"
            let parse = "(\(habit.scheduled) \(habit.scheduledRepeat) \(deadline) \(repeat_) \(done) \"\(habit.repeatType)\")"
            let cells = habit.graph(today: today)
            let faces = cells.map { cell -> String in
                let base = cell.face.rawValue.replacingOccurrences(of: "Future", with: "")
                return "org-habit-\(base)-" + (cell.face.rawValue.hasSuffix("Future") ? "future-face" : "face")
            }
            return Graph(pos: heading.start, parse: parse, glyphs: String(cells.map(\.glyph)) + " ", faces: faces)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func graphsMatchEmacs() throws {
        for (y, m, d) in [(2026, 10, 5), (2026, 10, 1), (2026, 10, 12), (2026, 9, 20)] {
            let today = Days.absolute(year: y, month: m, day: d)
            for text in [Self.habits, Self.broken] {
                #expect(Self.ours(text, today: today) == (try Self.emacs(text, today: today)), "\(y)-\(m)-\(d)")
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func agendaMatchesEmacs() throws {
        let files = [("habits.org", Self.habits)]
        for (y, m, d) in [(2026, 10, 5), (2026, 10, 3), (2026, 10, 9)] {
            let today = Days.absolute(year: y, month: m, day: d)
            try AgendaOracle.compare(files: files, start: today - 1, span: 3, today: today)
        }
    }

    @Test func urgency() {
        let habit = Habit.parse(entry: "", scheduled: "2026-10-01 Thu .+2d/4d", doneKeywords: ["DONE"])!
        let oct1 = Days.absolute(year: 2026, month: 10, day: 1)
        #expect(habit.deadline == oct1 + 2)
        #expect(habit.urgency(today: oct1) == 1000 - 10)
        #expect(habit.urgency(today: oct1 + 2) == 1000 + 20 + 50 + 100)
        #expect(habit.urgency(today: oct1 + 4) == 1000 + 40 + 300)
    }
}
