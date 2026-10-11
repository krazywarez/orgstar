import OrgApp
import OrgCore
import OrgWorkspace
import SwiftUI
import UniformTypeIdentifiers

struct Sidebar: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    @Binding var selection: String?
    var addFolder: () -> Void = {}
    /// Folders shown collapsed, by path, one per line.
    @AppStorage("collapsedFolders") private var collapsedText = ""
    @State private var removing: String?
    /// A file operation waiting for a name or a confirmation.
    @Environment(\.orgTheme) private var theme
    @State var pending: FileOperation?
    @State var name = ""
    @State var failure: String?

    private var collapsed: Set<String> { Set(collapsedText.split(separator: "\n").map(String.init)) }

    private func expanded(_ root: String) -> Binding<Bool> {
        Binding {
            !collapsed.contains(root)
        } set: { isExpanded in
            var set = collapsed
            if isExpanded { set.remove(root) } else { set.insert(root) }
            collapsedText = set.sorted().joined(separator: "\n")
        }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(workspace.rootPaths, id: \.self) { root in
                Section(isExpanded: expanded(root)) {
                    OutlineGroup(workspace.tree(forRoot: root).children ?? [], children: \.children) { node in
                        Label(node.name, systemImage: icon(node))
                            .foregroundStyle(node.file?.kind == .conflict ? .orange : node.isDownloading ? .secondary : theme.color("sidebar-foreground") ?? .primary)
                            .help(node.isDownloading ? "Downloading from iCloud" : "")
                            .tag(node.file?.path)
                            .contextMenu { fileMenu(node) }
                    }
                } header: {
                    Text((root as NSString).lastPathComponent)
                        .foregroundStyle(theme.color("sidebar-header") ?? .secondary)
                        .help(root)
                        .contextMenu { folderMenu(root) }
                }
            }
        }
        .listStyle(.sidebar)
        .themedListBackground(theme.color("sidebar-background"))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 4) {
                Button("Add Folder…", systemImage: "plus", action: addFolder)
                    .help("Add a folder (⇧⌘O)")
                Menu {
                    ForEach(workspace.rootPaths, id: \.self) { root in
                        Button((root as NSString).lastPathComponent) { removing = root }
                    }
                } label: {
                    Label("Remove Folder", systemImage: "minus")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(workspace.rootPaths.isEmpty)
                .help("Remove a folder from the sidebar")
                Spacer()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .confirmationDialog(
            "Remove “\(removing.map { ($0 as NSString).lastPathComponent } ?? "")” from the sidebar?",
            isPresented: Binding { removing != nil } set: { if !$0 { removing = nil } }
        ) {
            Button("Remove") {
                if let root = removing { try? workspace.removeRoot(path: root) }
                removing = nil
            }
        } message: {
            Text("The folder and its files stay on disk.")
        }
        .fileOperations(self)
    }

    @ViewBuilder
    private func folderMenu(_ root: String) -> some View {
        Button("New File…") { ask(.create(folder: root)) }
        Divider()
        Button(collapsed.contains(root) ? "Expand" : "Collapse") { expanded(root).wrappedValue.toggle() }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root)]) }
        Divider()
        Button("Remove from Sidebar…") { removing = root }
    }

    private func icon(_ node: FileTreeNode) -> String {
        if node.isDownloading { return "icloud.and.arrow.down" }
        guard let file = node.file else { return "folder" }
        switch file.kind {
        case .org: return "doc.text"
        case .archive: return "archivebox"
        case .conflict: return "exclamationmark.triangle"
        case .other:
            guard let type = UTType(filenameExtension: (file.path as NSString).pathExtension) else { return "doc" }
            if type.conforms(to: .image) { return "photo" }
            if type.conforms(to: .pdf) { return "doc.richtext" }
            if type.conforms(to: .audiovisualContent) { return "play.rectangle" }
            if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return "chevron.left.forwardslash.chevron.right" }
            if type.conforms(to: .text) { return "doc.plaintext" }
            return "doc"
        }
    }
}

struct OutlineColumn: View {
    let session: DocumentSession
    @Environment(\.orgTheme) private var theme

    var body: some View {
        List(Array(session.outline.enumerated()), id: \.element.start) { _, entry in
            Button {
                session.reveal(entry.start)
            } label: {
                Text(entry.title.isEmpty ? "(untitled)" : entry.title)
                    .foregroundStyle(theme.color("sidebar-foreground") ?? .primary)
                    .lineLimit(1)
                    .padding(.leading, CGFloat(entry.level - 1) * 12)
            }
            .buttonStyle(.plain)
        }
        .themedListBackground(theme.color("sidebar-background"))
        .overlay {
            if session.path != nil, !session.isOrg {
                ContentUnavailableView("No outline", systemImage: "doc.plaintext", description: Text("Only org files have an outline."))
            } else if session.path != nil, session.outline.isEmpty {
                ContentUnavailableView("No headings", systemImage: "list.bullet.indent")
            }
        }
    }
}
