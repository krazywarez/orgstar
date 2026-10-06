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

@MainActor
struct BodyFoldTests {
    /// CONTENTS view hides bodies (body folds); an edit elsewhere keeps them hidden.
    @Test func bodyFoldsSurviveEdits() {
        let h = Harness("* A\nbody a\n** B\nbody b\n* C\nbody c\n")
        h.editor.cycleGlobal()
        h.editor.cycleGlobal()
        #expect(!h.editor.foldState.bodyFolds.isEmpty)
        let hiddenBefore = h.editor.hidden.all
        #expect(!hiddenBefore.isEmpty)
        h.caret(at: 3)
        h.textView.insertText("x", replacementRange: NSRange(location: 3, length: 0))
        #expect(h.editor.hidden.all.count == hiddenBefore.count)
        #expect(h.editor.hidden.all.map { $0.count } == hiddenBefore.map { $0.count })
    }
}
