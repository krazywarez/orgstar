import OrgApp
import OrgCore
import OrgIndex
import OrgPresentation
import SwiftUI

/// Headings that link to the heading at the caret, and to the file.
struct BacklinksPane: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    let commands: AppCommands
    let open: (HeadingLocation) -> Void
    @State private var toHeading: [HeadingLocation] = []
    @State private var toFile: [HeadingLocation] = []
    @Environment(\.orgTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    /// The heading at the caret.
    private var heading: OutlineEntry? { session.outline.last { $0.start <= commands.selection.location } }

    private struct Key: Equatable {
        var path: String?
        var heading: Int?
        var version: Int
    }

    var body: some View {
        List {
            if let heading {
                Section("Links to \(heading.title.isEmpty ? "(untitled)" : heading.title)") { rows(toHeading) }
            }
            Section("Links to this file") { rows(toFile) }
        }
        .themedListBackground(theme.color("sidebar-background", in: colorScheme))
        .task(id: Key(path: session.path, heading: heading?.start, version: session.editVersion)) { refresh() }
    }

    @ViewBuilder
    private func rows(_ locations: [HeadingLocation]) -> some View {
        if locations.isEmpty {
            Text("None").foregroundStyle(.secondary)
        }
        ForEach(locations, id: \.self) { location in
            Button {
                open(location)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(location.title.isEmpty ? "(untitled)" : location.title).lineLimit(1)
                    if let snippet = location.snippet {
                        Text(snippet.attributed).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    }
                    Text((location.path as NSString).lastPathComponent).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func refresh() {
        guard let path = session.path else {
            toHeading = []
            toFile = []
            return
        }
        let overlay = workspace.overlay(session.openDocuments)
        // The file's own ID, as an org-roam file node.
        let fileID = session.document.map { DocumentModel(tree: $0.tree).property("ID", of: nil)?.value }
        toFile = workspace.backlinks(to: Backlinks.Target(path: path, id: fileID ?? nil), overlay: overlay)
        guard let heading, let tree = session.document?.tree,
              let info = DocumentModel(tree: tree).headings.first(where: { $0.headingRange.lowerBound == heading.start }) else {
            toHeading = []
            return
        }
        let customID = info.properties.last { $0.key.uppercased() == "CUSTOM_ID" }?.value
        let target = Backlinks.Target(path: path, title: info.title, id: info.id, customID: customID)
        toHeading = workspace.backlinks(to: target, excluding: heading.start, overlay: overlay)
    }
}
