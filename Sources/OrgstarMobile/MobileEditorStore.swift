#if os(iOS)
import OrgApp
import UIKit

/// The editors of the open buffers and the text views the panes show them in, across every
/// scene: one `MobileEditor` per file, one text view per pane that shows it.
@MainActor
final class MobileEditorStore {
    private var editors: [String: MobileEditor] = [:]
    /// The pane each text view belongs to.
    private var owners: [ObjectIdentifier: PaneID] = [:]

    /// The editor of `path`, made with `make` when there's none or the session's buffer for the
    /// file is no longer it (the file was closed and opened again).
    func editor(for path: String, session: DocumentSession, make: () -> MobileEditor?) -> MobileEditor? {
        if let editor = editors[path], session.isAttached(editor, for: path) { return editor }
        if let old = editors[path] { for view in old.textViews { owners[ObjectIdentifier(view)] = nil } }
        guard let made = make() else { return nil }
        editors[path] = made
        session.attach(made, for: path)
        return made
    }

    /// The text view `pane` shows `editor` in: one no other pane owns, else a new one.
    func view(for pane: PaneID, of editor: MobileEditor) -> UITextView {
        if let owned = editor.textViews.first(where: { owners[ObjectIdentifier($0)] == pane }) { return owned }
        let view = editor.textViews.first { owners[ObjectIdentifier($0)] == nil } ?? editor.addView()
        owners[ObjectIdentifier(view)] = pane
        return view
    }

    /// `pane` no longer shows `path`: its view goes, or is left free when it's the editor's
    /// first, which stays with the editor.
    func release(_ pane: PaneID, path: String) {
        guard let editor = editors[path] else { return }
        for view in editor.textViews where owners[ObjectIdentifier(view)] == pane {
            owners[ObjectIdentifier(view)] = nil
            editor.removeView(view)
        }
    }

    /// The editors of files the session no longer has open go.
    func prune(_ session: DocumentSession) {
        for (path, editor) in editors where !session.isAttached(editor, for: path) {
            for view in editor.textViews { owners[ObjectIdentifier(view)] = nil }
            editors[path] = nil
        }
    }
}
#endif
