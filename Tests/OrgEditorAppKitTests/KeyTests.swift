import AppKit
import OrgCore
import Testing
@testable import OrgEditorAppKit

@MainActor
struct KeyTests {
    static let codes: [Character: UInt16] = ["a": 0, "s": 1, "f": 3, "g": 5, "z": 6, "x": 7, "c": 8, "w": 13, "t": 17]

    /// Presses a key. `control` sends the control character, as macOS does.
    func press(_ h: Harness, _ key: Character, control: Bool = false, option: UInt = 0, typed: String? = nil) {
        var flags: NSEvent.ModifierFlags = []
        if control { flags.insert(.control) }
        if option != 0 { flags = NSEvent.ModifierFlags(rawValue: flags.rawValue | NSEvent.ModifierFlags.option.rawValue | option) }
        let ignoring = String(key)
        let characters = typed ?? (control ? String(UnicodeScalar(UInt8(key.asciiValue! & 0x1f))) : ignoring)
        send(h, characters: characters, ignoring: ignoring, code: Self.codes[key] ?? 0, flags: flags)
    }

    func send(_ h: Harness, characters: String, ignoring: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: h.window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code
        )!
        h.textView.keyDown(with: event)
    }

    @Test func prefixSequenceRunsAnOrgCommand() {
        let h = Harness("* a\n")
        var pending: [String?] = []
        var next: [(key: String, title: String)] = []
        h.editor.onKeysPending = { keys, continuations in
            pending.append(keys)
            if keys != nil { next = continuations }
        }
        h.caret(at: 1)
        press(h, "c", control: true)
        #expect(pending == ["C-c"])
        #expect(next.contains { $0.key == "C-t" && $0.title == "Cycle TODO State" })
        press(h, "t", control: true)
        #expect(h.string == "* TODO a\n")
        #expect(pending == ["C-c", nil])
        h.checkInSync()
    }

    @Test func undefinedSequenceReportsAMessage() {
        let h = Harness("text\n")
        var messages: [String] = []
        h.editor.onMessage = { messages.append($0) }
        press(h, "c", control: true)
        press(h, "z", control: true)
        #expect(messages == ["C-c C-z is undefined"])
        press(h, "x", control: true)
        press(h, "g", control: true)
        #expect(messages.last == "Quit")
        #expect(h.string == "text\n")
    }

    @Test func tabFoldsOnHeadingsAndIndentsElsewhere() {
        let h = Harness(outline)
        h.caret(at: 1)
        send(h, characters: "\t", ignoring: "\t", code: 48)
        #expect(h.visibleLines == ["* a\n", "* c\n", "text\n"])
        h.caret(at: h.offset(of: "text"))
        send(h, characters: "\t", ignoring: "\t", code: 48)
        #expect(h.string.hasSuffix("\ttext\n"))
    }

    @Test func markExtendsMovementAndKillTakesTheRegion() {
        let h = Harness("abc\n")
        h.caret(at: 0)
        send(h, characters: "\0", ignoring: " ", code: 49, flags: .control)
        #expect(h.editor.markActive)
        press(h, "f", control: true)
        press(h, "f", control: true)
        #expect(h.textView.selectedRange() == NSRange(location: 0, length: 2))
        press(h, "w", control: true)
        #expect(h.string == "c\n")
        #expect(!h.editor.markActive)
        h.checkInSync()
    }

    @Test func leftOptionIsMetaRightOptionTypes() {
        let h = Harness("one two\n")
        h.caret(at: 0)
        press(h, "f", option: KeyEvents.leftOption, typed: "ƒ")
        #expect(h.caret == 3)
        press(h, "f", option: KeyEvents.rightOption, typed: "ƒ")
        #expect(h.string == "oneƒ two\n")
    }

    @Test func appCommandsGoToTheApp() {
        let h = Harness("text\n")
        var commands: [String] = []
        h.editor.onAppCommand = { commands.append($0) }
        press(h, "x", control: true)
        press(h, "s", control: true)
        #expect(commands == ["app.save"])
    }

    @Test func userKeymapOverridesThePreset() throws {
        let h = Harness("* a\n")
        var problems: [String] = []
        let user = try Keymap(toml: "[[bind]]\nkeys = \"C-c C-t\"\ncommand = \"org.priority.up\"\n", problems: &problems)
        h.editor.keymap = .layered([KeymapPreset.emacs.keymap, user])
        h.caret(at: 1)
        press(h, "c", control: true)
        press(h, "t", control: true)
        #expect(h.string == "* [#B] a\n")
    }

    @Test func everyPresetCommandExists() {
        for preset in KeymapPreset.allCases {
            for binding in preset.keymap.bindings {
                #expect(EditorCommands.command(binding.command) != nil, "\(preset): \(binding.command)")
            }
        }
    }
}
