import AppKit
import Testing
@testable import OrgEditorAppKit

/// What VoiceOver reads: the text as shown, with ranges and lines in its terms.
@MainActor
struct AccessibilityTests {
    let text = "* Top\nbody\n* Links\nSee [[https://x.org][the site]] now.\n"

    @Test func readsTheTextAsShown() {
        let h = Harness(text)
        h.editor.showMarkup = false
        h.caret(at: 0)
        h.drainStyling()
        let view = h.textView
        #expect(view.accessibilityValue() == "* Top\nbody\n* Links\nSee the site now.\n")
        #expect(view.accessibilityNumberOfCharacters() == 37)

        // The caret after "the" in the link description.
        let the = (text as NSString).range(of: "the site").location
        h.caret(at: the + 3)
        h.drainStyling()
        h.caret(at: 0)
        h.drainStyling()
        view.setAccessibilitySelectedTextRange(NSRange(location: 27, length: 4))
        #expect(view.selectedRange() == NSRange(location: the + 4, length: 4))
        #expect(view.accessibilitySelectedText() == "site")
        // The caret's line now shows its markup, as on screen.
        #expect(view.accessibilityValue() == "* Top\nbody\n* Links\nSee [[https://x.org][the site]] now.\n")
        #expect(view.accessibilityLine(for: 7) == 1 && view.accessibilityRange(forLine: 1) == NSRange(location: 6, length: 5))
        #expect(view.accessibilityString(for: NSRange(location: 19, length: 3)) == "See")

        // Folded text is still read.
        h.caret(at: 0)
        h.editor.cycleAtCaret()
        h.drainStyling()
        #expect(view.accessibilityValue() == "* Top\nbody\n* Links\nSee the site now.\n")
        #expect(view.accessibilityInsertionPointLineNumber() == 0)

        // With markup shown, the whole text.
        h.editor.showMarkup = true
        h.drainStyling()
        #expect(view.accessibilityValue() == text)
    }

    @Test func mapsBetweenShownAndBufferOffsets() {
        let storage = NSMutableAttributedString(string: "a[[x][b]]c")
        storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 0.01), range: NSRange(location: 1, length: 5))
        storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 0.01), range: NSRange(location: 7, length: 2))
        let shown = AccessibleText(storage)
        #expect(shown.string == "abc" && shown.model == [0, 6, 9, 10])
        #expect(shown.visible(NSRange(location: 6, length: 1)) == NSRange(location: 1, length: 1))
        #expect(shown.buffer(NSRange(location: 0, length: 3)) == NSRange(location: 0, length: 10))
        #expect(shown.buffer(NSRange(location: 3, length: 0)) == NSRange(location: 10, length: 0))
        let pretty = NSMutableAttributedString(string: "x \\alpha y")
        pretty.addAttribute(.font, value: NSFont.systemFont(ofSize: 0.01), range: NSRange(location: 2, length: 5))
        pretty.addAttribute(.orgEntityDisplay, value: "α", range: NSRange(location: 7, length: 1))
        #expect(AccessibleText(pretty).string == "x α y")
    }
}
