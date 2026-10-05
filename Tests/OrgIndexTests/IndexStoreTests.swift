import OrgCore
import Testing
@testable import OrgIndex

struct IndexStoreTests {
    @Test func searchFindsTitlesAndBodies() throws {
        let store = try IndexStore()
        try store.write(record("/notes/a.org", "* Groceries\nbuy apples\n* Taxes\nfile forms\n"))
        #expect(try store.search("appl").map(\.title) == ["Groceries"])
        #expect(try store.search("tax").map(\.title) == ["Taxes"])
        #expect(try store.search("file forms").map(\.title) == ["Taxes"])
        #expect(try store.search("\"oops").isEmpty)
        #expect(try store.search("   ").isEmpty)
    }

    @Test func rewritingAFileReplacesItsRows() throws {
        let store = try IndexStore()
        try store.write(record("/notes/a.org", "* Old title\n"))
        try store.write(record("/notes/a.org", "* New title\n"))
        #expect(try store.search("old").isEmpty)
        #expect(try store.search("new").count == 1)
    }

    @Test func removeMoveAndTouch() throws {
        let store = try IndexStore()
        try store.write(record("/notes/a.org", "* Alpha\n"))
        try store.write(record("/notes/b.org", "* Beta\n"))
        var change = IndexChange()
        change.removals = ["/notes/a.org"]
        change.moves = [(from: "/notes/b.org", to: "/notes/c.org", mtime: 5)]
        try store.apply(change)
        #expect(try store.search("alpha").isEmpty)
        #expect(try store.search("beta").map(\.path) == ["/notes/c.org"])
        #expect(try store.fileStates(root: "/notes")["/notes/c.org"]?.mtime == 5)
    }

    @Test func overlayReplacesIndexedRows() throws {
        let store = try IndexStore()
        try store.write(record("/notes/a.org", "* Saved title\n"))
        let overlay = ["/notes/a.org": record("/notes/a.org", "* Unsaved title\n")]
        #expect(try store.search("saved", overlay: overlay).isEmpty)
        #expect(try store.search("unsaved", overlay: overlay).map(\.title) == ["Unsaved title"])
    }

    @Test func idsAndDuplicates() throws {
        let store = try IndexStore()
        try store.write(record("/notes/a.org", "* A\n:PROPERTIES:\n:ID: x\n:END:\n"))
        try store.write(record("/notes/b.org", "* B\n:PROPERTIES:\n:ID: y\n:END:\n"))
        #expect(try store.headings(withID: "x").map(\.path) == ["/notes/a.org"])
        #expect(try store.duplicateIDs().isEmpty)
        let overlay = ["/notes/b.org": record("/notes/b.org", "* B\n:PROPERTIES:\n:ID: x\n:END:\n")]
        #expect(try store.headings(withID: "x", overlay: overlay).map(\.path) == ["/notes/a.org", "/notes/b.org"])
        #expect(try store.duplicateIDs(overlay: overlay).keys.sorted() == ["x"])
    }

    @Test func fileStatesAndKinds() throws {
        let store = try IndexStore()
        let a = record("/notes/a.org", "* A\n")
        try store.write(a)
        try store.write(record("/notes/a.sync-conflict-1.org", "* A\n", kind: .conflict))
        let states = try store.fileStates(root: "/notes")
        #expect(states["/notes/a.org"] == FileState(kind: .org, size: a.size, mtime: 1, hash: a.hash, settingsVersion: 1))
        #expect(try store.files().map(\.kind) == [.org, .conflict])
        #expect(try store.search("a").map(\.path) == ["/notes/a.org"])
    }
}
