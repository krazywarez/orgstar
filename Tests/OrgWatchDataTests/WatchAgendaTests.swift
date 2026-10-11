import Foundation
import Testing
@testable import OrgWatchData

struct WatchAgendaTests {
    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static func entry(_ id: String, start: Int? = nil, end: Int? = nil, todo: String? = "TODO", done: Bool = false, event: Bool = false) -> WatchAgenda.Entry {
        let midnight = utc.date(from: DateComponents(year: 2026, month: 10, day: 12))!
        func at(_ hhmm: Int?) -> Date? { hhmm.map { midnight.addingTimeInterval(Double(($0 / 100) * 3600 + ($0 % 100) * 60)) } }
        return WatchAgenda.Entry(
            id: id, title: id, gutter: start == nil ? "Scheduled" : "", category: "work", todo: todo, status: done ? "done" : "normal", isDone: done,
            isEvent: event, start: at(start), end: at(end), path: "/n/work.org", offset: 10, headingLine: "* \(todo ?? "") \(id)", doneKeyword: "DONE"
        )
    }

    static let agenda = WatchAgenda(
        generated: Date(timeIntervalSince1970: 0), day: utc.date(from: DateComponents(year: 2026, month: 10, day: 12))!,
        overdue: [entry("late")],
        rows: [entry("standup", start: 900, end: 915), entry("lunch", start: 1200, todo: nil, event: true), entry("review", start: 1530),
               entry("done", done: true), entry("plants")],
        clock: .init(heading: "Review", startedAt: Date(timeIntervalSince1970: 100)), lastClocked: "Review"
    )

    @Test func upcomingLeavesOutWhatsOver() {
        let ten = Self.utc.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 10))!
        #expect(Self.agenda.upcoming(at: ten, calendar: Self.utc).map(\.id) == ["lunch", "review", "plants", "late"])
        #expect(Self.agenda.next(at: ten, calendar: Self.utc)?.id == "lunch")
        #expect(Self.agenda.openCount(at: ten, calendar: Self.utc) == 4)
        let tomorrow = ten.addingTimeInterval(86400)
        #expect(Self.agenda.upcoming(at: tomorrow, calendar: Self.utc).isEmpty && Self.agenda.openCount(at: tomorrow, calendar: Self.utc) == 0)
    }

    @Test func markingDoneHere() {
        let marked = Self.agenda.markingDone("late")
        #expect(marked.overdue[0].isDone && marked.overdue[0].todo == "DONE" && !marked.overdue[0].canBeDone)
        #expect(Self.agenda.overdue[0].done == .done(path: "/n/work.org", offset: 10, headingLine: "* TODO late", keyword: "DONE"))
        #expect(Self.agenda.rows[1].done == nil)
    }

    @Test func roundTrips() throws {
        #expect(WatchAgenda.decode(try Self.agenda.data()) == Self.agenda)
        for action in [WatchAction.done(path: "/a.org", offset: 3, headingLine: "* TODO x", keyword: "DONE"), .clockOut, .clockInLast, .capture(text: "Buy milk")] {
            #expect(WatchAction(userInfo: action.userInfo) == action)
        }
        #expect(WatchAction(userInfo: [:]) == nil)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-watch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("watch.json")
        #expect(try Self.agenda.write(to: file) && !(try Self.agenda.write(to: file)))
        #expect(WatchAgenda.read(from: file) == Self.agenda)
    }
}
