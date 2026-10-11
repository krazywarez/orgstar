extension KeymapPreset {
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
        keys = "C-M-i"
        command = "editor.complete"
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
        keys = "C-c C-y"
        command = "org.timestamp.evaluate-range"
        [[bind]]
        keys = "C-c C-x f"
        command = "org.footnote.action"
        [[bind]]
        keys = "C-c ="
        command = "org.table.column-formula"
        [[bind]]
        keys = "C-c TAB"
        command = "org.table.toggle-column-width"
        when = "table"
        [[bind]]
        keys = "C-x n s"
        command = "org.narrow.subtree"
        [[bind]]
        keys = "C-x n b"
        command = "org.narrow.block"
        [[bind]]
        keys = "C-x n w"
        command = "org.widen"
        [[bind]]
        keys = "C-x x t"
        command = "editor.toggle-truncate-lines"
        [[bind]]
        keys = "C-c C-j"
        command = "org.goto"
        [[bind]]
        keys = "C-c /"
        command = "org.sparse-tree"
        [[bind]]
        keys = "C-c ,"
        command = "org.priority.set"
        [[bind]]
        keys = "C-c C-x p"
        command = "org.property.read-and-set"
        [[bind]]
        keys = "C-c C-x i"
        command = "org.columns.insert-dblock"
        [[bind]]
        keys = "C-c C-x a"
        command = "org.archive.toggle-tag"
        [[bind]]
        keys = "C-c C-x A"
        command = "org.archive.to-sibling"
        [[bind]]
        keys = "C-c C-x o"
        command = "org.property.toggle-ordered"
        [[bind]]
        keys = "C-c C-x C-v"
        command = "org.toggle-inline-images"
        [[bind]]
        keys = "C-c C-x C-l"
        command = "org.latex-preview"
        [[bind]]
        keys = "C-c \\" g"
        command = "app.plot"
        [[bind]]
        keys = "C-c C-x C-c"
        command = "org.columns"
        [[bind]]
        keys = "S-<right>"
        command = "org.item.bullet-next"
        when = "item"
        [[bind]]
        keys = "S-<left>"
        command = "org.item.bullet-previous"
        when = "item"
        [[bind]]
        keys = "C-c C-x d"
        command = "org.drawer.insert"
        [[bind]]
        keys = "M-<up>"
        command = "org.element.drag-backward"
        [[bind]]
        keys = "M-<down>"
        command = "org.element.drag-forward"
        [[bind]]
        keys = "S-<right>"
        command = "org.property.next-value"
        when = "property"
        [[bind]]
        keys = "S-<left>"
        command = "org.property.previous-value"
        when = "property"
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
        keys = "C-c C-v t"
        command = "org.babel.tangle"
        [[bind]]
        keys = "C-c C-v C-t"
        command = "org.babel.tangle"
        [[bind]]
        keys = "C-c `"
        command = "org.table.edit-field"
        when = "table"
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
        keys = "C-x 2"
        command = "app.split-below"
        [[bind]]
        keys = "C-x 3"
        command = "app.split-right"
        [[bind]]
        keys = "C-x 0"
        command = "app.pane-close"
        [[bind]]
        keys = "C-x 1"
        command = "app.pane-only"
        [[bind]]
        keys = "C-x o"
        command = "app.pane-next"
        [[bind]]
        keys = "C-x 5 2"
        command = "app.window-new"
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
        keys = "C-c C-x C-x"
        command = "app.clock.in-last"
        [[bind]]
        keys = "C-c C-x C-z"
        command = "app.clock.resolve"
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
        [[bind]]
        keys = "C-c C-e c f"
        command = "app.export.icalendar"
        [[bind]]
        keys = "C-c C-e c a"
        command = "app.export.icalendar-agenda"
        [[bind]]
        keys = "C-c C-e c c"
        command = "app.export.icalendar-combined"
        [[bind]]
        keys = "C-c C-e P x"
        command = "app.publish"
        [[bind]]
        keys = "C-c C-e P a"
        command = "app.publish.all"
        [[bind]]
        keys = "C-c C-e P f"
        command = "app.publish.current-file"
        [[bind]]
        keys = "C-c C-e P p"
        command = "app.publish.current-project"

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
        keys = "C-u C-c C-w"
        command = "app.refile.goto"
        [[bind]]
        keys = "C-c M-w"
        command = "app.refile.copy"
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
        command = "org.ctrl-c-ctrl-c"
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
}
