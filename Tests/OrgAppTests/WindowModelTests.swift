import Foundation
import OrgDocument
import Testing
@testable import OrgApp

/// `WindowModel` lives in the app target; this is its contract over the session, checked with
/// the session alone: a split is a new pane showing the focused buffer; closing a pane leaves
/// its buffer open; the last pane stays.
@MainActor
struct WindowModelContractTests {
    @Test func aSplitShowsTheSameBufferInANewPane() throws {
        let notes = try Folder()
        let a = try notes.write("a.org", "* A\n").path
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(a)
        let pane = session.makePane()
        session.open(a, in: pane)
        #expect(pane.path == a && session.openPaths == [a])
        session.closePane(pane)
        #expect(session.panes.count == 1 && session.isOpen(a))
    }
}
