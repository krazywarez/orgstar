#if os(iOS)
import OrgApp
import SwiftUI
import UniformTypeIdentifiers

/// The folders of org files the agenda reads, and their files.
struct FoldersScreen: View {
    let workspace: WorkspaceModel
    @State private var importing = false

    var body: some View {
        List {
            ForEach(workspace.rootPaths, id: \.self) { root in
                Section((root as NSString).lastPathComponent) {
                    FolderContents(workspace: workspace, root: root, folder: "")
                    Button("Remove Folder", role: .destructive) { try? workspace.removeRoot(path: root) }
                }
            }
            if let error = workspace.lastError {
                Text(error).foregroundStyle(.red)
            }
        }
        .navigationTitle("Folders")
        .navigationDestination(for: FolderRoute.self) { route in
            List { FolderContents(workspace: workspace, root: route.root, folder: route.folder) }
                .navigationTitle((route.folder as NSString).lastPathComponent)
        }
        .overlay {
            if workspace.rootPaths.isEmpty {
                ContentUnavailableView {
                    Label("No folders", systemImage: "folder")
                } description: {
                    Text("Add the folder your org files are in, from iCloud Drive or another app's storage.")
                } actions: {
                    Button("Add Folder") { importing = true }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Add Folder", systemImage: "folder.badge.plus") { importing = true }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            // Kept for the bookmark; WorkspaceRoot resolves it with access again at launch.
            _ = url.startAccessingSecurityScopedResource()
            Task {
                do {
                    try await workspace.addRoot(url)
                } catch {
                    workspace.lastError = "Can't add \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }
}
/// A subfolder to show, relative to its root.
struct FolderRoute: Hashable {
    let root: String
    let folder: String
}

/// One folder's subfolders, which open their own contents, then its org files and the files
/// still downloading into it. `folder` is relative to `root`, empty for the root itself.
private struct FolderContents: View {
    let workspace: WorkspaceModel
    let root: String
    let folder: String

    private var prefix: String { folder.isEmpty ? "" : folder + "/" }

    /// Paths below this folder, relative to it.
    private func below(_ relativePaths: [String]) -> [String] {
        relativePaths.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    var body: some View {
        let files = workspace.files.filter { $0.root == root && $0.kind == .org && $0.relativePath.hasPrefix(prefix) }
        let pending = below(workspace.downloading.filter { $0.hasPrefix(root + "/") }.map { String($0.dropFirst(root.count + 1)) })
        let subfolders = Set((below(files.map(\.relativePath)) + pending).compactMap { path in
            path.firstIndex(of: "/").map { String(path[..<$0]) }
        }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        ForEach(subfolders, id: \.self) { name in
            // A value, as the files' links are: a stack mixing the two kinds pushes wrongly.
            NavigationLink(value: FolderRoute(root: root, folder: prefix + name)) {
                Label(name, systemImage: "folder")
            }
        }
        ForEach(files.filter { !$0.relativePath.dropFirst(prefix.count).contains("/") }) { file in
            NavigationLink(value: ReaderRoute.file(file.path)) {
                Label(file.name, systemImage: "doc.text")
            }
        }
        ForEach(pending.filter { !$0.contains("/") }, id: \.self) { name in
            Label(name, systemImage: "icloud.and.arrow.down").foregroundStyle(.secondary)
        }
    }
}
#endif
