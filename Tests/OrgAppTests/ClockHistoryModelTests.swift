import Foundation
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp

/// Answers prompts in order and remembers what they asked.
@MainActor
final class ScriptedAnswers {
    var answers: [String?]
    var asked: [String] = []
    init(_ answers: [String?]) { self.answers = answers }
    var ask: ClockModel.Ask {
        { prompt in
            self.asked.append(prompt.message)
            return self.answers.isEmpty ? nil : self.answers.removeFirst()
        }
    }
}

@MainActor
struct ClockHistoryModelTests {
    let notes: Folder
    let work: URL
    let session: DocumentSession
    let stateFile: URL
    let defaults: UserDefaults
    let start = Date(timeIntervalSince1970: 1_789_000_000)

    init() throws {
        notes = try Folder()
        work = try notes.write("work.org", "* A\n* B\n:PROPERTIES:\n:ID: b1\n:END:\n* C\n")
        session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(work.path)
        stateFile = notes.url.appendingPathComponent("clock.json")
        defaults = UserDefaults(suiteName: "orgstar-clock-\(UUID().uuidString)")!
    }

    func offset(_ heading: String) -> Int {
        (session.document!.text as NSString).range(of: heading).location
    }

    @Test func historyIsKeptAndPersisted() throws {
        let clock = ClockModel(file: stateFile, defaults: defaults)
        for (i, heading) in ["* A", "* B", "* A", "* C"].enumerated() {
            _ = clock.clockIn(session, path: work.path, at: offset(heading), now: start.addingTimeInterval(Double(i * 600)))
        }
        #expect(clock.history.map(\.title) == ["C", "A", "B"])
        #expect(clock.interruptedTask?.title == "A")
        let reloaded = ClockModel(file: stateFile, defaults: defaults)
        #expect(reloaded.history == clock.history && reloaded.running == clock.running)

        // Headings move and are renamed: entries are found by ID, else position and title.
        session.reveal(0)
        _ = session.perform(PrecomputedEdit(EditResult(baseRevision: session.document!.revision, edits: [TextEdit(range: 0..<0, replacement: "* New\n")])), path: work.path, at: 0, expect: nil)
        #expect(clock.locate(clock.history[2], session)?.offset == offset("* B"))

        defaults.set(2, forKey: "clockHistoryLength")
        _ = clock.clockIn(session, path: work.path, at: offset("* B"), now: start.addingTimeInterval(3000))
        #expect(clock.history.map(\.title) == ["B", "C"])
    }

    @Test func oldClockFilesStillLoad() throws {
        let running = ClockModel.Running(path: work.path, start: "2026-09-10 Thu 00:26", heading: "A", startedAt: start)
        try JSONEncoder().encode(running).write(to: stateFile)
        let clock = ClockModel(file: stateFile, defaults: defaults)
        #expect(clock.running == running && clock.history.isEmpty)
    }

    @Test func selectingRecentEntries() async throws {
        let clock = ClockModel(file: stateFile, defaults: defaults)
        let none = await clock.clockIn(session, target: .select, paths: [], ask: ScriptedAnswers([]).ask)
        #expect(none.messages == ["No recent clock"])
        _ = clock.clockIn(session, path: work.path, at: offset("* A"), now: start)
        _ = clock.clockIn(session, path: work.path, at: offset("* B"), now: start.addingTimeInterval(600))
        _ = clock.markDefault(session, path: work.path, at: offset("* C"))
        let choices = try #require(clock.selection(session))
        #expect(choices.map(\.key) == ["d", "i", "c", "1", "2"])
        #expect(choices.map(\.task.title) == ["C", "A", "B", "B", "A"])

        let answers = ScriptedAnswers(["2"])
        let outcome = await clock.clockIn(session, target: .select, paths: [work.path], ask: answers.ask, now: { start.addingTimeInterval(1200) })
        #expect(answers.asked == ["Clock-in on task: "])
        #expect(clock.running?.heading == "A" && outcome.messages.last?.hasPrefix("Clock starts at") == true)
        let same = await clock.clockIn(session, target: .last, paths: [], ask: ScriptedAnswers([]).ask)
        #expect(same.messages == ["Clock continues in \"A\""])
        let aborted = await clock.clockIn(session, target: .select, paths: [], ask: ScriptedAnswers(["q"]).ask)
        #expect(aborted.messages == ["Abort"])

        _ = clock.clockOut(session, now: start.addingTimeInterval(1800))
        let goto = clock.goto(session)
        #expect(goto.location?.offset == offset("* A") && goto.message == "No running clock, this is the most recently clocked task")
        let recent = await clock.gotoRecent(session, ask: ScriptedAnswers(["2"]).ask)
        #expect(recent.location?.offset == offset("* B"))
    }

