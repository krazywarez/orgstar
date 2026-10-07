import AppKit
import OrgCore
import Testing
@testable import OrgEditorAppKit

/// `electric-pair-mode` through key events, in the Emacs and Doom presets.
@MainActor
struct ElectricPairEditorTests {
    func harness(_ text: String, on: Bool = true) -> Harness {
        let h = Harness(text)
        var options = h.editor.options
        options.electricPair = on
        h.editor.options = options
        return h
    }

    func key(_ h: Harness, _ characters: String, code: UInt16 = 0) {
        KeyTests().send(h, characters: characters, ignoring: characters, code: code)
    }

    @Test func pairsSkipsAndDeletes() {
        let h = harness("Text \n")
        h.caret(at: 5)
        key(h, "(")
        #expect(h.editor.document.text == "Text ()\n")
        #expect(h.textView.selectedRange().location == 6)
        key(h, "\u{7f}", code: 51)
        #expect(h.editor.document.text == "Text \n")
        key(h, "[")
        key(h, "\r", code: 36)
        #expect(h.editor.document.text == "Text [\n\n]\n")
        #expect(h.textView.selectedRange().location == 7)
        h.caret(at: 8)
        key(h, "]")
        #expect(h.editor.document.text == "Text [\n\n]\n")
        #expect(h.textView.selectedRange().location == 9)
    }

    @Test func offTypesAsUsual() {
        let h = harness("Text \n", on: false)
        h.caret(at: 5)
        #expect(!h.editor.electricPair(KeyChord("(")))
        #expect(h.editor.document.text == "Text \n")
    }

    @Test func doomInsertState() {
        let h = harness("x\n")
        h.editor.keymap = KeymapPreset.doom.keymap
        h.editor.modal = true
        h.caret(at: 1)
        ModalTests().type(h, "a")
        key(h, "\"")
        #expect(h.editor.document.text == "x\"\"\n")
        #expect(h.textView.selectedRange().location == 2)
    }
}
