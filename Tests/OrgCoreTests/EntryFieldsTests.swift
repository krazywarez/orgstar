import Foundation
import Testing
@testable import OrgCore

struct EntryFieldsTests {
    static let text = """
        * TODO [#A] Call bank :work:home:
        SCHEDULED: <2026-10-17 Sat 18:00> DEADLINE: <2026-10-20 Tue>
        :PROPERTIES:
        :ID: x
        :END:
        :LOGBOOK:
        CLOCK: [2026-10-16 Fri 09:00]--[2026-10-16 Fri 09:30] =>  0:30
        :END:
        Line one
        Line two

        ** Child
        child body

        """

    @Test func readsTheHeadingPlanningAndNotes() throws {
        let fields = try #require(EntryFields.read(Self.text, at: 0, settings: .default))
        #expect(fields.todo == "TODO")
        #expect(fields.priority == "A")
        #expect(fields.title == "Call bank")
        #expect(fields.tags == ["work", "home"])
        #expect(fields.scheduled == "2026-10-17 Sat 18:00")
        #expect(fields.deadline == "2026-10-20 Tue")
        #expect(fields.notes == "Line one\nLine two")
    }

    @Test func readsAPlainHeading() throws {
        let fields = try #require(EntryFields.read("* Just a title\n", at: 0, settings: .default))
        #expect(fields == EntryFields(todo: nil, priority: nil, title: "Just a title", tags: [], scheduled: nil, deadline: nil, notes: ""))
        #expect(EntryFields.read("no heading\n", at: 0, settings: .default) == nil)
    }

    @Test func setsTheTitleKeepingKeywordCookieAndTags() {
        let result = runCommand(SetHeadingTitle(title: "Call the bank"), Self.text, caret: 0)
        #expect(result.failure == nil)
        let line = result.text.prefix { $0 != "\n" }
        #expect(line.hasPrefix("* TODO [#A] Call the bank "))
        #expect(line.hasSuffix(" :work:home:"))
        #expect(runCommand(SetHeadingTitle(title: "Named"), "* TODO\nbody\n", caret: 0).text == "* TODO Named\nbody\n")
        #expect(runCommand(SetHeadingTitle(title: "  Trimmed "), "* Old\n", caret: 0).text == "* Trimmed\n")
        #expect(runCommand(SetHeadingTitle(title: "Two\nlines\n"), "* Old\n", caret: 0).text == "* Two lines\n")
    }

    @Test func replacesNotesKeepingMetaDataAndChildren() {
        let result = runCommand(SetEntryNotes(notes: "New note\n\n"), Self.text, caret: 0)
        #expect(result.failure == nil)
        #expect(result.text == Self.text.replacingOccurrences(of: "Line one\nLine two\n", with: "New note\n"))
        let cleared = runCommand(SetEntryNotes(notes: ""), Self.text, caret: 0).text
        #expect(cleared == Self.text.replacingOccurrences(of: "Line one\nLine two\n", with: ""))
    }

    @Test func addsNotesWhereThereWereNone() {
        #expect(runCommand(SetEntryNotes(notes: "Body"), "* A\n* B\n", caret: 0).text == "* A\nBody\n* B\n")
        #expect(runCommand(SetEntryNotes(notes: "Body"), "* A", caret: 0).text == "* A\nBody\n")
        #expect(runCommand(SetEntryNotes(notes: "Body"), "* A\nSCHEDULED: <2026-10-17 Sat>\n", caret: 0).text == "* A\nSCHEDULED: <2026-10-17 Sat>\nBody\n")
    }
}

struct ReplaceChangedTextTests {
    @Test func writesTheDifferenceAsOneEdit() throws {
        let old = "* TODO Call bank\nbody\n* Next\n"
        let new = "* DONE Call bank\nbody\nmore\n* Next\n"
        let command = try #require(ReplaceChangedText(from: old, to: new))
        #expect(command.edit.range == 2..<21)
        #expect(runCommand(command, old, caret: 0).text == new)
        #expect(ReplaceChangedText(from: old, to: old) == nil)
    }

    @Test func refusesTextThatChangedSince() throws {
        let command = try #require(ReplaceChangedText(from: "* TODO A\n", to: "* DONE A\n"))
        #expect(runCommand(command, "* WAIT A\n", caret: 0).failure != nil)
    }

    @Test func keepsSurrogatePairsWhole() throws {
        let command = try #require(ReplaceChangedText(from: "* 😀\n", to: "* 😃\n"))
        #expect(runCommand(command, "* 😀\n", caret: 0).text == "* 😃\n")
    }
}