    @Test func danglingClocksAreResolvedBeforeClockingIn() async throws {
        let other = try notes.write("other.org", "* Old\n:LOGBOOK:\nCLOCK: [2026-09-09 Wed 09:00]\n:END:\n")
        let clock = ClockModel(file: stateFile, defaults: defaults)
        let opened = clock.openClocks(session, paths: [other.path])
        #expect(opened.map(\.heading) == ["Old"])
        let answers = ScriptedAnswers(["x", "K", "30"])
        let outcome = await clock.clockIn(session, target: .caret, paths: [other.path], ask: answers.ask, now: { opened[0].startedAt.addingTimeInterval(7200) })
        #expect(answers.asked.first == "Dangling clock started 120 mins ago" + ClockResolution.keyHint)
        #expect(answers.asked.count == 3 && answers.asked[2] == "Keep how many minutes (default 120): ")
        #expect(outcome.messages.count == 2)
        #expect(clock.running?.heading == "A")
        let text = try #require(ClockModel.text(other.path, session))
        #expect(text.contains("CLOCK: [2026-09-09 Wed 09:00]--[2026-09-09 Wed 09:30] =>  0:30"), "\(text)")
        // Resolving before a clock-in never leaves time over.
        #expect(clock.leftover == nil)
    }

    /// `org-agenda-clock-in` runs `org-clock-in` at the entry, so it resolves first too, and
    /// finds the entry after resolving moved it.
    @Test func clockingInAtAnEntryResolvesDanglingClocks() async throws {
        let other = try notes.write("other.org", "* Old\n:LOGBOOK:\nCLOCK: [2026-09-09 Wed 09:00]\n:END:\n* New\n")
        let clock = ClockModel(file: stateFile, defaults: defaults)
        let started = clock.openClocks(session, paths: [other.path])[0].startedAt
        let text = try #require(ClockModel.text(other.path, session))
        let entry = (text as NSString).range(of: "* New").location
        let answers = ScriptedAnswers(["K", "30"])
        let outcome = await clock.clockIn(
            session, target: .entry(path: other.path, offset: entry), paths: [other.path], ask: answers.ask, now: { started.addingTimeInterval(7200) }
        )
        #expect(answers.asked.first == "Dangling clock started 120 mins ago" + ClockResolution.keyHint)
        #expect(clock.running?.heading == "New" && outcome.messages.last == "Clock starts at [2026-09-09 Wed 11:00]")
        let updated = try #require(ClockModel.text(other.path, session))
        #expect(
            updated == "* Old\n:LOGBOOK:\nCLOCK: [2026-09-09 Wed 09:00]--[2026-09-09 Wed 09:30] =>  0:30\n:END:\n* New\n:LOGBOOK:\nCLOCK: [2026-09-09 Wed 11:00]\n:END:\n",
            "\(updated)"
        )
    }

    /// A template's `clock-in` is `org-clock-in` when capture began: dangling clocks are
    /// resolved as of then, and the entry is clocked out when it is filed.
    @Test func captureClockInResolvesDanglingClocks() async throws {
        let other = try notes.write("other.org", "* Old\n:LOGBOOK:\nCLOCK: [2026-09-09 Wed 09:00]\n:END:\n")
        let clock = ClockModel(file: stateFile, defaults: defaults)
        let opened = clock.openClocks(session, paths: [other.path])[0].startedAt.addingTimeInterval(7200)
        let answers = ScriptedAnswers(["K", "30"])
        let outcome = await clock.captured(
            (work.path, offset("* C")), options: .init(clockIn: true), session: session, paths: [other.path], ask: answers.ask,
            opened: opened, now: opened.addingTimeInterval(600)
        )
        #expect(answers.asked.first == "Dangling clock started 120 mins ago" + ClockResolution.keyHint)
        #expect(outcome.messages.suffix(2) == ["Clock starts at [2026-09-09 Wed 11:00]", "Clock stopped after 0:10"])
        #expect(clock.running == nil && clock.history.first?.title == "C")
        #expect(try #require(ClockModel.text(other.path, session)).contains("=>  0:30"))
    }

    /// With a clock running the capture clock-in resolves nothing; the `clock-resume` clock-in,
    /// with no clock running, does, as in Org.
    @Test func captureClockInResumesTheInterruptedClock() async throws {
        let other = try notes.write("other.org", "* Old\n:LOGBOOK:\nCLOCK: [2026-09-09 Wed 09:00]\n:END:\n")
        let clock = ClockModel(file: stateFile, defaults: defaults)
        _ = clock.clockIn(session, path: work.path, at: offset("* A"), now: start)
        let answers = ScriptedAnswers([])
        let outcome = await clock.captured(
            (work.path, offset("* C")), options: .init(clockIn: true, clockResume: true), session: session, paths: [other.path],
            ask: answers.ask, opened: start.addingTimeInterval(600), now: start.addingTimeInterval(900)
        )
        #expect(answers.asked.count == 1 && answers.asked[0].hasPrefix("Dangling clock started"))
        #expect(outcome.messages.count == 3 && clock.running?.heading == "A")
    }

    @Test func jumpingFromADanglingClockShowsItAfterClockingIn() async throws {
        let other = try notes.write("other.org", "* Old\n:LOGBOOK:\nCLOCK: [2026-09-09 Wed 09:00]\n:END:\n")
        let clock = ClockModel(file: stateFile, defaults: defaults)
        let started = clock.openClocks(session, paths: [other.path])[0].startedAt
        // `c` isn't a key org-clock-resolve reads; `J` clocks out and jumps.
        let answers = ScriptedAnswers(["c", "J"])
        let outcome = await clock.clockIn(session, target: .caret, paths: [other.path], ask: answers.ask, now: { started.addingTimeInterval(600) })
        #expect(answers.asked.count == 2)
        #expect(outcome.jump?.path == other.path)
        #expect(clock.running?.heading == "A")
    }

    @Test func idleTimeIsSubtractedAndOfferedToTheNextClock() async throws {
        let clock = ClockModel(file: stateFile, defaults: defaults)
        _ = clock.clockIn(session, path: work.path, at: offset("* A"), now: start)
        let idle = start.addingTimeInterval(20 * 60)
        let answers = ScriptedAnswers(["S"])
        _ = await clock.resolveIdle(session, idleSince: idle, ask: answers.ask, now: { idle.addingTimeInterval(45 * 60) })
        #expect(answers.asked == ["Clocked in & idle for 45.0 mins" + ClockResolution.keyHint])
        #expect(clock.running == nil && clock.leftover == idle)
        #expect(session.document!.text.contains("=>  0:20"))

        let next = ScriptedAnswers(["y"])
        let c = try #require(ClockTask.at(offset("* C"), in: session.document!.text, path: work.path))
        _ = await clock.clockIn(session, target: .task(c), paths: [], ask: next.ask, now: { idle.addingTimeInterval(50 * 60) })
        #expect(next.asked == ["You stopped another clock 50 mins ago; start this one from then? (y or n) "])
        #expect(clock.running?.heading == "C" && clock.running?.startedAt == idle && clock.leftover == nil)
    }
}
