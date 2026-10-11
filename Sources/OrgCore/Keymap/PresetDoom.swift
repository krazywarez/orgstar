extension KeymapPreset {
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
                || keys == "M-x" || keys == "M-q"
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
        [[bind]]
        keys = "SPC t s"
        command = "editor.toggle-spell-check"
        mode = "normal"
        [[bind]]
        keys = "SPC t w"
        command = "editor.toggle-truncate-lines"
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
        keys = "SPC m s n"
        command = "org.narrow.subtree"
        mode = "normal"
        [[bind]]
        keys = "SPC m s s"
        command = "org.sparse-tree"
        mode = "normal"
        [[bind]]
        keys = "SPC m s N"
        command = "org.widen"
        mode = "normal"
        [[bind]]
        keys = "SPC m ."
        command = "org.goto"
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
        keys = "SPC m s a"
        command = "org.archive.toggle-tag"
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
        keys = "SPC m c G"
        command = "app.clock.goto-recent"
        mode = "normal"
        [[bind]]
        keys = "SPC m c I"
        command = "app.clock.in-last"
        mode = "normal"
        [[bind]]
        keys = "SPC m c d"
        command = "app.clock.default"
        mode = "normal"
        [[bind]]
        keys = "SPC m c r"
        command = "app.clock.resolve"
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
        keys = "SPC m p p"
        command = "org.priority.set"
        mode = "normal"
        [[bind]]
        keys = "SPC m o"
        command = "org.property.read-and-set"
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
        command = "org.fold.toggle"
        mode = "normal"
        [[bind]]
        keys = "z c"
        command = "org.fold.close"
        mode = "normal"
        [[bind]]
        keys = "z o"
        command = "org.fold.open"
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

        # Doom's corfu: completion-at-point in insert state.
        [[bind]]
        keys = "C-SPC"
        command = "editor.complete"
        mode = "insert"
        [[bind]]
        keys = "C-@"
        command = "editor.complete"
        mode = "insert"

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
}
