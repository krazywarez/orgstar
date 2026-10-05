#if os(macOS)
import AppKit
import OrgCore

/// Every command a key, menu or the palette can run, by id.
public struct EditorCommand: Sendable {
    public enum Action: Sendable {
        /// An `OrgCore` command, run through `OrgEditor.perform`.
        case text(any OrgCommand)
        /// Folding and other view changes the editor makes itself.
        case view
        /// A text-system action; `extending` is its variant that extends the selection, used
        /// while a mark is active.
        case edit(selector: String, extending: String? = nil)
        /// Mark handling in the editor.
        case mark
        /// The find bar.
        case find(NSTextFinder.Action)
        /// Handled by the app (save, quick open, palette).
        case app
    }

    public let id: String
    public let title: String
    public let action: Action

    /// Shown in the palette; text-system movement and editing are left to keys.
    public var inPalette: Bool {
        switch action {
        case .edit, .mark: false
        default: true
        }
    }
}

public enum EditorCommands {
    public static let all: [EditorCommand] = Commands.everything.map { EditorCommand(id: $0.id, title: $0.title, action: .text($0)) } + [
        EditorCommand(id: "org.cycle", title: "Cycle Visibility", action: .view),
        EditorCommand(id: "org.cycle-global", title: "Cycle Global Visibility", action: .view),

        EditorCommand(id: "app.save", title: "Save", action: .app),
        EditorCommand(id: "app.quit", title: "Quit Orgstar", action: .app),
        EditorCommand(id: "app.toggle-outline", title: "Show or Hide Outline", action: .app),
        EditorCommand(id: "app.toggle-markup", title: "Show or Hide Markup", action: .app),
        EditorCommand(id: "app.quick-open", title: "Quick Open…", action: .app),
        EditorCommand(id: "app.palette", title: "Command Palette…", action: .app),
        EditorCommand(id: "app.search", title: "Search Notes", action: .app),
        EditorCommand(id: "app.reload-keymap", title: "Reload Keymap", action: .app),
        EditorCommand(id: "app.refile", title: "Refile…", action: .app),
        EditorCommand(id: "app.archive", title: "Archive Subtree", action: .app),
        EditorCommand(id: "app.agenda", title: "Agenda", action: .app),
        EditorCommand(id: "app.capture", title: "Capture…", action: .app),
        EditorCommand(id: "app.board", title: "Board", action: .app),
        EditorCommand(id: "app.clock.in", title: "Clock In", action: .app),
        EditorCommand(id: "app.clock.out", title: "Clock Out", action: .app),
        EditorCommand(id: "app.clock.cancel", title: "Cancel Clock", action: .app),
        EditorCommand(id: "app.clock.goto", title: "Go to Clocked Entry", action: .app),
        EditorCommand(id: "app.clock.report", title: "Clock Report", action: .app),
        EditorCommand(id: "app.export.html", title: "Export to HTML", action: .app),
        EditorCommand(id: "app.export.html-open", title: "Export to HTML and Open", action: .app),
        EditorCommand(id: "app.export.markdown", title: "Export to Markdown", action: .app),
        EditorCommand(id: "app.export.pdf", title: "Export to PDF with Emacs", action: .app),
        EditorCommand(id: "app.export.odt", title: "Export to ODT with Emacs", action: .app),
        EditorCommand(id: "app.export.latex", title: "Export to LaTeX with Emacs", action: .app),
        EditorCommand(id: "app.export.text", title: "Export to Plain Text with Emacs", action: .app),

        movement("forward-char", "Forward Character", "moveForward:"),
        movement("backward-char", "Backward Character", "moveBackward:"),
        movement("next-line", "Next Line", "moveDown:"),
        movement("previous-line", "Previous Line", "moveUp:"),
        movement("beginning-of-line", "Beginning of Line", "moveToBeginningOfParagraph:"),
        movement("end-of-line", "End of Line", "moveToEndOfParagraph:"),
        movement("forward-word", "Forward Word", "moveWordForward:"),
        movement("backward-word", "Backward Word", "moveWordBackward:"),
        movement("beginning-of-buffer", "Beginning of Buffer", "moveToBeginningOfDocument:"),
        movement("end-of-buffer", "End of Buffer", "moveToEndOfDocument:"),
        movement("scroll-up", "Scroll Up", "pageDown:"),
        movement("scroll-down", "Scroll Down", "pageUp:"),
        edit("recenter", "Recenter", "centerSelectionInVisibleArea:"),
        edit("delete-char", "Delete Character", "deleteForward:"),
        edit("kill-word", "Kill Word", "deleteWordForward:"),
        edit("backward-kill-word", "Kill Word Backward", "deleteWordBackward:"),
        edit("kill-line", "Kill Line", "deleteToEndOfParagraph:"),
        edit("yank", "Yank", "yank:"),
        edit("select-all", "Select All", "selectAll:"),
        edit("kill-region", "Kill Region", "cut:"),
        edit("copy-region", "Copy Region", "copy:"),
        edit("undo", "Undo", "undo:"),
        edit("transpose-chars", "Transpose Characters", "transpose:"),
        EditorCommand(id: "edit.find", title: "Find", action: .find(.showFindInterface)),
        EditorCommand(id: "edit.replace", title: "Find and Replace", action: .find(.showReplaceInterface)),
        EditorCommand(id: "edit.find-next", title: "Find Next", action: .find(.nextMatch)),
        EditorCommand(id: "edit.find-previous", title: "Find Previous", action: .find(.previousMatch)),
        EditorCommand(id: "edit.use-selection-for-find", title: "Use Selection for Find", action: .find(.setSearchString)),
        EditorCommand(id: "edit.set-mark", title: "Set Mark", action: .mark),
        EditorCommand(id: "edit.keyboard-quit", title: "Quit", action: .mark),
    ]

    private static func movement(_ name: String, _ title: String, _ selector: String) -> EditorCommand {
        let extending = String(selector.dropLast()) + "AndModifySelection:"
        return EditorCommand(id: "edit.\(name)", title: title, action: .edit(selector: selector, extending: extending))
    }

    private static func edit(_ name: String, _ title: String, _ selector: String) -> EditorCommand {
        EditorCommand(id: "edit.\(name)", title: title, action: .edit(selector: selector))
    }

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func command(_ id: String) -> EditorCommand? { byID[id] }
}
#endif
