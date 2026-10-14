extension KeymapPreset {
    static let macBindings = """
        [[bind]]
        keys = "C-TAB"
        command = "app.buffer.next"
        [[bind]]
        keys = "C-S-TAB"
        command = "app.buffer.previous"
        [[bind]]
        keys = "C-s-2"
        command = "app.split-below"
        [[bind]]
        keys = "C-s-3"
        command = "app.split-right"
        [[bind]]
        keys = "C-s-0"
        command = "app.pane-close"
        [[bind]]
        keys = "C-s-1"
        command = "app.pane-only"
        [[bind]]
        keys = "M-s-`"
        command = "app.pane-next"
        [[bind]]
        keys = "M-s-n"
        command = "app.window-new"
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
        keys = "C-s-g"
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
        keys = "C-s-e"
        command = "org.deadline"
        [[bind]]
        keys = "C-M-s-s"
        command = "org.schedule.remove"
        [[bind]]
        keys = "C-M-s-e"
        command = "org.deadline.remove"
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
        keys = "C-s-*"
        command = "org.table.recalc"
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

        # Act at point, links, clocking, export and the rest of C-c.
        [[bind]]
        keys = "C-s-x"
        command = "org.ctrl-c-ctrl-c"
        [[bind]]
        keys = "C-s-x"
        command = "org.dblock.update"
        when = "dblock"
        [[bind]]
        keys = "C-s-x"
        command = "org.table.recalc-all"
        when = "tblfm"
        [[bind]]
        keys = "C-s-x"
        command = "org.babel.execute"
        when = "src"
        [[bind]]
        keys = "s-k"
        command = "org.link.insert"
        [[bind]]
        keys = "s-b"
        command = "org.emphasize.bold"
        [[bind]]
        keys = "s-i"
        command = "org.emphasize.italic"
        [[bind]]
        keys = "s-u"
        command = "org.emphasize.underline"
        [[bind]]
        keys = "C-s-o"
        command = "org.link.open"
        [[bind]]
        keys = "C-s-l"
        command = "org.link.store"
        [[bind]]
        keys = "C-s-i"
        command = "app.clock.in"
        [[bind]]
        keys = "C-S-s-i"
        command = "app.clock.out"
        [[bind]]
        keys = "C-s-j"
        command = "app.clock.goto"
        [[bind]]
        keys = "C-M-s-i"
        command = "app.clock.in-recent"
        [[bind]]
        keys = "C-M-s-j"
        command = "app.clock.goto-recent"
        [[bind]]
        keys = "C-s-k"
        command = "app.clock.cancel"
        [[bind]]
        keys = "s-S-e"
        command = "app.export-dialog"
        [[bind]]
        keys = "C-s-n"
        command = "org.narrow.toggle"
        [[bind]]
        keys = "C-S-s-s"
        command = "org.sort"
        [[bind]]
        keys = "C-S-s-p"
        command = "org.property.read-and-set"
        [[bind]]
        keys = "C-S-s-f"
        command = "org.footnote.action"
        [[bind]]
        keys = "C-s-'"
        command = "org.edit-special"
        [[bind]]
        keys = "C-S-s-<right>"
        command = "org.todo.next"
        when = "heading"
        [[bind]]
        keys = "C-S-s-<left>"
        command = "org.todo.previous"
        when = "heading"
        [[bind]]
        keys = "C-S-s-<right>"
        command = "org.property.next-value"
        when = "property"
        [[bind]]
        keys = "C-S-s-<left>"
        command = "org.property.previous-value"
        when = "property"
        [[bind]]
        keys = "M-S-s-<down>"
        command = "org.heading.forward-same-level"
        [[bind]]
        keys = "M-S-s-<up>"
        command = "org.heading.backward-same-level"
        [[bind]]
        keys = "C-S-s-e"
        command = "org.effort.set"
        [[bind]]
        keys = "C-s-,"
        command = "org.priority.set"
        [[bind]]
        keys = "C-s-v"
        command = "org.babel.tangle"
        [[bind]]
        keys = "C-S-s-v"
        command = "org.babel.tangle-block"
        [[bind]]
        keys = "C-M-s-v"
        command = "org.babel.tangle-target"

        """
}
