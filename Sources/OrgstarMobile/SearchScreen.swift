#if os(iOS)
import OrgApp
import OrgIndex
import SwiftUI

/// Files by name and headings by their words, as ⌘P and ⇧⌘F find them on the Mac.
struct SearchScreen: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    @State private var query = ""

    var body: some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        List {
            if !trimmed.isEmpty {
                let files = FuzzyMatch.rank(trimmed, workspace.files.filter { $0.kind == .org }, limit: 8)
                if !files.isEmpty {
                    Section("Files") {
                        ForEach(files) { file in
                            NavigationLink(value: ReaderRoute.file(file.path)) {
                                Label(file.relativePath, systemImage: "doc.text")
                            }
                        }
                    }
                }
                let headings = workspace.search(trimmed, overlay: workspace.overlay(session.openDocuments))
                Section("Headings") {
                    if headings.isEmpty { Text("No headings match").foregroundStyle(.secondary) }
                    ForEach(headings, id: \.self) { location in
                        NavigationLink(value: ReaderRoute.heading(location)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(location.title.isEmpty ? "(untitled)" : location.title).lineLimit(2)
                                Text((location.path as NSString).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if trimmed.isEmpty {
                ContentUnavailableView("Search notes", systemImage: "magnifyingglass", description: Text("File names and the words of headings and their text."))
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
    }
}
#endif
