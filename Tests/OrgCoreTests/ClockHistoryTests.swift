import Foundation
import Testing
@testable import OrgCore

struct ClockResolutionTests {
    struct Case {
        var text: String
        var key: Character
        var minutes: Int?
        /// For `t`: when the user got distracted.
        var date: Int?
        /// Seconds after the clock-in (active) or the clock's start (dangling) that idling began.
        var idle: Int
        var active = true
        var clockingIn = false
    }

    static let t1 = 1_789_000_000   // Thu 2026-09-10 00:26:40
    static let now = t1 + 95 * 60 + 7
    static let task = "* TODO Task\nBody\n"
    static let logged = "* Task\n:LOGBOOK:\nCLOCK: [2026-09-09 Wed 09:00]--[2026-09-09 Wed 10:00] =>  1:00\n:END:\nNotes\n"
    static let dangling = "* Task\n:LOGBOOK:\nCLOCK: [2026-09-10 Thu 00:26]\nCLOCK: [2026-09-09 Wed 09:00]--[2026-09-09 Wed 10:00] =>  1:00\n:END:\n* Next\n"

    static let cases: [Case] = [
        Case(text: task, key: "k", minutes: 77, idle: 17 * 60 + 20),
        Case(text: task, key: "k", minutes: 5, idle: 17 * 60 + 20),
        Case(text: logged, key: "K", minutes: 5, idle: 17 * 60 + 20),
        Case(text: task, key: "K", minutes: 77, idle: 17 * 60 + 20),
        Case(text: task, key: "s", idle: 17 * 60 + 20),
        Case(text: logged, key: "S", idle: 17 * 60 + 20),
        Case(text: logged, key: "C", idle: 17 * 60 + 20),
        Case(text: task, key: "g", minutes: 10, idle: 17 * 60 + 20),
        Case(text: task, key: "G", minutes: 10, idle: 17 * 60 + 20),
        Case(text: task, key: "g", minutes: 0, idle: 17 * 60 + 20),
        Case(text: task, key: "s", idle: 30),
        Case(text: logged, key: "S", idle: 30),
        Case(text: task, key: "t", date: t1 + 40 * 60, idle: 17 * 60 + 20),
        Case(text: task, key: "T", date: t1 + 40 * 60, idle: 17 * 60 + 20),
        Case(text: task, key: "J", idle: 17 * 60 + 20),
        Case(text: task, key: "q", idle: 17 * 60 + 20),
        Case(text: dangling, key: "k", minutes: 95, idle: 0, active: false),
        Case(text: dangling, key: "k", minutes: 5, idle: 0, active: false),
        Case(text: dangling, key: "S", idle: 0, active: false),
        Case(text: dangling, key: "C", idle: 0, active: false),
        Case(text: dangling, key: "k", minutes: 95, idle: 0, active: false, clockingIn: true),
        Case(text: dangling, key: "g", minutes: 3, idle: 0, active: false, clockingIn: true),
    ]

    static func date(_ seconds: Int) -> Date { Date(timeIntervalSince1970: Double(seconds)) }

