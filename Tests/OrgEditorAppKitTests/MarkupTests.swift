import AppKit
import OrgCore
import Testing
@testable import OrgEditorAppKit

/// Hiding link and emphasis markup, with the caret's line showing it.
@MainActor
struct MarkupTests {
    static let text = "See [[https://example.org][Example]] and =code= here\nsecond line\n"

    func size(_ h: Harness, at offset: Int) -> CGFloat {
        (h.textView.textStorage!.attribute(.font, at: offset, effectiveRange: nil) as! NSFont).pointSize
    }

    func x(_ h: Harness, _ offset: Int) -> CGFloat {
        h.layout()
        return h.textView.firstRect(forCharacterRange: NSRange(location: offset, length: 1), actualRange: nil).minX
    }

    @Test func hidesMarkupOffTheCaretLine() {
        let h = Harness(Self.text)
        let ns = Self.text as NSString
        let bracket = ns.range(of: "[[").location
        let equals = ns.range(of: "=code").location
        #expect(size(h, at: bracket) > 1)

        h.caret(at: ns.range(of: "second").location)
        h.editor.options.hideEmphasisMarkers = true
        h.editor.showMarkup = false
        h.drainStyling()
        #expect(size(h, at: bracket) < 1)
        #expect(size(h, at: equals) < 1)
        #expect(size(h, at: ns.range(of: "Example").location) > 1)
        // Hidden text takes no room: "Example" starts right after "See ".
        let column = x(h, 1) - x(h, 0)
        #expect(abs(x(h, ns.range(of: "Example").location) - x(h, 0) - 4 * column) < 1)

        h.caret(at: 1)
        #expect(size(h, at: bracket) > 1)
        h.caret(at: ns.range(of: "second").location)
        #expect(size(h, at: bracket) < 1)

        h.editor.showMarkup = true
        h.drainStyling()
        #expect(size(h, at: bracket) > 1)
    }

    @Test func emphasisFollowsTheEmacsSetting() {
        let h = Harness(Self.text)
        let ns = Self.text as NSString
        h.caret(at: ns.range(of: "second").location)
        h.editor.options.hideEmphasisMarkers = false
        h.editor.showMarkup = false
        h.drainStyling()
        #expect(size(h, at: ns.range(of: "=code").location) > 1)
        #expect(size(h, at: ns.range(of: "[[").location) < 1)
    }
}

@MainActor
struct LineNumberTests {
    @Test func marginFollowsTheSettingAndLineCount() {
        let h = Harness("* a\nb\n")
        h.editor.showLineNumbers = true
        let narrow = h.textView.textContainerInset.width
        #expect(narrow > 0)
        h.textView.insertText(String(repeating: "x\n", count: 120), replacementRange: NSRange(location: 6, length: 0))
        #expect(h.textView.textContainerInset.width > narrow)
        h.editor.showLineNumbers = false
        #expect(h.textView.textContainerInset.width == 0)
    }
}
