import AppKit
import OrgApp
import SwiftUI

/// Creating, renaming and trashing files from the sidebar.
enum FileOperation: Equatable {
    case create(folder: String)
    case rename(path: String)
    case trash(path: String)
}

extension Sidebar {
    @ViewBuilder
    func fileMenu(_ node: FileTreeNode) -> some View {
        let folder = node.file == nil ? node.path : (node.path as NSString).deletingLastPathComponent
        Button("New File…") { ask(.create(folder: folder)) }
        Divider()
        Button("Rename…") { ask(.rename(path: node.path)) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)]) }
        Divider()
        Button("Move to Trash…") { ask(.trash(path: node.path)) }
    }

    func ask(_ operation: FileOperation) {
        switch operation {
        case .create: name = ""
        case .rename(let path): name = (path as NSString).lastPathComponent
        case .trash: break
        }
        pending = operation
    }

    /// The open buffers of `path`, a file or a folder holding them.
    func openFiles(under path: String) -> [String] {
        session.openPaths.filter { $0 == path || $0.hasPrefix(path + "/") }
    }

    /// Whether `path` is an open file or a folder holding one.
    func holdsOpenFile(_ path: String) -> Bool { !openFiles(under: path).isEmpty }

    func finish() {
        guard let operation = pending else { return }
        pending = nil
        Task {
            do {
                switch operation {
                case .create(let folder):
                    selection = try await workspace.createFile(named: name, in: folder)
                case .rename(let path):
                    let affected = openFiles(under: path)
                    // Open files are saved first, so the rename carries their edits, and open
                    // again under their new paths.
                    if !UnsavedChanges.resolve(session, paths: affected) { return }
                    let shown = session.path
                    let renamed = try await workspace.rename(path, to: name)
                    for open in affected {
                        session.kill(open)
                        session.open(renamed + open.dropFirst(path.count))
                    }
                    if let shown, affected.contains(shown) {
                        let moved = renamed + shown.dropFirst(path.count)
                        session.open(moved)
                        selection = moved
                    } else if let shown {
                        session.open(shown)
                    }
                case .trash(let path):
                    for open in openFiles(under: path) { session.kill(open) }
                    if session.path == nil { selection = nil }
                    try await workspace.trash(path)
                }
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

extension View {
    func fileOperations(_ sidebar: Sidebar) -> some View {
        let names: Binding<String> = sidebar.$name
        return self
            .alert(title(sidebar.pending), isPresented: Binding { sidebar.pending?.needsName == true } set: { if !$0 { sidebar.pending = nil } }) {
                TextField("Name", text: names)
                Button(sidebar.pending.map { if case .create = $0 { "Create" } else { "Rename" } } ?? "OK") { sidebar.finish() }
                Button("Cancel", role: .cancel) { sidebar.pending = nil }
            } message: {
                if case .create = sidebar.pending { Text("A name without an extension gets .org. Use folder/name to make folders.") }
            }
            .confirmationDialog(title(sidebar.pending), isPresented: Binding { sidebar.pending?.needsName == false } set: { if !$0 { sidebar.pending = nil } }) {
                Button("Move to Trash", role: .destructive) { sidebar.finish() }
            } message: {
                if case .trash(let path) = sidebar.pending, sidebar.holdsOpenFile(path), sidebar.session.isDirty {
                    Text("Unsaved changes to the open file will be lost.")
                } else {
                    Text("You can put it back from the Trash in Finder.")
                }
            }
            .alert("Couldn't change the file", isPresented: Binding { sidebar.failure != nil } set: { if !$0 { sidebar.failure = nil } }) {
                Button("OK") { sidebar.failure = nil }
            } message: {
                Text(sidebar.failure ?? "")
            }
    }

    private func title(_ operation: FileOperation?) -> String {
        switch operation {
        case .create(let folder): "New file in “\((folder as NSString).lastPathComponent)”"
        case .rename(let path): "Rename “\((path as NSString).lastPathComponent)”"
        case .trash(let path): "Move “\((path as NSString).lastPathComponent)” to the Trash?"
        case nil: ""
        }
    }
}

extension FileOperation {
    var needsName: Bool {
        if case .trash = self { return false }
        return true
    }
}