    /// Clocks in (active cases), then carries out the plan with the clock commands.
    func ours(_ c: Case) throws -> String {
        let clock = ClockTests()
        var text = c.text
        var start: String
        if c.active {
            text = clock.run(ClockIn(), text, caret: 2, at: Self.t1).text
            start = try #require(ClockIn.runningStart(in: text, near: 0))
        } else {
            start = try #require(ClockResolution.openClocks(in: text).first?.start)
        }
        let startDate = c.active ? Self.date(Self.t1) : try #require(ClockResolution.date(of: start, calendar: ClockTests.utc))
        let lastValid = startDate.addingTimeInterval(Double(c.idle))
        let minutes = c.date.map { ClockResolution.minutes(from: lastValid, to: Self.date($0)) } ?? c.minutes
        let plan = try ClockResolution.plan(
            key: c.key, minutes: minutes, start: startDate, lastValid: lastValid, now: Self.date(Self.now), active: c.active, clockingIn: c.clockingIn
        )
        let heading = try #require(ClockTask.at(0, in: text, path: "x"))
        for step in plan.steps {
            switch step {
            case .cancel:
                text = clock.run(ClockOut(start: start, cancel: true), text, caret: 0, at: Self.now).text
            case .clockOut(let at):
                text = clock.run(ClockOut(start: start), text, caret: 0, at: Int(at.timeIntervalSince1970)).text
            case .clockIn(let at):
                let offset = try #require(heading.locate(in: text))
                text = clock.run(ClockIn(), text, caret: offset, at: Int(at.timeIntervalSince1970)).text
                start = try #require(ClockIn.runningStart(in: text, near: offset))
            case .resume:
                break
            }
        }
        return text
    }

    func form(_ c: Case) -> String {
        let reads = """
            ((symbol-function 'read-char-exclusive) (lambda (&rest _) ?\(c.key)))
            ((symbol-function 'read-number) (lambda (&rest _) \(c.minutes ?? 0)))
            ((symbol-function 'org-read-date) (lambda (&rest _) (seconds-to-time \(c.date ?? 0))))
            """
        let find = c.active ? "(cons org-clock-marker org-clock-start-time)" : """
            (save-excursion
              (goto-char (point-min))
              (re-search-forward "CLOCK: \\\\(\\\\[.*?\\\\]\\\\)$")
              (cons (copy-marker (match-end 1) t) (org-time-string-to-time (match-string 1))))
            """
        let resolve = """
            (cl-letf (\(reads))
              (let* ((clock \(find))
                     (org-clock-resolving-clocks-due-to-idleness t)
                     (org-clock-clocking-in \(c.clockingIn ? "t" : "nil")))
                (org-clock-resolve clock (lambda (_) "Idle") (time-add (cdr clock) \(c.idle)))))
            """
        return """
            (progn
              (require 'org-clock)
              (setq org-clock-persist nil org-clock-idle-time nil org-clock-auto-clock-resolution nil org-clock-into-drawer t
                    org-clock-leftover-time nil)
              \(c.active ? frozenClock(Self.t1, "(org-clock-in)") : "")
              \(frozenClock(Self.now, resolve)))
            """
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func matchesEmacs() throws {
        let mine = try Self.cases.map(ours)
        let emacs = try EmacsOracle.run(Self.cases.map { EmacsOracle.Case(text: $0.text, point: 3, form: form($0)) })
        for (i, (ours, theirs)) in zip(mine, emacs).enumerated() {
            let c = Self.cases[i]
            #expect(ours == theirs.text, "case \(i) \(c.key) \(c.minutes.map(String.init) ?? "")\nours:  \(ours.debugDescription)\nemacs: \(theirs.text.debugDescription) \(theirs.error)")
        }
    }

    @Test func plans() throws {
        let start = Self.date(Self.t1)
        let idle = start.addingTimeInterval(600)
        let now = start.addingTimeInterval(3600)
        func plan(_ key: Character, _ minutes: Int? = nil, active: Bool = true) throws -> ClockResolution.Plan {
            try ClockResolution.plan(key: key, minutes: minutes, start: start, lastValid: idle, now: now, active: active, clockingIn: false)
        }
        #expect(try plan("k", 50).steps.isEmpty)
        #expect(try plan("k", 50, active: false).steps == [.resume])
        #expect(try plan("K", 5) == .init(steps: [.clockOut(idle.addingTimeInterval(300))], leftover: idle.addingTimeInterval(300), setsLeftover: true))
        #expect(try plan("S") == .init(steps: [.clockOut(idle)], leftover: idle, setsLeftover: true))
        #expect(try plan("G", 5) == .init(steps: [.clockOut(idle)], leftover: nil, setsLeftover: true))
        #expect(try plan("j") == .init(jump: true))
        #expect(throws: ClockResolution.Failure.self) { try plan("k", 70) }
        #expect(ClockResolution.defaultMinutes(lastValid: idle, now: now.addingTimeInterval(59)) == 50)
    }
}

struct ClockHistoryTests {
    static let text = "* A\n:PROPERTIES:\n:CATEGORY: work\n:END:\n** TODO [#B] Child :tag:\n* B\n:PROPERTIES:\n:ID: b1\n:END:\n* A\n"

