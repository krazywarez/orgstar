import AppKit
import OrgCore
import Testing
@testable import OrgApp
@testable import OrgEditorAppKit

/// C-s, C-r, Vim's `/` and auto-fill through the editor's key handling.
@MainActor
struct ISearchEditorTests {
    let keys = ModalTests()

    @Test func controlSSearchesAsYouTypeWithoutTyping() {
        let h = Harness("foo bar foo baz\n")
        var messages: [String] = []
        h.editor.onMessage = { messages.append($0) }
        h.caret(at: 0)
        keys.type(h, "C-s b a")
        #expect(h.textView.selectedRange() == NSRange(location: 4, length: 2))
        keys.type(h, "z")
        #expect(h.textView.selectedRange() == NSRange(location: 12, length: 3))
        #expect(messages.last == "I-search: baz")
        keys.type(h, "RET")
        #expect(h.string == "foo bar foo baz\n")
        #expect(h.textView.selectedRange() == NSRange(location: 15, length: 0))
        // C-r from there, and C-g back to where it began.
        keys.type(h, "C-r f o o C-g")
        #expect(h.textView.selectedRange() == NSRange(location: 15, length: 0))
        #expect(h.editor.isearch == nil)
    }

    @Test func anotherKeyEndsTheSearchAndRuns() {
        let h = Harness("foo bar foo baz\n")
        h.caret(at: 0)
        keys.type(h, "C-s b a r C-a")
        #expect(h.editor.isearch == nil)
        #expect(h.textView.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test func vimSlashSearchesAndNRepeats() {
        let h = keys.doom("one two one two\n")
        h.caret(at: 0)
        keys.type(h, "/ t w o")
        #expect(h.textView.selectedRange() == NSRange(location: 4, length: 3))
        keys.type(h, "RET")
        #expect(h.textView.selectedRange().location == 4)
        keys.type(h, "n")
        #expect(h.textView.selectedRange().location == 12)
        #expect(h.string == "one two one two\n")
    }

    @Test func spaceAutoFillsPastTheFillColumn() {
        let h = Harness("\n")
        var options = h.editor.options
        options.fillColumn = 12
        options.autoFill = true
        h.editor.options = options
        h.caret(at: 0)
        for word in ["alpha", "beta", "gamma", "delta"] {
            for letter in word { keys.type(h, String(letter)) }
            keys.type(h, "SPC")
        }
        #expect(h.string == "alpha beta\ngamma delta \n")
        h.editor.run("editor.toggle-auto-fill")
        for letter in "epsilonzeta" { keys.type(h, String(letter)) }
        keys.type(h, "SPC")
        #expect(h.string == "alpha beta\ngamma delta epsilonzeta \n")
    }
}
