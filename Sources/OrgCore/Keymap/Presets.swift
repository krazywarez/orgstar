/// The keymaps the app ships. The user's `keymap.toml` is layered on top of the chosen one.
public enum KeymapPreset: String, Sendable, CaseIterable {
    case emacs, mac, doom

    public var title: String {
        switch self {
        case .emacs: "Emacs"
        case .mac: "Mac"
        case .doom: "Doom (Vim keys)"
        }
    }

    /// Whether the preset edits modally.
    public var isModal: Bool { self == .doom }

    public var keymap: Keymap {
        var problems: [String] = []
        let map = try! Keymap(toml: toml, problems: &problems)
        precondition(problems.isEmpty, "preset \(rawValue): \(problems)")
        return map
    }

    public var toml: String {
        switch self {
        case .emacs: Self.common + Self.speedBindings(mode: nil) + Self.emacsBindings
        case .mac: Self.common + Self.speedBindings(mode: nil) + Self.macBindings
        case .doom: Self.doomToml + Self.speedBindings(mode: "insert")
        }
    }

    /// `org-speed-commands`, for the start of a heading line when `org-use-speed-commands` is on.
    static let speedCommands: [(key: String, command: String)] = [
        ("n", "org.heading.next"), ("p", "org.heading.previous"), ("f", "org.heading.forward-same-level"),
        ("b", "org.heading.backward-same-level"), ("u", "org.heading.up"), ("j", "org.goto"),
        ("c", "org.cycle"), ("C", "org.cycle-global"), ("s", "org.narrow.toggle"), ("k", "org.subtree.cut"),
        ("U", "org.subtree.up"), ("D", "org.subtree.down"), ("r", "org.heading.demote"), ("l", "org.heading.promote"),
        ("R", "org.subtree.demote"), ("L", "org.subtree.promote"), ("i", "org.heading.insert-after-subtree"),
        ("^", "org.sort"), ("w", "app.refile"), ("a", "app.archive"), ("@", "org.subtree.mark"),
        ("#", "org.heading.toggle-comment"), ("I", "app.clock.in"), ("O", "app.clock.out"), ("t", "org.todo.cycle"),
        (",", "org.priority.set"), ("0", "org.priority.remove"), ("1", "org.priority.set-a"), ("2", "org.priority.set-b"),
        ("3", "org.priority.set-c"), (":", "org.tags.set"), ("e", "org.effort.set"), ("v", "app.agenda"),
        ("/", "org.sparse-tree"), ("o", "org.link.open"),
    ]

    static func speedBindings(mode: String?) -> String {
        speedCommands.map { key, command in
            "[[bind]]\nkeys = \"\(key)\"\ncommand = \"\(command)\"\nwhen = \"speed\"\n" + (mode.map { "mode = \"\($0)\"\n" } ?? "")
        }.joined()
    }

    /// Doom: the Emacs preset's org bindings in every evil state (as org-mode-map's are), with
    /// evil-org's `M-h/j/k/l` forms, then Doom's leader, localleader and evil-org keys.
    static let common = """
        [[bind]]
        keys = "TAB"
        command = "org.cycle"
        when = "heading"
        [[bind]]
        keys = "TAB"
        command = "org.cycle"
        when = "fold-line"

        [[bind]]
        keys = "S-TAB"
        command = "org.cycle-global"
        [[bind]]
        keys = "TAB"
        command = "org.table.next-field"
        when = "table"
        [[bind]]
        keys = "S-TAB"
        command = "org.table.previous-field"
        when = "table"
        [[bind]]
        keys = "RET"
        command = "org.table.next-row"
        when = "table"
        [[bind]]
        keys = "TAB"
        command = "org.table-el.next-cell"
        when = "table-el"
        [[bind]]
        keys = "S-TAB"
        command = "org.table-el.previous-cell"
        when = "table-el"

        """

}
