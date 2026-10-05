import Testing
@testable import OrgCore

struct KeyNotationTests {
    @Test func parsesAndFormats() {
        #expect(KeySequence.parse("C-c C-x C-i").map(KeySequence.format) == "C-c C-x C-i")
        #expect(KeyChord.parse("C-M-x") == KeyChord("x", [.control, .meta]))
        #expect(KeyChord.parse("S-a") == KeyChord("A"))
        #expect(KeyChord.parse("S-TAB") == KeyChord("TAB", .shift))
        #expect(KeyChord.parse("<backtab>") == KeyChord("TAB", .shift))
        #expect(KeyChord.parse("C--") == KeyChord("-", .control))
        #expect(KeyChord.parse("M-<") == KeyChord("<", .meta))
        #expect(KeyChord.parse("s-<left>")?.description == "s-<left>")
        #expect(KeyChord.parse("<tab>") == KeyChord("TAB"))
        #expect(KeyChord.parse("X-a") == nil)
        #expect(KeyChord.parse("abc") == nil)
        #expect(KeySequence.parse("") == nil)
    }
}

struct TOMLTests {
    @Test func parsesTables() throws {
        let tables = try TOML.parse("""
            top = 1 # comment
            [[bind]]
            keys = "C-c \\"x\\""
            when = 'heading'
            on = true

            [options]
            name = "a\\u00e9"
            """)
        #expect(tables.count == 3)
        #expect(tables[0].values["top"] == .integer(1))
        #expect(tables[1].name == "bind" && tables[1].isArrayElement && tables[1].line == 2)
        #expect(tables[1].values["keys"] == .string("C-c \"x\""))
        #expect(tables[1].values["when"] == .string("heading"))
        #expect(tables[1].values["on"] == .bool(true))
        #expect(tables[2].values["name"] == .string("aé"))
    }

    @Test func reportsErrorsWithLines() {
        #expect(throws: TOML.ParseError(line: 2, message: "unclosed string")) { try TOML.parse("[[bind]]\nkeys = \"C-c") }
        #expect(throws: TOML.ParseError(line: 1, message: "expected key = value")) { try TOML.parse("keys") }
        #expect(throws: TOML.ParseError(line: 2, message: "duplicate key a")) { try TOML.parse("a = 1\na = 2") }
    }
}

struct KeymapTests {
    func map(_ toml: String) throws -> (Keymap, [String]) {
        var problems: [String] = []
        let keymap = try Keymap(toml: toml, problems: &problems)
        return (keymap, problems)
    }

    @Test func skipsBadEntries() throws {
        let (keymap, problems) = try map("""
            [[bind]]
            keys = "C-c C-t"
            command = "org.todo.cycle"
            [[bind]]
            keys = "Q-x"
            command = "a"
            [[bind]]
            keys = "TAB"
            command = "a"
            when = "nowhere"
            [other]
            """)
        #expect(keymap.bindings.count == 1)
        #expect(problems.count == 3)
    }

    @Test func laterLayersWinAndCanUnbind() throws {
        let preset = KeymapPreset.emacs.keymap
        let (user, _) = try map("""
            [[bind]]
            keys = "C-c C-t"
            command = "org.priority.up"
            [[bind]]
            keys = "C-k"
            command = "none"
            """)
        let keymap = Keymap.layered([preset, user])
        #expect(keymap.candidates(for: KeySequence.parse("C-c C-t")!).first?.command == "org.priority.up")
        #expect(keymap.candidates(for: KeySequence.parse("C-k")!).isEmpty)
        #expect(keymap.keys(for: "org.todo.cycle").map(KeySequence.format) == "S-<right>")
    }

    @Test func keyLabelsForMenus() {
        let emacs = KeymapPreset.emacs.keymap
        #expect(emacs.keyLabels(for: "org.todo.cycle") == ["C-c C-t", "S-<right>"])
        #expect(emacs.keyLabels(for: "org.schedule") == ["C-c C-s"])
        let doom = KeymapPreset.doom.keymap
        let labels = doom.keyLabels(for: "org.todo.cycle", modes: ["normal", "insert"])
        #expect(labels == ["C-c C-t", "SPC m t"])
        #expect(doom.keyLabels(for: "app.quit", modes: ["normal", "insert"]) == ["SPC q q"])
    }

    @Test func dispatchesPrefixes() {
        var dispatcher = KeyDispatcher(keymap: KeymapPreset.emacs.keymap)
        let c = KeyChord("c", .control), t = KeyChord("t", .control), z = KeyChord("z", .control)
        #expect(dispatcher.feed(c) == .pending([c]))
        guard case .complete(let keys, let candidates) = dispatcher.feed(t) else {
            Issue.record("expected a binding")
            return
        }
        #expect(keys == [c, t] && candidates.first?.command == "org.todo.cycle")
        #expect(dispatcher.feed(c) == .pending([c]))
        #expect(dispatcher.feed(z) == .undefined([c, z]))
        #expect(dispatcher.feed(c) == .pending([c]))
        #expect(dispatcher.feed(KeyDispatcher.quit) == .cancelled)
        #expect(dispatcher.feed(KeyChord("a")) == .unbound)
    }

    @Test func continuationsListNextKeys() {
        let keymap = KeymapPreset.emacs.keymap
        let next = keymap.continuations(of: [KeyChord("x", .control)])
        #expect(next.contains { $0.key == KeyChord("s", .control) && $0.command == "app.save" })
        #expect(keymap.continuations(of: []).contains { $0.key == KeyChord("c", .control) && $0.command == nil })
    }

    @Test func contexts() {
        let text = "* a\n| x |\n- item\n"
        let tree = OrgParser.parse(text)
        func holds(_ name: String, _ caret: Int, _ selection: Range<Int>? = nil) -> Bool {
            KeyContext.holds(name, in: EditContext(revision: 0, text: text, tree: tree, selection: [selection ?? caret..<caret]))
        }
        #expect(holds("heading", 1) && !holds("heading", 5))
        #expect(holds("table", 5) && !holds("table", 12))
        #expect(holds("item", 12))
        #expect(holds("region", 0, 0..<2) && !holds("region", 0))
    }

    @Test func presetsParse() {
        for preset in KeymapPreset.allCases { #expect(!preset.keymap.bindings.isEmpty) }
    }
}
