import AppKit
import OrgApp
import OrgEditorAppKit

/// The editors of the open buffers and the text views the panes show them in, across every
/// window: one `OrgEditor` per file, one text view per pane that shows it.
@MainActor
final class EditorStore {
    /// The editor of each open file.
    private(set) var editors: [String: OrgEditor] = [:]
    /// Each pane's text view per file, with its scroll view, kept while the pane shows
    /// another buffer so its caret and scroll position stay.
    private(set) var views: [PaneID: [String: (scroll: NSScrollView, textView: NSTextView)]] = [:]
    /// The pane each text view belongs to.
    private var paneOf: [ObjectIdentifier: EditorPane] = [:]
    /// The pane using an editor's first text view, which can't be removed from the editor.
    private var primaryOwner: [String: PaneID] = [:]
    /// The editor windows, for the pane commands.
    var windows: [WindowModel] = []

    func editor(for path: String) -> OrgEditor? { editors[path] }

    func pane(of textView: NSTextView) -> EditorPane? { paneOf[ObjectIdentifier(textView)] }

    func window(of pane: PaneID) -> WindowModel? { windows.first { $0.pane(pane) != nil } }

    /// The text view `pane` shows `path` in, made with `make` the first time.
    func view(for pane: EditorPane, path: String, make: () -> OrgEditor?) -> (editor: OrgEditor, scroll: NSScrollView, textView: NSTextView)? {
        let editor: OrgEditor
        if let existing = editors[path] {
            editor = existing
        } else {
            guard let made = make() else { return nil }
            editors[path] = made
            editor = made
        }
        if let shown = views[pane.id]?[path] { return (editor, shown.scroll, shown.textView) }
        let textView: NSTextView
        if primaryOwner[path] == nil {
            primaryOwner[path] = pane.id
            textView = editor.textViews[0]
        } else {
            textView = editor.addView()
        }
        let scroll = editor.makeScrollView(for: textView)
        scroll.autoresizingMask = [.width, .height]
        views[pane.id, default: [:]][path] = (scroll, textView)
        paneOf[ObjectIdentifier(textView)] = pane
        return (editor, scroll, textView)
    }

    /// The text view `pane` shows `path` in, if it has one.
    func textView(for pane: PaneID, path: String) -> NSTextView? { views[pane]?[path]?.textView }

    /// Drops `pane`'s text views; its buffers stay.
    func releasePane(_ pane: PaneID) {
        for (path, shown) in views[pane] ?? [:] { drop(shown, path: path, pane: pane) }
        views[pane] = nil
    }

    /// Drops every text view of `path` and its editor, as the buffer closes.
    func releasePath(_ path: String) {
        for pane in views.keys {
            if let shown = views[pane]?[path] { drop(shown, path: path, pane: pane) }
            views[pane]?[path] = nil
        }
        editors[path] = nil
        primaryOwner[path] = nil
    }

    private func drop(_ shown: (scroll: NSScrollView, textView: NSTextView), path: String, pane: PaneID) {
        shown.scroll.removeFromSuperview()
        paneOf[ObjectIdentifier(shown.textView)] = nil
        if primaryOwner[path] == pane {
            primaryOwner[path] = nil
        } else {
            editors[path]?.removeView(shown.textView)
        }
    }
}
