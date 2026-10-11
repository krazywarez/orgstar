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
    var focusedPane: EditorPane { panes[focused] ?? panes[layout.panes[0]]! }
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

    func setFraction(_ fraction: Double, ofSplitStartingWith id: PaneID) {
        layout = layout.settingFraction(fraction, ofSplitStartingWith: id)
    }

    /// Takes every pane out of the session, as the window closes.
    func closeAll() {
        for pane in panes.values { session.closePane(pane) }
        panes = [:]
    }
}
