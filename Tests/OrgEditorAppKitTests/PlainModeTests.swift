import AppKit
import OrgCore
import OrgDocument
import Testing
@testable import OrgEditorAppKit

/// Files that aren't org: plain text, without org styling, folding or commands.
@MainActor
struct PlainModeTests {
    func plain(_ text: String) -> Harness {
        let h = Harness(DocumentState(bytes: Array(text.utf8)), mode: .plain(language: nil))
        h.drainStyling()
        h.layout()
        return h
    }

    @Test func orgCommandsDoNothing() {
        let h = plain("* TODO Not a heading\n")
        var messages: [String] = []
        h.editor.onMessage = { messages.append($0) }
        h.caret(at: 2)
        h.editor.run("org.todo.cycle")
        #expect(h.editor.document.text == "* TODO Not a heading\n")
        #expect(messages == ["Not an org file"])
        KeyTests().send(h, characters: "\t", ignoring: "\t", code: 48)
        #expect(h.editor.document.text == "* \tTODO Not a heading\n")
    }

    @Test func noOrgStyling() {
        let h = plain("* Heading *bold*\n")
        let org = Harness("* Heading *bold*\n")
        let font = { (h: Harness) in h.textView.textStorage!.attribute(.font, at: 2, effectiveRange: nil) as? NSFont }
        #expect(font(h) == h.editor.theme.font)
        #expect(font(org) != org.editor.theme.font)
    }
}
