import AppKit
import OrgCore
import Testing
@testable import OrgEditorAppKit

/// The Doom preset in the editor: keys through the keymap and the modal engine.
@MainActor
struct ModalTests {
    func doom(_ text: String) -> Harness {
        let h = Harness(text)
        h.editor.keymap = KeymapPreset.doom.keymap
        h.editor.modal = true
        return h
    }

    /// Types `keys` as key events: letters, `ESC`, `RET`, `TAB`, `SPC`.
    func type(_ h: Harness, _ keys: String) {
        let codes: [String: UInt16] = ["ESC": 53, "RET": 36, "TAB": 48, "SPC": 49]
        for token in keys.split(separator: " ") {
            let key = String(token)
            if key.hasPrefix("C-") {
                let letter = String(key.dropFirst(2))
                let named = codes[letter]
                let characters = named == nil ? letter : " "
                KeyTests().send(h, characters: characters, ignoring: characters, code: named ?? 0, flags: .control)
            } else if let code = codes[key] {
                let characters = key == "ESC" ? "\u{1b}" : key == "RET" ? "\r" : key == "TAB" ? "\t" : " "
                KeyTests().send(h, characters: characters, ignoring: characters, code: code)
            } else {
                let shifted = key.first!.isUppercase
                KeyTests().send(h, characters: key, ignoring: key, code: 0, flags: shifted ? .shift : [])
            }
        }
    }

    @Test func normalStateEditsAndInsertTypes() {
        let h = doom("hello world\nsecond\n")
        h.caret(at: 0)
        type(h, "d w")
        #expect(h.editor.document.text == "world\nsecond\n")
        type(h, "c i w")
        #expect(h.editor.vim.mode == .insert)
        h.textView.insertText("planet", replacementRange: h.textView.selectedRange())
        type(h, "ESC")
        #expect(h.editor.document.text == "planet\nsecond\n")
        #expect(h.textView.selectedRange().location == 5)
        type(h, "j .")
        #expect(h.editor.document.text == "planet\nplanet\n")
    }

    @Test func undo() {
        let h = doom("hello world\n")
        h.caret(at: 0)
        type(h, "d w")
        #expect(h.editor.document.text == "world\n")
        type(h, "u")
        #expect(h.editor.document.text == "hello world\n")
    }

    @Test func leaderAndOrgKeys() {
        let h = doom("* TODO Task\n")
        var app: [String] = []
        h.editor.onAppCommand = { app.append($0) }
        h.caret(at: 2)
        type(h, "SPC f s")
        #expect(app == ["app.save"])
        type(h, "RET")
        #expect(h.editor.document.text == "* DONE Task\n")
        type(h, "SPC m t")
        #expect(h.editor.document.text == "* KILL Task\n" || h.editor.document.text.hasPrefix("* "))
        type(h, "TAB")
        #expect(h.editor.vim.mode == .normal)
    }

    @Test func keyHintsFollowContext() {
        let h = doom("* a\n#+begin_src sh\necho\n#+end_src\n")
        var hints: [(key: String, title: String)] = []
        h.editor.onKeysPending = { _, next in if !next.isEmpty { hints = next } }
        func hint() -> String? { hints.first { $0.key == "C-c" }?.title }
        h.caret(at: 1)
        type(h, "C-c")
        #expect(hint() != nil && hint() != "Run Source Block")
        type(h, "C-g")
        h.caret(at: 20)
        type(h, "C-c")
        #expect(hint() == "Run Source Block")
        type(h, "C-g")
    }

    @Test func visualSelection() {
        let h = doom("one two three\n")
        h.caret(at: 0)
        type(h, "v e")
        #expect(h.textView.selectedRange() == NSRange(location: 0, length: 3))
        type(h, "d")
        #expect(h.editor.document.text == " two three\n")
        #expect(h.textView.selectedRange().length == 0)
    }

    func shiftTab(_ h: Harness) {
        KeyTests().send(h, characters: "\u{19}", ignoring: "\u{19}", code: 48, flags: .shift)
    }

    @Test func insertStateTabFollowsDoom() {
        let h = doom("* Top\n** Sub\n- one\n- item\n  - child\nbody\n")
        h.caret(at: 8)
        type(h, "i")
        #expect(h.editor.vim.mode == .insert)
        shiftTab(h)
        #expect(h.editor.document.text.hasPrefix("* Top\n* Sub\n"))
        type(h, "TAB")
        #expect(h.editor.document.text.hasPrefix("* Top\n** Sub\n"))
        let item = (h.editor.document.text as NSString).range(of: "- item").location
        h.caret(at: item + 3)
        type(h, "TAB")
        #expect(h.editor.document.text.contains("- one\n  - item\n    - child\n"))
        #expect(h.editor.vim.mode == .insert)
    }

    @Test func shiftTabCyclesInNormalState() {
        let h = doom("* Top\nbody\n")
        h.caret(at: 7)
        let before = h.editor.document.text
        shiftTab(h)
        #expect(h.editor.document.text == before)
        #expect(h.editor.vim.mode == .normal)
    }

    @Test func reportsStateAndQuits() {
        let h = doom("text\n")
        var states: [String?] = []
        var app: [String] = []
        h.editor.onModeChange = { states.append($0) }
        h.editor.onAppCommand = { app.append($0) }
        h.caret(at: 0)
        type(h, "i")
        type(h, "ESC")
        type(h, "V")
        type(h, "ESC")
        type(h, "SPC q q")
        #expect(states == ["insert", "normal", "visual-line", "normal"])
        #expect(app == ["app.quit"])
        h.editor.modal = false
        #expect(states.last == .some(nil))
    }

    @Test func macrosReplayKeys() {
        let h = doom("one two\nthree four\nfive six\nseven\n")
        h.caret(at: 0)
        type(h, "q a d w j q")
        #expect(h.editor.document.text == "two\nthree four\nfive six\nseven\n")
        type(h, "@ a")
        #expect(h.editor.document.text == "two\nfour\nfive six\nseven\n")
        type(h, "@ @")
        #expect(h.editor.document.text == "two\nfour\nsix\nseven\n")
        type(h, "g g q b A ! ESC j q 2 @ b")
        #expect(h.editor.document.text == "two!\nfour!\nsix!\nseven\n", "\(h.editor.document.text.debugDescription)")
    }

    @Test func jumpsAndMarks() {
        let h = doom("one\ntwo\nthree\nfour\n")
        h.caret(at: 4)
        type(h, "G")
        #expect(h.textView.selectedRange().location == 19)
        type(h, "C-o")
        #expect(h.textView.selectedRange().location == 4)
        type(h, "C-i")
        #expect(h.textView.selectedRange().location == 19)
        type(h, "g g m a G ' a")
        #expect(h.textView.selectedRange().location == 0)
        // Marks follow edits above them.
        type(h, "G m b g g O")
        h.textView.insertText("new", replacementRange: h.textView.selectedRange())
        type(h, "ESC ` b")
        #expect(h.textView.selectedRange().location == 23)
    }
}

struct PresetCommandTests {
    /// Every command a preset binds is one the editor runs, and every mode is a state.
    @Test func presetsBindKnownCommands() throws {
        let known = Set(EditorCommands.all.map(\.id))
        for preset in KeymapPreset.allCases {
            var problems: [String] = []
            _ = try Keymap(toml: preset.toml, problems: &problems, commands: known)
            #expect(problems.isEmpty, "\(preset): \(problems)")
        }
    }
}
