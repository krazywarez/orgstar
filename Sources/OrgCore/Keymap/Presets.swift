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
        case .emacs: Self.common + Self.emacsBindings
        case .mac: Self.common + Self.macBindings
        case .doom: Self.doomToml
        }
    }

    /// Doom: the Emacs preset's org bindings in every evil state (as org-mode-map's are), with
    /// evil-org's `M-h/j/k/l` forms, then Doom's leader, localleader and evil-org keys.
    static var doomToml: String {
        var problems: [String] = []
        let emacs = try! Keymap(toml: common + emacsBindings, problems: &problems)
        let translations: [String: String] = ["<left>": "h", "<right>": "l", "<up>": "k", "<down>": "j"]
        var out = ""
        func bind(_ keys: String, _ command: String, when: String?, mode: String) {
            out += "[[bind]]\nkeys = \"\(keys.replacingOccurrences(of: "\\", with: "\\\\"))\"\ncommand = \"\(command)\"\n"
            if let when { out += "when = \"\(when)\"\n" }
            out += "mode = \"\(mode)\"\n"
        }
        for binding in emacs.bindings {
            let first = binding.keys[0]
            let keys = KeySequence.format(binding.keys)
            let orgKey = first.key == "c" && first.modifiers == [.control] || first.key == "x" && first.modifiers == [.control]
                || (first.modifiers.contains(.meta) && ["<left>", "<right>", "<up>", "<down>", "RET"].contains(first.key))
                || (first.modifiers.contains(.shift) && ["<left>", "<right>", "<up>", "<down>"].contains(first.key))
                || (first.modifiers == [.control] && first.key == "RET")
                || keys == "M-x"
            guard orgKey else { continue }
            for mode in ["normal", "insert", "visual"] { bind(keys, binding.command, when: binding.when, mode: mode) }
            // evil-org: M-h/j/k/l and M-H/J/K/L in normal, visual and insert.
            if binding.keys.count == 1, first.modifiers.contains(.meta), let letter = translations[first.key] {
                let shifted = first.modifiers.contains(.shift)
                let key = "M-" + (shifted ? letter.uppercased() : letter)
                for mode in ["normal", "insert", "visual"] { bind(key, binding.command, when: binding.when, mode: mode) }
            }
            // Doom: C-S-h/j/k/l are org-shift* in normal and insert.
            if binding.keys.count == 1, first.modifiers == [.shift], let letter = translations[first.key] {
                for mode in ["normal", "insert"] { bind("C-" + letter.uppercased(), binding.command, when: binding.when, mode: mode) }
            }
            // evil-org insert state: C-t demotes, C-d promotes.
            if binding.keys.count == 1, first.modifiers == [.meta], first.key == "<right>" || first.key == "<left>" {
                bind(first.key == "<right>" ? "C-t" : "C-d", binding.command, when: binding.when, mode: "insert")
            }
        }
        return out + doomBindings
    }

    static let doomBindings = """
        # Leader
        [[bind]]
        keys = "SPC SPC"
        command = "app.quick-open"
        mode = "normal"
        [[bind]]
        keys = "SPC q q"
        command = "app.quit"
        mode = "normal"
        [[bind]]
        keys = "SPC ."
        command = "app.quick-open"
        mode = "normal"
        [[bind]]
        keys = "SPC f f"
        command = "app.quick-open"
        mode = "normal"
        [[bind]]
        keys = "SPC f s"
        command = "app.save"
        mode = "normal"
        # Buffers
        [[bind]]
        keys = "SPC b b"
        command = "app.buffer.switch"
        mode = "normal"
        [[bind]]
        keys = "SPC b B"
        command = "app.buffer.switch"
        mode = "normal"
        [[bind]]
        keys = "SPC ,"
        command = "app.buffer.switch"
        mode = "normal"
        [[bind]]
        keys = "SPC `"
        command = "app.buffer.last"
        mode = "normal"
        [[bind]]
        keys = "SPC b k"
        command = "app.buffer.kill"
        mode = "normal"
        [[bind]]
        keys = "SPC b d"
        command = "app.buffer.kill"
        mode = "normal"
        [[bind]]
        keys = "SPC b K"
        command = "app.buffer.kill-all"
        mode = "normal"
        [[bind]]
        keys = "SPC b O"
        command = "app.buffer.kill-others"
        mode = "normal"
        [[bind]]
        keys = "SPC b n"
        command = "app.buffer.next"
        mode = "normal"
        [[bind]]
        keys = "SPC b p"
        command = "app.buffer.previous"
        mode = "normal"
        [[bind]]
        keys = "SPC b ]"
        command = "app.buffer.next"
        mode = "normal"
        [[bind]]
        keys = "SPC b ["
        command = "app.buffer.previous"
        mode = "normal"
        [[bind]]
        keys = "] b"
        command = "app.buffer.next"
        mode = "normal"
        [[bind]]
        keys = "[ b"
        command = "app.buffer.previous"
        mode = "normal"
        [[bind]]
        keys = "SPC b s"
        command = "app.save"
        mode = "normal"
        [[bind]]
        keys = "SPC b S"
        command = "app.save-all"
        mode = "normal"
        [[bind]]
        keys = "SPC s s"
        command = "edit.find"
        mode = "normal"
        [[bind]]
        keys = "SPC /"
        command = "app.search"
        mode = "normal"
        [[bind]]
        keys = "SPC s p"
        command = "app.search"
        mode = "normal"
        [[bind]]
        keys = "SPC :"
        command = "app.palette"
        mode = "normal"
        [[bind]]
        keys = "SPC o a"
        command = "app.agenda"
        mode = "normal"
        [[bind]]
        keys = "SPC X"
        command = "app.capture"
        mode = "normal"
        [[bind]]
        keys = "SPC z t"
        command = "app.clock.report"
        mode = "normal"
        [[bind]]
        keys = "SPC h r r"
        command = "app.reload-keymap"
        mode = "normal"

        # Localleader (SPC m)
        [[bind]]
        keys = "SPC m '"
        command = "org.edit-special"
        mode = "normal"
        [[bind]]
        keys = "SPC m s c"
        command = "org.subtree.clone"
        mode = "normal"
        [[bind]]
        keys = "SPC m s d"
        command = "org.subtree.cut"
        mode = "normal"
        [[bind]]
        keys = "SPC m s S"
        command = "org.sort"
        mode = "normal"
        [[bind]]
        keys = "SPC m h"
        command = "org.heading.toggle"
        mode = "normal"
        [[bind]]
        keys = "SPC m i"
        command = "org.item.toggle"
        mode = "normal"
        [[bind]]
        keys = "SPC m l l"
        command = "org.link.insert"
        mode = "normal"
        [[bind]]
        keys = "SPC m l s"
        command = "org.link.store"
        mode = "normal"
        [[bind]]
        keys = "SPC m l i"
        command = "org.id.store-link"
        mode = "normal"
        [[bind]]
        keys = "SPC n l"
        command = "org.link.store"
        mode = "normal"
        [[bind]]
        keys = "SPC m t"
        command = "org.todo.cycle"
        mode = "normal"
        [[bind]]
        keys = "SPC m q"
        command = "org.tags.set"
        mode = "normal"
        [[bind]]
        keys = "SPC m x"
        command = "org.checkbox.toggle"
        mode = "normal"
        [[bind]]
        keys = "SPC m A"
        command = "app.archive"
        mode = "normal"
        [[bind]]
        keys = "SPC m e h h"
        command = "app.export.html"
        mode = "normal"
        [[bind]]
        keys = "SPC m e h o"
        command = "app.export.html-open"
        mode = "normal"
        [[bind]]
        keys = "SPC m e m m"
        command = "app.export.markdown"
        mode = "normal"
        [[bind]]
        keys = "SPC m e l p"
        command = "app.export.pdf"
        mode = "normal"
        [[bind]]
        keys = "SPC m d d"
        command = "org.deadline"
        mode = "normal"
        [[bind]]
        keys = "SPC m d s"
        command = "org.schedule"
        mode = "normal"
        [[bind]]
        keys = "SPC m d t"
        command = "org.timestamp.active"
        mode = "normal"
        [[bind]]
        keys = "SPC m d T"
        command = "org.timestamp.inactive"
        mode = "normal"
        [[bind]]
        keys = "SPC m r r"
        command = "app.refile"
        mode = "normal"
        [[bind]]
        keys = "SPC m s r"
        command = "app.refile"
        mode = "normal"
        [[bind]]
        keys = "SPC m s A"
        command = "app.archive"
        mode = "normal"
        [[bind]]
        keys = "SPC m s h"
        command = "org.subtree.promote"
        mode = "normal"
        [[bind]]
        keys = "SPC m s l"
        command = "org.subtree.demote"
        mode = "normal"
        [[bind]]
        keys = "SPC m s j"
        command = "org.subtree.down"
        mode = "normal"
        [[bind]]
        keys = "SPC m s k"
        command = "org.subtree.up"
        mode = "normal"
        [[bind]]
        keys = "SPC m c i"
        command = "app.clock.in"
        mode = "normal"
        [[bind]]
        keys = "SPC m c o"
        command = "app.clock.out"
        mode = "normal"
        [[bind]]
        keys = "SPC m c c"
        command = "app.clock.cancel"
        mode = "normal"
        [[bind]]
        keys = "SPC m c g"
        command = "app.clock.goto"
        mode = "normal"
        [[bind]]
        keys = "SPC m c R"
        command = "app.clock.report"
        mode = "normal"
        [[bind]]
        keys = "SPC m c E"
        command = "org.effort.set"
        mode = "normal"
        [[bind]]
        keys = "SPC m p u"
        command = "org.priority.up"
        mode = "normal"
        [[bind]]
        keys = "SPC m p d"
        command = "org.priority.down"
        mode = "normal"
        [[bind]]
        keys = "SPC m b -"
        command = "org.table.insert-hline"
        mode = "normal"
        [[bind]]
        keys = "SPC m b a"
        command = "org.table.align"
        mode = "normal"
        [[bind]]
        keys = "SPC m b r"
        command = "org.table.recalc-all"
        mode = "normal"
        [[bind]]
        keys = "SPC m b d c"
        command = "org.table.delete-column"
        mode = "normal"
        [[bind]]
        keys = "SPC m b d r"
        command = "org.table.kill-row"
        mode = "normal"
        [[bind]]
        keys = "SPC m b i c"
        command = "org.table.insert-column"
        mode = "normal"
        [[bind]]
        keys = "SPC m b i r"
        command = "org.table.insert-row"
        mode = "normal"
        [[bind]]
        keys = "SPC m b i h"
        command = "org.table.insert-hline"
        mode = "normal"

        # evil-org and Doom's org keys
        [[bind]]
        keys = "TAB"
        command = "org.cycle"
        mode = "normal"
        [[bind]]
        keys = "S-TAB"
        command = "org.cycle-global"
        mode = "normal"
        [[bind]]
        keys = "RET"
        command = "org.dwim"
        mode = "normal"
        [[bind]]
        keys = "z a"
        command = "org.cycle"
        mode = "normal"
        [[bind]]
        keys = "z c"
        command = "org.cycle"
        mode = "normal"
        [[bind]]
        keys = "z o"
        command = "org.cycle"
        mode = "normal"
        [[bind]]
        keys = "z A"
        command = "org.cycle-global"
        mode = "normal"
        [[bind]]
        keys = "g h"
        command = "org.heading.up"
        mode = "normal"
        [[bind]]
        keys = "g j"
        command = "org.heading.forward-same-level"
        mode = "normal"
        [[bind]]
        keys = "g k"
        command = "org.heading.backward-same-level"
        mode = "normal"
        [[bind]]
        keys = "] h"
        command = "org.heading.forward-same-level"
        mode = "normal"
        [[bind]]
        keys = "[ h"
        command = "org.heading.backward-same-level"
        mode = "normal"
        [[bind]]
        keys = "RET"
        command = "org.table.next-row"
        when = "table"
        mode = "insert"
        [[bind]]
        keys = "TAB"
        command = "org.cycle"
        mode = "visual"
        [[bind]]
        keys = "S-TAB"
        command = "org.cycle-global"
        mode = "visual"

        # Insert state: org-cycle and org-shifttab with Doom's +org-indent-maybe-h, which
        # demotes or promotes a heading and indents or outdents an item tree.
        [[bind]]
        keys = "S-TAB"
        command = "org.cycle-global"
        mode = "insert"
        [[bind]]
        keys = "TAB"
        command = "org.table.next-field"
        when = "table"
        mode = "insert"
        [[bind]]
        keys = "S-TAB"
        command = "org.table.previous-field"
        when = "table"
        mode = "insert"
        [[bind]]
        keys = "TAB"
        command = "org.item.indent-tree"
        when = "item"
        mode = "insert"
        [[bind]]
        keys = "S-TAB"
        command = "org.item.outdent-tree"
        when = "item"
        mode = "insert"
        [[bind]]
        keys = "TAB"
        command = "org.heading.demote"
        when = "heading"
        mode = "insert"
        [[bind]]
        keys = "S-TAB"
        command = "org.heading.promote"
        when = "heading"
        mode = "insert"

        """


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

        """

    static let emacsBindings = """
        # Movement and editing. With a mark set (C-SPC), movement extends the region.
        [[bind]]
        keys = "C-f"
        command = "edit.forward-char"
        [[bind]]
        keys = "C-b"
        command = "edit.backward-char"
        [[bind]]
        keys = "C-n"
        command = "edit.next-line"
        [[bind]]
        keys = "C-p"
        command = "edit.previous-line"
        [[bind]]
        keys = "C-a"
        command = "edit.beginning-of-line"
        [[bind]]
        keys = "C-e"
        command = "edit.end-of-line"
        [[bind]]
        keys = "M-f"
        command = "edit.forward-word"
        [[bind]]
        keys = "M-b"
        command = "edit.backward-word"
        [[bind]]
        keys = "M-<"
        command = "edit.beginning-of-buffer"
        [[bind]]
        keys = "M->"
        command = "edit.end-of-buffer"
        [[bind]]
        keys = "C-v"
        command = "edit.scroll-up"
        [[bind]]
        keys = "M-v"
        command = "edit.scroll-down"
        [[bind]]
        keys = "C-l"
        command = "edit.recenter"
        [[bind]]
        keys = "C-d"
        command = "edit.delete-char"
        [[bind]]
        keys = "M-d"
        command = "edit.kill-word"
        [[bind]]
        keys = "M-DEL"
        command = "edit.backward-kill-word"
        [[bind]]
        keys = "C-k"
        command = "edit.kill-line"
        [[bind]]
        keys = "C-y"
        command = "edit.yank"
        [[bind]]
        keys = "C-SPC"
        command = "edit.set-mark"
        [[bind]]
        keys = "C-x h"
        command = "edit.select-all"
        [[bind]]
        keys = "C-w"
        command = "edit.kill-region"
        [[bind]]
        keys = "M-w"
        command = "edit.copy-region"
        [[bind]]
        keys = "C-/"
        command = "edit.undo"
        [[bind]]
        keys = "C-_"
        command = "edit.undo"
        [[bind]]
        keys = "C-x u"
        command = "edit.undo"
        [[bind]]
        keys = "C-g"
        command = "edit.keyboard-quit"
        [[bind]]
        keys = "C-t"
        command = "edit.transpose-chars"
        [[bind]]
        keys = "C-s"
        command = "edit.find"
        [[bind]]
        keys = "C-r"
        command = "edit.find"
        [[bind]]
        keys = "M-%"
        command = "edit.replace"

        # Files and commands
        [[bind]]
        keys = "C-x C-s"
        command = "app.save"
        [[bind]]
        keys = "C-c C-o"
        command = "org.link.open"
        [[bind]]
        keys = "C-c C-l"
        command = "org.link.insert"
        [[bind]]
        keys = "C-c l"
        command = "org.link.store"
        [[bind]]
        keys = "C-c ;"
        command = "org.heading.toggle-comment"
        [[bind]]
        keys = "C-c *"
        command = "org.heading.toggle"
        [[bind]]
        keys = "C-c -"
        command = "org.item.toggle"
        [[bind]]
        keys = "C-c @"
        command = "org.subtree.mark"
        [[bind]]
        keys = "C-c C-x C-w"
        command = "org.subtree.cut"
        [[bind]]
        keys = "C-c C-x M-w"
        command = "org.subtree.copy"
        [[bind]]
        keys = "C-c C-x C-y"
        command = "org.subtree.paste"
        [[bind]]
        keys = "C-c C-x c"
        command = "org.subtree.clone"
        [[bind]]
        keys = "C-c ^"
        command = "org.sort"
        [[bind]]
        keys = "C-c C-c"
        command = "org.ctrl-c-ctrl-c"
        [[bind]]
        keys = "C-c C-x C-r"
        command = "org.clock.report"
        [[bind]]
        keys = "C-c C-x C-u"
        command = "org.dblock.update"
        [[bind]]
        keys = "C-c C-x e"
        command = "org.effort.set"
        [[bind]]
        keys = "C-c C-c"
        command = "org.dblock.update"
        when = "dblock"
        [[bind]]
        keys = "C-c C-,"
        command = "org.structure-template"
        [[bind]]
        keys = "C-c '"
        command = "org.edit-special"
        [[bind]]
        keys = "C-x b"
        command = "app.buffer.switch"
        [[bind]]
        keys = "C-x C-b"
        command = "app.buffer.switch"
        [[bind]]
        keys = "C-x k"
        command = "app.buffer.kill"
        [[bind]]
        keys = "C-x <right>"
        command = "app.buffer.next"
        [[bind]]
        keys = "C-x <left>"
        command = "app.buffer.previous"
        [[bind]]
        keys = "C-x s"
        command = "app.save-all"
        [[bind]]
        keys = "C-x C-f"
        command = "app.quick-open"
        [[bind]]
        keys = "M-x"
        command = "app.palette"
        [[bind]]
        keys = "C-c a"
        command = "app.agenda"
        [[bind]]
        keys = "C-c c"
        command = "app.capture"
        [[bind]]
        keys = "C-c C-x C-i"
        command = "app.clock.in"
        [[bind]]
        keys = "C-c C-x C-o"
        command = "app.clock.out"
        [[bind]]
        keys = "C-c C-x C-q"
        command = "app.clock.cancel"
        [[bind]]
        keys = "C-c C-x C-j"
        command = "app.clock.goto"
        [[bind]]
        keys = "C-c C-e h h"
        command = "app.export.html"
        [[bind]]
        keys = "C-c C-e h o"
        command = "app.export.html-open"
        [[bind]]
        keys = "C-c C-e m m"
        command = "app.export.markdown"
        [[bind]]
        keys = "C-c C-e l p"
        command = "app.export.pdf"
        [[bind]]
        keys = "C-c C-e l l"
        command = "app.export.latex"
        [[bind]]
        keys = "C-c C-e o o"
        command = "app.export.odt"
        [[bind]]
        keys = "C-c C-e t u"
        command = "app.export.text"

        # Org
        [[bind]]
        keys = "C-c C-t"
        command = "org.todo.cycle"
        [[bind]]
        keys = "S-<right>"
        command = "org.todo.next"
        when = "heading"
        [[bind]]
        keys = "S-<left>"
        command = "org.todo.previous"
        when = "heading"
        [[bind]]
        keys = "S-<up>"
        command = "org.priority.up"
        when = "heading"
        [[bind]]
        keys = "S-<down>"
        command = "org.priority.down"
        when = "heading"
        [[bind]]
        keys = "M-<left>"
        command = "org.heading.promote"
        when = "heading"
        [[bind]]
        keys = "M-<right>"
        command = "org.heading.demote"
        when = "heading"
        [[bind]]
        keys = "M-S-<left>"
        command = "org.subtree.promote"
        when = "heading"
        [[bind]]
        keys = "M-S-<right>"
        command = "org.subtree.demote"
        when = "heading"
        [[bind]]
        keys = "M-<up>"
        command = "org.subtree.up"
        when = "heading"
        [[bind]]
        keys = "M-<down>"
        command = "org.subtree.down"
        when = "heading"
        [[bind]]
        keys = "M-RET"
        command = "org.heading.insert"
        [[bind]]
        keys = "C-RET"
        command = "org.heading.insert-after-subtree"
        [[bind]]
        keys = "M-S-RET"
        command = "org.heading.insert-todo"
        [[bind]]
        keys = "C-c C-n"
        command = "org.heading.next"
        [[bind]]
        keys = "C-c C-p"
        command = "org.heading.previous"
        [[bind]]
        keys = "C-c C-f"
        command = "org.heading.forward-same-level"
        [[bind]]
        keys = "C-c C-b"
        command = "org.heading.backward-same-level"
        [[bind]]
        keys = "C-c C-u"
        command = "org.heading.up"
        [[bind]]
        keys = "C-c C-q"
        command = "org.tags.set"
        [[bind]]
        keys = "M-RET"
        command = "org.item.insert"
        when = "item"
        [[bind]]
        keys = "M-S-RET"
        command = "org.item.insert-checkbox"
        when = "item"
        [[bind]]
        keys = "M-<left>"
        command = "org.item.outdent"
        when = "item"
        [[bind]]
        keys = "M-<right>"
        command = "org.item.indent"
        when = "item"
        [[bind]]
        keys = "M-S-<left>"
        command = "org.item.outdent-tree"
        when = "item"
        [[bind]]
        keys = "M-S-<right>"
        command = "org.item.indent-tree"
        when = "item"
        [[bind]]
        keys = "M-<up>"
        command = "org.item.up"
        when = "item"
        [[bind]]
        keys = "M-<down>"
        command = "org.item.down"
        when = "item"
        [[bind]]
        keys = "C-c C-c"
        command = "org.ctrl-c-ctrl-c"
        when = "item"
        [[bind]]
        keys = "C-c C-x C-b"
        command = "org.checkbox.toggle"
        [[bind]]
        keys = "C-c C-w"
        command = "app.refile"
        [[bind]]
        keys = "C-c C-x C-s"
        command = "app.archive"
        [[bind]]
        keys = "C-c $"
        command = "app.archive"
        [[bind]]
        keys = "C-c ."
        command = "org.timestamp.active"
        [[bind]]
        keys = "C-c !"
        command = "org.timestamp.inactive"
        [[bind]]
        keys = "C-c C-s"
        command = "org.schedule"
        [[bind]]
        keys = "C-c C-d"
        command = "org.deadline"
        [[bind]]
        keys = "M-q"
        command = "org.fill-paragraph"
        [[bind]]
        keys = "C-c C-c"
        command = "org.table.align"
        when = "table"
        [[bind]]
        keys = "C-c C-c"
        command = "org.table.recalc-all"
        when = "tblfm"
        [[bind]]
        keys = "C-c *"
        command = "org.table.recalc"
        when = "table"
        [[bind]]
        keys = "C-c C-c"
        command = "org.babel.execute"
        when = "src"
        [[bind]]
        keys = "M-<up>"
        command = "org.table.row-up"
        when = "table"
        [[bind]]
        keys = "M-<down>"
        command = "org.table.row-down"
        when = "table"
        [[bind]]
        keys = "M-<left>"
        command = "org.table.column-left"
        when = "table"
        [[bind]]
        keys = "M-<right>"
        command = "org.table.column-right"
        when = "table"
        [[bind]]
        keys = "M-S-<right>"
        command = "org.table.insert-column"
        when = "table"
        [[bind]]
        keys = "M-S-<left>"
        command = "org.table.delete-column"
        when = "table"
        [[bind]]
        keys = "M-S-<up>"
        command = "org.table.kill-row"
        when = "table"
        [[bind]]
        keys = "M-S-<down>"
        command = "org.table.insert-row"
        when = "table"
        [[bind]]
        keys = "C-c -"
        command = "org.table.insert-hline"
        when = "table"
        [[bind]]
        keys = "C-c |"
        command = "org.table.create"
        [[bind]]
        keys = "S-<up>"
        command = "org.timestamp.up"
        when = "timestamp"
        [[bind]]
        keys = "S-<down>"
        command = "org.timestamp.down"
        when = "timestamp"
        [[bind]]
        keys = "S-<right>"
        command = "org.timestamp.day-later"
        when = "timestamp"
        [[bind]]
        keys = "S-<left>"
        command = "org.timestamp.day-earlier"
        when = "timestamp"

        """

    /// Standard Mac text keys stay as they are; org commands use Control-Command chords, which
    /// macOS text editing leaves free.
    static let macBindings = """
        [[bind]]
        keys = "C-TAB"
        command = "app.buffer.next"
        [[bind]]
        keys = "C-S-TAB"
        command = "app.buffer.previous"
        [[bind]]
        keys = "C-s-t"
        command = "org.todo.cycle"
        [[bind]]
        keys = "C-s-<up>"
        command = "org.priority.up"
        [[bind]]
        keys = "C-s-<down>"
        command = "org.priority.down"
        [[bind]]
        keys = "C-s-<left>"
        command = "org.heading.promote"
        [[bind]]
        keys = "C-s-<right>"
        command = "org.heading.demote"
        [[bind]]
        keys = "C-M-s-<left>"
        command = "org.subtree.promote"
        [[bind]]
        keys = "C-M-s-<right>"
        command = "org.subtree.demote"
        [[bind]]
        keys = "C-M-s-<up>"
        command = "org.subtree.up"
        [[bind]]
        keys = "C-M-s-<down>"
        command = "org.subtree.down"
        [[bind]]
        keys = "s-RET"
        command = "org.heading.insert"
        [[bind]]
        keys = "C-s-RET"
        command = "org.heading.insert-after-subtree"
        [[bind]]
        keys = "s-S-RET"
        command = "org.heading.insert-todo"
        [[bind]]
        keys = "M-s-<down>"
        command = "org.heading.next"
        [[bind]]
        keys = "M-s-<up>"
        command = "org.heading.previous"
        [[bind]]
        keys = "C-s-q"
        command = "org.tags.set"
        [[bind]]
        keys = "s-RET"
        command = "org.item.insert"
        when = "item"
        [[bind]]
        keys = "s-S-RET"
        command = "org.item.insert-checkbox"
        when = "item"
        [[bind]]
        keys = "C-s-<left>"
        command = "org.item.outdent"
        when = "item"
        [[bind]]
        keys = "C-s-<right>"
        command = "org.item.indent"
        when = "item"
        [[bind]]
        keys = "C-M-s-<left>"
        command = "org.item.outdent-tree"
        when = "item"
        [[bind]]
        keys = "C-M-s-<right>"
        command = "org.item.indent-tree"
        when = "item"
        [[bind]]
        keys = "C-M-s-<up>"
        command = "org.item.up"
        when = "item"
        [[bind]]
        keys = "C-M-s-<down>"
        command = "org.item.down"
        when = "item"
        [[bind]]
        keys = "C-s-c"
        command = "org.checkbox.toggle"
        [[bind]]
        keys = "C-s-w"
        command = "app.refile"
        [[bind]]
        keys = "C-s-a"
        command = "app.archive"
        [[bind]]
        keys = "C-s-."
        command = "org.timestamp.active"
        [[bind]]
        keys = "C-M-s-."
        command = "org.timestamp.inactive"
        [[bind]]
        keys = "C-s-s"
        command = "org.schedule"
        [[bind]]
        keys = "C-s-d"
        command = "org.deadline"
        [[bind]]
        keys = "C-s-p"
        command = "org.fill-paragraph"
        [[bind]]
        keys = "C-s-<up>"
        command = "org.table.row-up"
        when = "table"
        [[bind]]
        keys = "C-s-<down>"
        command = "org.table.row-down"
        when = "table"
        [[bind]]
        keys = "C-s-<left>"
        command = "org.table.column-left"
        when = "table"
        [[bind]]
        keys = "C-s-<right>"
        command = "org.table.column-right"
        when = "table"
        [[bind]]
        keys = "C-M-s-<right>"
        command = "org.table.insert-column"
        when = "table"
        [[bind]]
        keys = "C-M-s-<left>"
        command = "org.table.delete-column"
        when = "table"
        [[bind]]
        keys = "C-M-s-<up>"
        command = "org.table.kill-row"
        when = "table"
        [[bind]]
        keys = "C-M-s-<down>"
        command = "org.table.insert-row"
        when = "table"
        [[bind]]
        keys = "C-s--"
        command = "org.table.insert-hline"
        when = "table"
        [[bind]]
        keys = "C-s-\\\\"
        command = "org.table.create"
        [[bind]]
        keys = "C-s-<up>"
        command = "org.timestamp.up"
        when = "timestamp"
        [[bind]]
        keys = "C-s-<down>"
        command = "org.timestamp.down"
        when = "timestamp"
        [[bind]]
        keys = "C-s-<right>"
        command = "org.timestamp.day-later"
        when = "timestamp"
        [[bind]]
        keys = "C-s-<left>"
        command = "org.timestamp.day-earlier"
        when = "timestamp"

        """
}
