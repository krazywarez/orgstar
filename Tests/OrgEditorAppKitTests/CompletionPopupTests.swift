import AppKit
import OrgCore
import Testing
@testable import OrgEditorAppKit

@MainActor
struct CompletionPopupTests {
    func at(_ text: String) -> Harness {
        let h = Harness(text)
        h.caret(at: text.utf16.count)
        return h
    }

    @Test func oneCandidateIsInserted() {
        let h = at("#+TI")
        h.editor.run("editor.complete")
        #expect(h.editor.document.text == "#+TITLE: " && h.caret == 9)
        let tags = at("* H :work:\n* I :")
        tags.editor.run("editor.complete")
        #expect(tags.editor.document.text == "* H :work:\n* I :work:")
        let template = at("  <s")
        template.editor.run("editor.complete")
        #expect(template.editor.document.text == "#+begin_src \n#+end_src" && template.caret == 12)
        let none = at("plain")
        none.editor.run("editor.complete")
        #expect(none.editor.completionPopup == nil && none.editor.document.text == "plain")
    }

    @Test func listPicksWithKeys() {
        let h = at("#+STARTUP: in")
        h.editor.run("editor.complete")
        #expect(h.editor.completionPopup?.completion.candidates == ["indent", "inlineimages"])
        #expect(h.editor.completionPopup?.window.isVisible == true)
        ModalTests().type(h, "C-n C-n")
        #expect(h.editor.completionPopup?.selected == "inlineimages")
        ModalTests().type(h, "C-p RET")
        #expect(h.editor.document.text == "#+STARTUP: indent" && h.editor.completionPopup == nil)

        // TAB completes the common start, then the list follows the text.
        let common = at("#+STARTUP: entities")
        common.editor.run("editor.complete")
        ModalTests().type(common, "TAB")
        #expect(common.editor.document.text == "#+STARTUP: entitiesp")
        #expect(common.editor.completionPopup?.completion.candidates == ["entitiesplain", "entitiespretty"])
        common.textView.insertText("r", replacementRange: common.textView.selectedRange())
        #expect(common.editor.completionPopup?.completion.candidates == ["entitiespretty"])
        common.textView.insertText(" ", replacementRange: common.textView.selectedRange())
        #expect(common.editor.completionPopup?.completion.candidates == nil || common.editor.completionPopup?.completion.range.lowerBound != 11)

        // RET with nothing chosen closes the list and is a newline.
        let plain = at("#+STARTUP: in")
        plain.editor.run("editor.complete")
        ModalTests().type(plain, "C-g")
        #expect(plain.editor.completionPopup == nil && plain.editor.document.text == "#+STARTUP: in")
    }

    @Test func doomOpensTheListAsYouType() {
        let h = Harness("* H :work:home:\n* I \n")
        h.editor.keymap = KeymapPreset.doom.keymap
        h.editor.modal = true
        h.caret(at: 20)
        ModalTests().type(h, "a")
        h.textView.insertText(":w", replacementRange: h.textView.selectedRange())
        h.editor.autoComplete()
        #expect(h.editor.completionPopup == nil)
        h.textView.insertText("o", replacementRange: h.textView.selectedRange())
        h.editor.autoComplete()
        #expect(h.editor.completionPopup?.completion.candidates == ["work:"])
        ModalTests().type(h, "ESC")
        #expect(h.editor.completionPopup == nil && h.editor.vim.mode == .normal)
        ModalTests().type(h, "a")
        h.textView.insertText("\\alp", replacementRange: h.textView.selectedRange())
        ModalTests().type(h, "C-SPC")
        #expect(h.editor.document.text.contains("\\alpha"))
    }
}
