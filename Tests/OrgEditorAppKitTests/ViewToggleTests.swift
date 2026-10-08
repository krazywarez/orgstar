import AppKit
import OrgCore
import OrgDocument
import Testing
@testable import OrgEditorAppKit

@MainActor
struct ViewToggleTests {
    /// A plain click at the middle of the character at `offset`.
    func click(_ h: Harness, _ offset: Int) {
        let screen = h.textView.firstRect(forCharacterRange: NSRange(location: offset, length: 1), actualRange: nil)
        let inWindow = h.window.convertPoint(fromScreen: NSPoint(x: screen.midX, y: screen.midY))
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: inWindow, modifierFlags: [], timestamp: 0,
                                       windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        h.textView.mouseDown(with: event)
    }

    @Test func clickingStarsCyclesAndCheckboxesToggle() {
        let h = Harness("* Top\nbody\n- [ ] task\n* Next\n")
        click(h, 0)
        #expect(h.visibleLines == ["* Top\n", "* Next\n"])
        click(h, 0)
        #expect(h.visibleLines.count == 4)
        click(h, h.offset(of: "[ ]") + 1)
        #expect(h.editor.document.text == "* Top\nbody\n- [X] task\n* Next\n")
        // Elsewhere a click is the text view's.
        #expect(!h.editor.click(at: h.offset(of: "Top") + 1))
        #expect(!h.editor.click(at: h.offset(of: "task") + 1))
    }

    @Test func truncatingAndSpellChecking() {
        let h = Harness("* Hedding\n~codez~ wurds\n")
        #expect(!h.editor.truncatesLines)
        h.editor.run("editor.toggle-truncate-lines")
        #expect(h.editor.truncatesLines && h.textView.enclosingScrollView?.hasHorizontalScroller == true)
        h.editor.run("editor.toggle-truncate-lines")
        #expect(!h.editor.truncatesLines && h.textView.textContainer?.widthTracksTextView == true)
        h.editor.run("editor.toggle-spell-check")
        #expect(h.textView.isContinuousSpellCheckingEnabled)
        let code = NSRange(location: h.offset(of: "codez"), length: 5)
        let prose = NSRange(location: h.offset(of: "wurds"), length: 5)
        #expect(h.editor.textView(h.textView, shouldSetSpellingState: 1, range: code) == 0)
        #expect(h.editor.textView(h.textView, shouldSetSpellingState: 1, range: prose) == 1)
    }

    @Test func gjMovesByScreenLines() {
        let long = Array(repeating: "word", count: 60).joined(separator: " ")
        // In Org files gj is evil-org's element motion; elsewhere it's screen lines.
        let h = Harness(DocumentState(bytes: Array((long + "\nnext\n").utf8)), mode: .plain(language: nil))
        h.editor.keymap = KeymapPreset.doom.keymap
        h.editor.modal = true
        h.caret(at: 0)
        h.caret(at: 0)
        ModalTests().type(h, "g j")
        #expect(h.caret > 0 && h.caret < long.utf16.count, "\(h.caret)")
        ModalTests().type(h, "g k")
        #expect(h.caret == 0)
        ModalTests().type(h, "j")
        #expect(h.caret == long.utf16.count + 1)
    }
}
