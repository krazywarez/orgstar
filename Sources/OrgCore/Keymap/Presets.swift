/// The keymaps the app ships. The user's `keymap.toml` is layered on top of the chosen one.
public enum KeymapPreset: String, Sendable, CaseIterable {
    case emacs, mac

    public var title: String {
        switch self {
        case .emacs: "Emacs"
        case .mac: "Mac"
        }
    }

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
        }
    }

    static let common = """
        [[bind]]
        keys = "TAB"
        command = "org.cycle"
        when = "heading"

        [[bind]]
        keys = "S-TAB"
        command = "org.cycle-global"

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
        keys = "C-x C-x"
        command = "edit.exchange-point-and-mark"
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

        # Files and commands
        [[bind]]
        keys = "C-x C-s"
        command = "app.save"
        [[bind]]
        keys = "C-x C-f"
        command = "app.quick-open"
        [[bind]]
        keys = "C-x b"
        command = "app.quick-open"
        [[bind]]
        keys = "M-x"
        command = "app.palette"

        # Org
        [[bind]]
        keys = "C-c C-t"
        command = "org.todo.cycle"
        [[bind]]
        keys = "S-<right>"
        command = "org.todo.cycle"
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

        """

    /// Standard Mac text keys stay as they are; org commands use Control-Command chords, which
    /// macOS text editing leaves free.
    static let macBindings = """
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

        """
}
