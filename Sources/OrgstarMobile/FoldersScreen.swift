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
                    let files = workspace.files.filter { $0.root == root && $0.kind == .org }
                    ForEach(files) { file in
                        NavigationLink(value: ReaderRoute.file(file.path)) {
                            Label(file.relativePath, systemImage: "doc.text")
                        }
                    }
                    let pending = workspace.downloading.filter { $0.hasPrefix(root + "/") }.sorted()
                    ForEach(pending, id: \.self) { path in
                        Label(String(path.dropFirst(root.count + 1)), systemImage: "icloud.and.arrow.down")
                            .foregroundStyle(.secondary)
                    }
                    Button("Remove Folder", role: .destructive) { try? workspace.removeRoot(path: root) }
                }
            }
            if let error = workspace.lastError {
                Text(error).foregroundStyle(.red)
            }
        }
        .navigationTitle("Folders")
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
#endif
