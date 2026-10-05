import OrgApp
import OrgCore
import OrgEditorAppKit
import OrgIndex
import SwiftUI

struct ContentView: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    @Bindable var commands: AppCommands
    @AppStorage("saveMode") private var saveMode = SaveMode.automatic
    @AppStorage("keymap") private var preset = KeymapPreset.emacs
    @AppStorage("optionAsMeta") private var optionAsMeta = OptionAsMeta.left.rawValue
    @State private var keymap = KeymapPreset.emacs.keymap
    @AppStorage("tagsColumn") private var tagsColumn = -77
    @AppStorage("headingAfterSubtree") private var headingAfterSubtree = true
    @AppStorage("splitLine") private var splitLine = false
    @AppStorage("alphabeticalLists") private var alphabeticalLists = true
    @AppStorage("fillColumn") private var fillColumn = 80

    private var options: EditingOptions {
        Preferences.options(tagsColumn: tagsColumn, headingAfterSubtree: headingAfterSubtree, splitLine: splitLine, alphabeticalLists: alphabeticalLists, fillColumn: fillColumn)
    }
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
                    SearchResults(results: workspace.search(query, overlay: workspace.overlay(path: session.path, document: session.document))) { location in
                        guard location.path == session.path || UnsavedChanges.resolve(session) else { return }
                        selectedFile = location.path
                        session.show(location)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 220, max: 360)
        } detail: {
            if session.path != nil {
                EditorView(session: session, commands: commands, keymap: keymap, optionAsMeta: OptionAsMeta(rawValue: optionAsMeta), options: options, onAppCommand: perform)
                    .safeAreaInset(edge: .bottom, spacing: 0) { EchoArea(commands: commands) }
            } else {
                ContentUnavailableView(
                    workspace.roots.isEmpty ? "Add a folder of org files" : "Choose a file",
                    systemImage: "doc.text",
                    description: Text(workspace.roots.isEmpty ? "File ▸ Add Folder… (⇧⌘O)" : "Or press ⌘P to open one by name.")
                )
            }
        }
        .navigationTitle(session.path.map { ($0 as NSString).lastPathComponent } ?? "Orgstar")
        .navigationSubtitle(session.isReadOnly ? "Read-only: not UTF-8" : "")
        .searchable(text: $query, placement: .toolbar, prompt: "Search notes")
        .searchFocused($searchFocused)
        .toolbar {
            if workspace.isIndexing { ProgressView().controlSize(.small) }
            if session.conflict != nil {
                Button("Conflict", systemImage: "exclamationmark.triangle") { commands.showingConflict = true }
                    .help("The file changed on disk, and the changes conflict with yours")
            }
        }
        .onChange(of: selectedFile) { old, path in
            guard let path, path != session.path else { return }
            if UnsavedChanges.resolve(session) {
                session.open(path)
            } else {
                selectedFile = old
            }
        }
        .onChange(of: saveMode, initial: true) { _, mode in session.saveMode = mode }
        .onChange(of: options, initial: true) { _, options in session.options = options }
        .onChange(of: preset, initial: true) { loadKeymap() }
        .sheet(isPresented: $commands.showingPalette) {
            PaletteView(keymap: keymap) { id in
                commands.showingPalette = false
                // After the sheet closes, so app commands can present their own.
                DispatchQueue.main.async { perform(id) }
            }
        }
        .onChange(of: session.conflict) { _, conflict in
            if conflict != nil { commands.showingConflict = true }
        }
        .alert("Conflicting changes", isPresented: $commands.showingConflict) {
            Button("Keep Mine") { session.keepMine() }
            Button("Use Disk Version") { session.useDiskVersion() }
            Button("Decide Later", role: .cancel) {}
        } message: {
            Text((session.conflict ?? "") + " The version you don't keep is saved in the recovery folder.")
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

    private func loadKeymap() {
        let loaded = KeymapLoader.load(preset)
        keymap = loaded.keymap
        if let first = loaded.problems.first {
            let more = loaded.problems.count > 1 ? " (and \(loaded.problems.count - 1) more)" : ""
            commands.show("keymap.toml: \(first)\(more)")
        }
    }

    /// Runs a command from a key, the palette or the Org menu.
    private func perform(_ id: String) {
        switch id {
        case "app.save":
            if !session.save(), session.conflict != nil { commands.showingConflict = true }
        case "app.quick-open": commands.showingQuickOpen = true
        case "app.palette": commands.showingPalette = true
        case "app.search": commands.focusSearch = true
        case "app.reload-keymap":
            loadKeymap()
            commands.show("Keymap reloaded")
        case "app.refile":
            let targets = workspace.refileTargets(openPath: session.path, document: session.document)
            commands.ask(Prompt(key: "refile", message: "Refile to:", choices: targets.map(\.label))) { answer in
                guard let answer, let target = targets.first(where: { $0.label == answer }) else { return }
                if let message = session.refile(to: target) { commands.show(message) }
            }
        case "app.archive":
            if let message = session.archive() { commands.show(message) }
        default:
            if let editor = commands.editor { editor.run(id) } else { commands.show("No file is open") }
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
            if session.path != nil, session.outline.isEmpty {
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
