import Foundation
import OrgApp

/// One editor window's panes: how they divide the window and which has focus. The panes
/// themselves belong to the session, which keeps them in step with the buffers.
@MainActor
@Observable
final class WindowModel: Identifiable {
    let id = UUID()
    let session: DocumentSession
    private(set) var layout: PaneLayout
    private(set) var panes: [PaneID: EditorPane]
    var focused: PaneID

    /// A window around `pane`, which the session already has.
    init(session: DocumentSession, pane: EditorPane) {
        self.session = session
        layout = .pane(pane.id)
        panes = [pane.id: pane]
        focused = pane.id
    }

    func pane(_ id: PaneID) -> EditorPane? { panes[id] }
    var focusedPane: EditorPane { panes[focused] ?? panes[layout.panes[0]] ?? panes.values.first ?? session.focused }
    var paneCount: Int { layout.panes.count }

    /// A new pane after the focused one, showing the same buffer, as `split-window` does. The
    /// focus stays where it was.
    @discardableResult
    func split(_ axis: PaneLayout.Axis) -> EditorPane {
        let current = focusedPane
        let pane = session.makePane()
        panes[pane.id] = pane
        layout = layout.splitting(current.id, axis: axis, new: pane.id)
        if let path = current.path { session.open(path, in: pane) }
        return pane
    }

    /// Removes `id` from the window; its buffers stay open. The only pane stays.
    func close(_ id: PaneID) {
        guard let pane = panes[id], let rest = layout.removing(id) else { return }
        layout = rest
        panes[id] = nil
        session.closePane(pane)
        if focused == id { focus(rest.panes[0]) }
    }

    /// Closes `path`'s tab in `pane`, or the empty pane when `path` is nil. With other panes in
    /// the window and no other tab here, the pane closes too, and the buffer closes only if no
    /// other pane shows it. False when unsaved changes kept it open.
    @discardableResult
    func closeTab(_ path: String?, in pane: EditorPane, commands: AppCommands) -> Bool {
        let closesPane = paneCount > 1 && pane.shown.allSatisfy { $0 == path }
        let elsewhere = path.map { path in session.panes.contains { $0 !== pane && $0.shown.contains(path) } } ?? true
        if let path, !(closesPane && elsewhere) {
            guard UnsavedChanges.resolve(session, paths: [path]) else { return false }
        }
        if closesPane {
            commands.store.releasePane(pane.id)
            close(pane.id)
            activate(commands)
        }
        if let path, !(closesPane && elsewhere) { session.kill(path) }
        return true
    }

    /// Gives the focused pane's text view the keyboard, after a pane command moved the focus.
    func activate(_ commands: AppCommands) {
        let pane = focusedPane
        session.focused = pane
        if let path = pane.path, let textView = commands.store.textView(for: pane.id, path: path) {
            textView.window?.makeFirstResponder(textView)
            commands.editor = commands.store.editor(for: path)
        } else {
            commands.editor = nil
        }
    }

    /// Removes every pane but the focused one.
    func closeOthers() {
        for id in layout.panes where id != focused { close(id) }
    }

    /// Focuses the pane after the focused one in reading order, wrapping.
    func focusNext() {
        focus(layout.next(after: focused))
    }

    func focus(_ id: PaneID) {
        guard let pane = panes[id] else { return }
        focused = id
        session.focused = pane
    }

    func setFraction(_ fraction: Double, ofSplitBetween before: PaneID, and after: PaneID) {
        layout = layout.settingFraction(fraction, ofSplitBetween: before, and: after)
    }

    /// Takes every pane out of the session, as the window closes. The panes stay listed here
    /// so views still on screen can read them.
    func closeAll() {
        for pane in panes.values { session.closePane(pane) }
    }
}
