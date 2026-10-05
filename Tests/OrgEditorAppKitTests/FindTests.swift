import AppKit
import OrgCore
import Testing
@testable import OrgEditorAppKit

@MainActor
struct FindTests {
    @Test func replaceShowsTheFindBar() {
        let h = Harness("* Heading\nbody\n")
        #expect(h.textView.enclosingScrollView?.isFindBarVisible != true)
        h.editor.run("edit.replace")
        #expect(h.textView.enclosingScrollView?.isFindBarVisible == true)
    }

    @Test func aMatchInFoldedTextUnfoldsIt() {
        let text = "* Heading\nhidden needle\n* Next\n"
        let h = Harness(text)
        h.caret(at: 0)
        h.editor.cycleAtCaret()
        #expect(!h.editor.foldState.folds.isEmpty)
        let needle = (text as NSString).range(of: "needle")
        h.textView.setSelectedRange(needle)
        #expect(h.editor.foldState.folds.isEmpty)
        #expect(h.textView.selectedRange() == needle)
    }
}
