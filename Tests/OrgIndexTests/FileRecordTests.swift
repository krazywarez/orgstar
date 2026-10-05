import OrgCore
import Testing
@testable import OrgIndex

func record(_ path: String, _ text: String, kind: FileKind = .org, settings: IndexSettings = IndexSettings()) -> FileRecord {
    FileRecord(path: path, root: "/notes", kind: kind, bytes: Array(text.utf8), mtime: 1, settings: settings)
}

struct FileRecordTests {
    let text = """
    #+FILETAGS: :work:
    #+PROPERTY: OWNER team
    * TODO [#A] Plan the launch :big:
    SCHEDULED: <2026-10-05 Mon +1w -2d>
    :PROPERTIES:
    :ID: plan
    :CATEGORY: launch
    :END:
    Draft the [[https://example.com][brief]] and see [[id:other]].
    ** DONE Child
    CLOSED: [2026-10-04 Sun 09:00]
    :LOGBOOK:
    CLOCK: [2026-10-04 Sun 08:00]--[2026-10-04 Sun 09:00] =>  1:00
    :END:
    <2026-10-06 Tue>

    """

    @Test func headings() throws {
        let headings = record("/notes/a.org", text).headings
        #expect(headings.count == 2)
        let plan = headings[0]
        #expect(plan.todo == "TODO" && !plan.isDone && plan.priority == "A")
        #expect(plan.orgID == "plan")
        #expect(plan.outlinePath == ["Plan the launch"])
        #expect(plan.body.contains("Draft the"))
        #expect(!plan.body.contains("Child"))
        #expect(plan.tags == [TagRow(name: "work", inherited: true), TagRow(name: "big", inherited: false)])
        #expect(plan.links == [LinkRow(type: "https", target: "https://example.com"), LinkRow(type: "id", target: "id:other")])
        #expect(plan.timestamps == [TimestampRow(kind: .scheduled, start: "2026-10-05", end: nil, repeater: "+1w", warning: "-2d")])

        let child = headings[1]
        #expect(child.parent == 0 && child.isDone)
        #expect(child.outlinePath == ["Plan the launch", "Child"])
        #expect(child.tags.map(\.name) == ["work", "big"])
        #expect(child.clocks == [ClockRow(start: "2026-10-04T08:00", end: "2026-10-04T09:00", minutes: 60)])
        #expect(child.timestamps.map(\.kind) == [.closed, .active])
        #expect(child.properties == [PropertyRow(key: "CATEGORY", value: "launch", inherited: true)])
    }

    @Test func propertyInheritanceFollowsSettings() {
        let settings = IndexSettings(semantic: SemanticSettings(propertyInheritance: .all))
        let child = record("/notes/a.org", text, settings: settings).headings[1]
        #expect(child.properties.contains(PropertyRow(key: "OWNER", value: "team", inherited: true)))
    }

    @Test func archiveTag() {
        let headings = record("/notes/a.org", "* a :ARCHIVE:\n** b\n* c\n").headings
        #expect(headings.map(\.archived) == [true, true, false])
    }

    @Test func conflictCopiesHaveNoHeadings() {
        #expect(record("/notes/a.sync-conflict-1.org", "* a\n", kind: .conflict).headings.isEmpty)
    }
}
