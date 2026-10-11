#if os(iOS)
import OrgApp
import SwiftUI
import UIKit

/// An editor's panes in a scene, as a Mac window has them: one to start, split right or below
/// (`app.split-right`, `app.split-below`), each showing a buffer in its own view, with its own
/// caret and scroll, over the buffer every scene shares.
@MainActor
@Observable
final class EditorSplit {
    private(set) var layout: PaneLayout
    private(set) var panes: [PaneID: EditorPane] = [:]
    private(set) var paths: [PaneID: String] = [:]
    var focused: PaneID
    @ObservationIgnored nonisolated(unsafe) private var release: (() -> Void)?

    init(path: String, session: DocumentSession, store: MobileEditorStore) {
        let pane = session.makePane()
        layout = .pane(pane.id)
        focused = pane.id
        panes = [pane.id: pane]
        paths = [pane.id: path]
        release = { [weak self, weak session] in
            guard let self, let session else { return }
            for (id, pane) in panes {
                if let path = paths[id] { store.release(id, path: path) }
                session.closePane(pane)
            }
        }
    }

    deinit {
        guard let release else { return }
        Task { @MainActor in release() }
    }

    var isSplit: Bool { layout.panes.count > 1 }

    /// Runs a pane command; false when it does nothing here.
    func run(_ id: String, session: DocumentSession, store: MobileEditorStore) -> String? {
        switch id {
        case "app.split-right", "app.split-below":
            guard let path = paths[focused] else { return nil }
            let pane = session.makePane()
            panes[pane.id] = pane
            paths[pane.id] = path
            layout = layout.splitting(focused, axis: id == "app.split-right" ? .horizontal : .vertical, new: pane.id)
        case "app.pane-next":
            focused = layout.next(after: focused)
        case "app.pane-close":
            guard isSplit else { return "Attempt to delete the only pane" }
            close(focused, session: session, store: store)
        case "app.pane-only":
            for id in layout.panes where id != focused { close(id, session: session, store: store) }
        default:
            return nil
        }
        return nil
    }

    private func close(_ id: PaneID, session: DocumentSession, store: MobileEditorStore) {
        guard let rest = layout.removing(id) else { return }
        let next = layout.next(after: id)
        layout = rest
        if let path = paths[id] { store.release(id, path: path) }
        if let pane = panes[id] { session.closePane(pane) }
        panes[id] = nil
        paths[id] = nil
        if focused == id { focused = next }
    }
}

/// The editor route's screen: its panes, with the focused one's title and toolbar.
struct EditorSplitScreen: View {
    let path: String
    let offset: Int?
    let workspace: WorkspaceModel
    let session: DocumentSession
    @State private var split: EditorSplit?
    @State private var message: String?
    @Environment(MobileModel.self) private var model

    var body: some View {
        Group {
            if let split {
                layoutView(split.layout, split: split)
                    .navigationTitle(split.paths[split.focused].map { session.bufferName($0) + (session.dirtyPaths.contains($0) ? " •" : "") } ?? "")
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if split == nil { split = EditorSplit(path: path, session: session, store: model.editors) }
        }
    }

    private func layoutView(_ layout: PaneLayout, split: EditorSplit) -> AnyView {
        switch layout {
        case .pane(let id):
            guard let pane = split.panes[id], let file = split.paths[id] else { return AnyView(EmptyView()) }
            return AnyView(
                EditorScreen(
                    path: file, offset: id == split.layout.panes.first ? offset : nil, workspace: workspace, session: session,
                    givenPane: pane, inSplit: split.isSplit, isFocused: split.focused == id,
                    onFocus: { split.focused = id },
                    onPaneCommand: { command in _ = split.run(command, session: session, store: model.editors) }
                )
                .id(id)
                .overlay(alignment: .top) {
                    if split.isSplit, split.focused == id { Rectangle().fill(Color.accentColor).frame(height: 2) }
                }
            )
        case .split(let axis, let first, let second, _):
            if axis == .horizontal {
                return AnyView(HStack(spacing: 0) {
                    layoutView(first, split: split)
                    Divider()
                    layoutView(second, split: split)
                })
            }
            return AnyView(VStack(spacing: 0) {
                layoutView(first, split: split)
                Divider()
                layoutView(second, split: split)
            })
        }
    }
}
#endif
