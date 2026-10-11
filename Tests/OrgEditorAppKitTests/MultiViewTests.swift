import AppKit
import OrgCore
import OrgDocument
import OrgPresentation
import Testing
@testable import OrgEditorAppKit

/// One editor, several text views on its storage: text, undo, folds and narrowing are the
/// editor's; the caret and the focus are each view's.
@MainActor
struct MultiViewTests {
    @MainActor struct Two {
        let editor: OrgEditor
        let second: NSTextView
        let windows: [NSWindow]

        init(_ text: String) {
            _ = NSApplication.shared
            let editor = OrgEditor(document: DocumentState(bytes: Array(text.utf8)))
            let second = editor.addView()
            let windows = [editor.textView, second].map { view in
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = editor.makeScrollView(for: view)
                return window
            }
            windows[0].makeFirstResponder(editor.textView)
            editor.finishStyling()
            for view in editor.textViews { view.textLayoutManager!.ensureLayout(for: view.textLayoutManager!.documentRange) }
            self.editor = editor
            self.second = second
            self.windows = windows
        }

        func lines(_ view: NSTextView) -> Int {
            let layout = view.textLayoutManager!
            layout.ensureLayout(for: layout.documentRange)
            var count = 0
            layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { _ in count += 1; return true }
            return count
        }
    }

    @Test func typingInOneViewShowsInTheOtherAndInTheDocument() {
        let two = Two("* a\nbody\n")
        two.editor.textView.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        #expect(two.second.string == "X* a\nbody\n")
        #expect(two.editor.document.text == "X* a\nbody\n")
    }

    @Test func undoIsShared() {
        let two = Two("* a\nbody\n")
        two.editor.textView.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        two.second.undoManager?.undo()
        #expect(two.second.string == "* a\nbody\n")
        #expect(two.editor.document.text == "* a\nbody\n")
    }

    @Test func foldsAreTheEditors() {
        let two = Two("* a\nbody\n* b\n")
        let before = two.lines(two.second)
        two.editor.setCaret(0)
        _ = two.editor.cycleAtCaret()
        #expect(two.lines(two.second) < before)
        #expect(two.lines(two.editor.textView) == two.lines(two.second))
    }

    @Test func commandsActOnTheFocusedView() {
        let two = Two("* a\nbody\n* b\nmore\n")
        two.windows[1].makeFirstResponder(two.second)
        #expect(two.editor.textView === two.second)
        two.second.setSelectedRange(NSRange(location: 9, length: 0))
        _ = two.editor.cycleAtCaret()
        #expect(two.editor.foldState.folds == [9])
    }

    @Test func aDiskChangeMapsEveryViewsCaret() {
        let two = Two("* a\nbody\n")
        two.second.setSelectedRange(NSRange(location: 5, length: 0))
        _ = two.editor.diskChanged(to: Array("XY* a\nbody\n".utf8))
        #expect(two.second.selectedRange() == NSRange(location: 7, length: 0))
        #expect(two.second.string == "XY* a\nbody\n")
    }

    @Test func removingAViewDetachesItsLayoutManager() {
        let two = Two("* a\n")
        let storage = two.editor.textView.textLayoutManager!.textContentManager!
        #expect(storage.textLayoutManagers.count == 2)
        two.editor.removeView(two.second)
        #expect(storage.textLayoutManagers.count == 1)
        #expect(two.editor.textViews.count == 1)
    }
}
