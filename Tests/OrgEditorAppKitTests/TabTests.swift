import AppKit
import OrgDocument
import Testing
@testable import OrgEditorAppKit

/// Tabs stop every 8 columns from the line's start, as `tab-width` 8 does in Emacs, so text
/// aligned with spaces under a tab-indented line stays aligned.
@MainActor
struct TabTests {
    static let text = "* Lists\n\t1. Spelling and\n           vice-versa.\n\t\ta. Design\n                   should\n"

    func x(_ h: Harness, _ needle: String) -> CGFloat {
        h.layout()
        let offset = (Self.text as NSString).range(of: needle).location
        return h.textView.firstRect(forCharacterRange: NSRange(location: offset, length: 1), actualRange: nil).minX
    }

    @Test(arguments: [true, false]) func tabsAreEightColumns(indented: Bool) {
        let h = Harness(DocumentState(bytes: Array(Self.text.utf8)), layout: false)
        h.editor.indented = indented
        h.editor.restyleOutsideEditing(0..<(Self.text as NSString).length)
        h.drainStyling()
        #expect(abs(x(h, "Spelling") - x(h, "vice")) < 1)
        #expect(abs(x(h, "Design") - x(h, "should")) < 1)
    }
}
