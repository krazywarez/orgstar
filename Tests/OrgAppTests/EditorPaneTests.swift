import Foundation
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp

@MainActor
struct EditorPaneTests {
    func session(_ notes: Folder) -> DocumentSession {
        DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
    }

    @Test func aFileOpenInTwoPanesIsOneBuffer() throws {
        let notes = try Folder()
        let a = try notes.write("a.org", "* A\n").path
        let session = session(notes)
        let first = session.focused
        let second = session.makePane()
        session.open(a)
        session.open(a, in: second)
        #expect(session.openPaths == [a])
        #expect(first.path == a && second.path == a)
        #expect(session.panes.count == 2)
    }

    @Test func killingABufferEmptiesEveryPaneShowingIt() throws {
        let notes = try Folder()
        let a = try notes.write("a.org", "* A\n").path
        let b = try notes.write("b.org", "* B\n").path
        let session = session(notes)
        let first = session.focused
        let second = session.makePane()
        session.open(a)
        session.open(b)
        session.open(b, in: second)
        session.kill(b)
        #expect(first.path == a)
        #expect(second.path == a)
        #expect(first.shown == [a] && second.shown == [a])
        session.kill(a)
        #expect(first.path == nil && second.path == nil && session.path == nil)
    }

    @Test func revealGoesToOnePane() throws {
        let notes = try Folder()
        let a = try notes.write("a.org", "* A\n* B\n").path
        let session = session(notes)
        let first = session.focused
        let second = session.makePane()
        session.open(a)
        session.open(a, in: second)
        session.reveal(4, in: second)
        #expect(second.revealRequest?.offset == 4)
        #expect(first.revealRequest == nil)
        session.focused = second
        #expect(session.revealRequest?.offset == 4)
    }

    @Test func dirtyPathsCountABufferOnce() throws {
        let notes = try Folder()
        let a = try notes.write("a.org", "* A\n").path
        let session = session(notes)
        session.saveMode = .explicit
        let second = session.makePane()
        session.open(a)
        session.open(a, in: second)
        let result = EditResult(baseRevision: session.document!.revision, edits: [TextEdit(range: 0..<0, replacement: "x")])
        _ = session.perform(PrecomputedEdit(result), path: a, at: 0, expect: nil)
        #expect(session.dirtyPaths == [a])
        #expect(session.focused.isDirty && second.isDirty)
    }

    @Test func closingAPaneKeepsTheBufferAndTheFocus() throws {
        let notes = try Folder()
        let a = try notes.write("a.org", "* A\n").path
        let session = session(notes)
        let first = session.focused
        let second = session.makePane()
        session.open(a, in: second)
        session.focused = second
        session.closePane(second)
        #expect(session.panes.count == 1 && session.focused === first)
        #expect(session.isOpen(a))
        session.closePane(first)
        #expect(session.panes.count == 1)
    }
}
