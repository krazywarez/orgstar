import OrgApp
import OrgIndex
import SwiftUI

struct ContentView: View {
    let workspace: WorkspaceModel
    @Bindable var commands: AppCommands
    @State private var session = DocumentSession()
    @State private var selectedFile: String?
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            Sidebar(workspace: workspace, selection: $selectedFile)
                .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } content: {
            Group {
                if query.isEmpty {
                    OutlineColumn(session: session)
                } else {
                    SearchResults(results: workspace.search(query)) { location in
                        selectedFile = location.path
                        session.show(location)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 220, max: 360)
        } detail: {
            if session.document != nil {
                EditorView(session: session)
            } else {
                ContentUnavailableView(
                    workspace.roots.isEmpty ? "Add a folder of org files" : "Choose a file",
                    systemImage: "doc.text",
                    description: Text(workspace.roots.isEmpty ? "File ▸ Add Folder… (⇧⌘O)" : "Or press ⌘P to open one by name.")
                )
            }
        }
        .navigationTitle(session.path.map { ($0 as NSString).lastPathComponent } ?? "Orgstar")
        .searchable(text: $query, placement: .toolbar, prompt: "Search notes")
        .searchFocused($searchFocused)
        .toolbar {
            if workspace.isIndexing { ProgressView().controlSize(.small) }
        }
        .onChange(of: selectedFile) { _, path in
            if let path, path != session.path { session.open(path) }
        }
        .onChange(of: workspace.changedFile?.version) {
            if let path = workspace.changedFile?.path { session.fileChanged(path) }
        }
        .onChange(of: commands.focusSearch) { _, focus in
            if focus {
                searchFocused = true
                commands.focusSearch = false
            }
        }
        .fileImporter(isPresented: $commands.showingFolderPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task {
                do { try await workspace.addRoot(url) } catch { workspace.lastError = error.localizedDescription }
            }
        }
        .sheet(isPresented: $commands.showingQuickOpen) {
            QuickOpenView(workspace: workspace) { entry in
                selectedFile = entry.path
                commands.showingQuickOpen = false
            }
        }
        .alert("Orgstar", isPresented: errorShown) {
            Button("OK") {
                workspace.lastError = nil
                session.lastError = nil
            }
        } message: {
            Text(workspace.lastError ?? session.lastError ?? "")
        }
        .task {
            DevelopmentHooks.scheduleSnapshot()
            if let path = DevelopmentHooks.fileToOpen { selectedFile = path }
            await workspace.refresh()
            workspace.startWatching()
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { workspace.lastError != nil || session.lastError != nil }, set: { _ in })
    }
}

struct Sidebar: View {
    let workspace: WorkspaceModel
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            ForEach(workspace.rootPaths, id: \.self) { root in
                Section((root as NSString).lastPathComponent) {
                    OutlineGroup(workspace.tree(forRoot: root).children ?? [], children: \.children) { node in
                        Label(node.name, systemImage: icon(node))
                            .foregroundStyle(node.file?.kind == .conflict ? .orange : .primary)
                            .tag(node.file?.path)
                    }
                }
                .contextMenu {
                    Button("Remove Folder") { try? workspace.removeRoot(path: root) }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func icon(_ node: FileTreeNode) -> String {
        guard let file = node.file else { return "folder" }
        switch file.kind {
        case .org: return "doc.text"
        case .archive: return "archivebox"
        case .conflict: return "exclamationmark.triangle"
        }
    }
}

struct OutlineColumn: View {
    let session: DocumentSession

    var body: some View {
        List(Array(session.outline.enumerated()), id: \.element.start) { _, entry in
            Button {
                session.reveal(entry.start)
            } label: {
                Text(entry.title.isEmpty ? "(untitled)" : entry.title)
                    .lineLimit(1)
                    .padding(.leading, CGFloat(entry.level - 1) * 12)
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if session.document != nil, session.outline.isEmpty {
                ContentUnavailableView("No headings", systemImage: "list.bullet.indent")
            }
        }
    }
}

struct SearchResults: View {
    let results: [HeadingLocation]
    let open: (HeadingLocation) -> Void

    var body: some View {
        List(results, id: \.self) { location in
            Button {
                open(location)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(location.title.isEmpty ? "(untitled)" : location.title).lineLimit(1)
                    Text((location.path as NSString).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if results.isEmpty { ContentUnavailableView.search }
        }
    }
}

struct QuickOpenView: View {
    let workspace: WorkspaceModel
    let open: (FileEntry) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let matches = workspace.quickOpen(query)
        VStack(spacing: 0) {
            TextField("Open file", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .onSubmit { if let first = matches.first { open(first) } }
            Divider()
            List(matches) { entry in
                Button {
                    open(entry)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                        Text(entry.relativePath).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 520, height: 360)
        .onExitCommand { dismiss() }
    }
}
