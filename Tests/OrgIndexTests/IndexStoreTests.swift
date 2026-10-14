import Foundation
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

    @Test func searchFindsTextBeforeTheFirstHeading() throws {
        let store = try IndexStore()
        try store.write(record("/notes/flat.org", "#+TITLE: Field notes\nThe heron came back to the pond.\n"))
        try store.write(record("/notes/b.org", "Preamble about otters.\n* Rivers\nwater\n"))
        let flat = try store.search("heron")
        #expect(flat.map(\.title) == ["Field notes"])
        #expect(flat.first?.ordinal == HeadingLocation.fileOrdinal && flat.first?.start == 0)
        #expect(try store.search("otters").map(\.path) == ["/notes/b.org"])
        #expect(try store.search("water").map(\.title) == ["Rivers"])
        // Rewritten and removed files take their preamble rows with them.
        try store.write(record("/notes/flat.org", "Nothing here.\n"))
        #expect(try store.search("heron").isEmpty)
        var change = IndexChange()
        change.removals = ["/notes/b.org"]
        try store.apply(change)
        #expect(try store.search("otters").isEmpty)
        // Unsaved text before the first heading is searched too.
        let overlay = ["/notes/flat.org": record("/notes/flat.org", "Kingfishers now.\n")]
        #expect(try store.search("kingfish", overlay: overlay).map(\.ordinal) == [HeadingLocation.fileOrdinal])
    }

    @Test func snippetsMarkTheMatches() throws {
        let store = try IndexStore()
        try store.write(record("/notes/a.org", "* Trip\nWe walked along the river bank and saw a heron fishing in the reeds near the old mill.\n"))
        let hit = try #require(try store.search("heron reed").first)
        let snippet = try #require(hit.snippet)
        let marked = snippet.matches.map { (snippet.text as NSString).substring(with: NSRange($0)) }
        #expect(marked == ["heron", "reeds"])
        #expect(snippet.text.contains("saw a heron fishing"))
        // A title-only match has no snippet.
        #expect(try store.search("trip").first?.snippet == nil)
    }

    @Test func snippetWindow() {
        let long = (1...80).map { "word\($0)" }.joined(separator: " ")
        let snippet = Snippet(text: long + "\nneedle\n" + long, prefixes: ["needle"])
        #expect(snippet != nil)
        #expect(snippet!.text.hasPrefix("…") && snippet!.text.hasSuffix("…"))
        #expect(snippet!.text.utf16.count < 200)
        #expect(!snippet!.text.contains("\n"))
        #expect(Snippet(text: "nothing", prefixes: ["zzz"]) == nil)
        #expect(Snippet(text: "Héron here", prefixes: ["heron"])?.matches.count == 1)
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