    static func offset(_ needle: String, _ text: String = text, last: Bool = false) -> Int {
        (text as NSString).range(of: needle, options: last ? .backwards : []).location
    }

    @Test func pushKeepsTheNewestFirstWithoutDuplicates() {
        let files = ["f.org": Self.text, "g.org": "* G\n"]
        let read = { (path: String) in files[path] }
        let a = ClockTask.at(0, in: Self.text, path: "f.org")!
        let child = ClockTask.at(Self.offset("** TODO"), in: Self.text, path: "f.org")!
        let b = ClockTask.at(Self.offset("* B"), in: Self.text, path: "f.org")!
        let g = ClockTask.at(0, in: "* G\n", path: "g.org")!
        let lastA = ClockTask.at(Self.offset("* A", last: true), in: Self.text, path: "f.org")!
        #expect(child.title == "Child" && b.id == "b1" && lastA.ordinal == 3)
        var history: [ClockTask] = []
        for task in [a, child, b, a, g] { history = ClockHistory.push(task, onto: history, length: 3, text: read) }
        #expect(history == [g, a, b])
        // The second heading titled A is another entry.
        history = ClockHistory.push(lastA, onto: history, length: 5, text: read)
        #expect(history == [lastA, g, a, b])
        // A file that is gone takes its entries along.
        #expect(ClockHistory.push(a, onto: history, length: 5, text: { $0 == "g.org" ? nil : files[$0] }) == [a, lastA, b])
    }

    @Test func tasksAreFoundAfterEdits() {
        let b = ClockTask.at(Self.offset("* B"), in: Self.text, path: "f.org")!
        let a = ClockTask.at(0, in: Self.text, path: "f.org")!
        let moved = "* New\n" + Self.text.replacingOccurrences(of: "* B\n", with: "* B renamed\n")
        #expect(b.locate(in: moved) == Self.offset("* B renamed", moved))
        #expect(a.locate(in: moved) == 6)
        #expect(a.locate(in: "* Other\n") == nil)
    }

    @Test func selectionKeysAndLines() throws {
        let read = { (_: String) in Self.text }
        let tasks = [0, Self.offset("** TODO"), Self.offset("* B"), Self.offset("* A", last: true)].map { ClockTask.at($0, in: Self.text, path: "/n/f.org")! }
        let choices = try #require(ClockHistory.selection(defaultTask: tasks[2], interrupted: nil, current: tasks[1], history: [tasks[1], tasks[1], tasks[0], tasks[3]], text: read))
        #expect(choices.map(\.key) == ["d", "c", "1", "2", "3"])
        #expect(choices[1].line == "work" + String(repeating: " ", count: 10) + "TODO [#B] Child")
        #expect(choices[0].line == "f" + String(repeating: " ", count: 13) + "B")
        #expect(choices.map(\.section) == ["Default Task", "Current Clocking Task", "Recent Tasks", "Recent Tasks", "Recent Tasks"])
        #expect(ClockHistory.selection(defaultTask: tasks[0], interrupted: nil, current: nil, history: [], text: read) == nil)
        let many = (0..<12).map { ClockTask(path: "/n/f.org", title: "A", ordinal: 0, id: "\($0)") }
        let keys = ClockHistory.selection(defaultTask: nil, interrupted: nil, current: nil, history: many, text: read)!.map(\.key)
        #expect(String(keys) == "123456789ABC")
    }
}
