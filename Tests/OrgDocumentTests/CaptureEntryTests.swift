import Foundation
import OrgCore
import Testing
@testable import OrgDocument

struct CaptureEntryTests {
    @Test func readsAndSetsTheFirstHeading() throws {
        var text = "* TODO Call the bank\nNotes here.\n"
        let calendar = Calendar(identifier: .gregorian)
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 9)))
        text = try #require(CaptureEntry.applying(SetPlanning(deadline: false), answers: ["date": "2026-10-12"], to: text, now: now))
        text = try #require(CaptureEntry.applying(SetPlanning(deadline: true), answers: ["date": "2026-10-14 15:00"], to: text, now: now))
        text = try #require(CaptureEntry.applying(SetTags(), answers: ["tags": "home:phone"], to: text, now: now))
        text = try #require(CaptureEntry.applying(SetPriority(value: "A"), answers: [:], to: text, now: now))
        text = try #require(CaptureEntry.applying(SetTodo(keyword: "DONE"), answers: [:], to: text, now: now))
        let entry = try #require(CaptureEntry(text: text))
        #expect(entry.todo == "DONE" && entry.priority == "A" && entry.tags == ["home", "phone"])
        #expect(entry.scheduled?.start.day == 12 && entry.deadline?.start.day == 14 && entry.deadline?.start.hour == 15)
        #expect(entry.keywords == ["TODO", "DONE"] && entry.priorities == ["A", "B", "C"])
        #expect(text.hasSuffix("Notes here.\n"))
        // Nothing to change, and no heading.
        #expect(CaptureEntry.applying(SetTodo(keyword: "DONE"), answers: [:], to: text, now: now) == nil)
        #expect(CaptureEntry(text: "Just a note\n") == nil)
    }
}
