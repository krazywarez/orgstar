import Foundation
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp

@MainActor
struct VersionTests {
    func edit(_ session: DocumentSession, _ path: String, _ text: String) {
        let current = session.document!.text
        _ = session.perform(PrecomputedEdit(EditResult(baseRevision: session.document!.revision, edits: lineEdits(from: current, to: text))),
                            path: path, at: 0, expect: nil)
    }

    @Test func conflictsMergeWithMarkers() throws {
        let notes = try Folder()
        let file = try notes.write("a.org", "* A\nline one\nline two\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        edit(session, file.path, "* A\nline ONE mine\nline two\n")
        try notes.write("a.org", "* A\nline one disk\nline two\nadded on disk\n")
        #expect(!session.save())
        #expect(session.conflict != nil)
        let versions = try #require(session.conflictVersions())
        #expect(versions.base == "* A\nline one\nline two\n" && versions.disk.contains("added on disk"))
        session.mergeConflictWithMarkers()
        #expect(session.conflict == nil)
        #expect(session.document?.text == "* A\n<<<<<<< yours\nline ONE mine\n=======\nline one disk\n>>>>>>> disk\nline two\nadded on disk\n")
        #expect(session.save())
        #expect(try String(contentsOf: file, encoding: .utf8) == session.document?.text)
        // The buffer as it was is kept, and restoring it works as an edit.
        let kept = session.recoveryVersions()
        #expect(kept.contains { $0.label == "local" })
        let local = try #require(kept.first { session.recoveryText($0.url) == "* A\nline ONE mine\nline two\n" })
        #expect(session.restore(local.url) == nil)
        #expect(session.document?.text == "* A\nline ONE mine\nline two\n")
    }

    @Test func resolvesSyncthingCopies() throws {
        let notes = try Folder()
        let file = try notes.write("n.org", "* N\nshared\nmine\n")
        let first = try notes.write("n.sync-conflict-20261005-101010-ABCD123.org", "* N\nshared\ntheirs\n")
        try notes.write("n.sync-conflict-20261005-121212-ZZZZ999.org", "* N\ncopy two\n")
        try notes.write("other.sync-conflict-20261005-101010-ABCD123.org", "x\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        #expect(session.syncConflictCopies().map(\.lastPathComponent) == ["n.sync-conflict-20261005-101010-ABCD123.org", "n.sync-conflict-20261005-121212-ZZZZ999.org"])
        #expect(session.resolve(copy: first, .merge) == nil)
        #expect(session.document?.text == "* N\nshared\n<<<<<<< n.org\nmine\n=======\ntheirs\n>>>>>>> n.sync-conflict-20261005-101010-ABCD123.org\n")
        #expect(!FileManager.default.fileExists(atPath: first.path))
        let second = session.syncConflictCopies()[0]
        #expect(session.resolve(copy: second, .useCopy) == nil)
        #expect(session.document?.text == "* N\ncopy two\n")
        #expect(session.syncConflictCopies().isEmpty)
        #expect(session.recoveryVersions().filter { $0.label == "sync-conflict" }.count == 2)
    }
}
