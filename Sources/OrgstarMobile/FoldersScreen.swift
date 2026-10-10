#if os(iOS)
import OrgApp
import SwiftUI
import UniformTypeIdentifiers

/// The folders of org files the agenda reads, and their files.
struct FoldersScreen: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    @State private var importing = false
    /// The file whose deletion is being confirmed.
    @State private var deleting: String?

    var body: some View {
        List {
            ForEach(workspace.rootPaths, id: \.self) { root in
                Section((root as NSString).lastPathComponent) {
                    FolderContents(workspace: workspace, root: root, folder: "", deleting: $deleting)
                    Button("Remove Folder", role: .destructive) { try? workspace.removeRoot(path: root) }
                }
            }
            if let error = workspace.lastError {
                Text(error).foregroundStyle(.red)
            }
        }
        .navigationTitle("Folders")
        .navigationDestination(for: FolderRoute.self) { route in
            FolderPage(workspace: workspace, session: session, route: route)
        }
        .confirmDeletion($deleting, workspace: workspace, session: session)
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
/// A subfolder's own list, asking about its own deletions.
private struct FolderPage: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    let route: FolderRoute
    @State private var deleting: String?

    var body: some View {
        List { FolderContents(workspace: workspace, root: route.root, folder: route.folder, deleting: $deleting) }
            .navigationTitle((route.folder as NSString).lastPathComponent)
            .confirmDeletion($deleting, workspace: workspace, session: session)
    }
}

private extension View {
    /// Asks before deleting the file in `deleting`, closing it first.
    func confirmDeletion(_ deleting: Binding<String?>, workspace: WorkspaceModel, session: DocumentSession) -> some View {
        let name = deleting.wrappedValue.map { ($0 as NSString).lastPathComponent } ?? ""
        return confirmationDialog("Delete “\(name)”?", isPresented: Binding { deleting.wrappedValue != nil } set: { if !$0 { deleting.wrappedValue = nil } },
                                  titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let path = deleting.wrappedValue else { return }
                deleting.wrappedValue = nil
                session.kill(path)
                Task {
                    do { try await workspace.trash(path) } catch { workspace.lastError = "Can't delete \(name): \(error.localizedDescription)" }
                }
            }
        } message: {
            Text("The whole file is removed. Files in iCloud Drive go to Recently Deleted in the Files app.")
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
    @Binding var deleting: String?

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
            .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash") { deleting = file.path }.tint(.red)
            }
            .contextMenu {
                Button("Delete…", systemImage: "trash", role: .destructive) { deleting = file.path }
            }
        }
        ForEach(pending.filter { !$0.contains("/") }, id: \.self) { name in
            Label(name, systemImage: "icloud.and.arrow.down").foregroundStyle(.secondary)
        }
    }
}
#endif
