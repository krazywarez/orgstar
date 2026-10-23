#if os(iOS)
import OrgApp
import OrgCore
import SwiftUI

/// Import from Emacs: a configuration folder (a synced `~/.config/doom` or `~/.emacs.d`), read
/// and picked from before anything changes. Settings go into the configuration
/// folder's config.toml when there is one; agenda folders, which name the Mac's paths, are left
/// out.
struct EmacsImportScreen: View {
    let model: MobileModel
    @State private var location: URL?
    @State private var result: EmacsImport?
    @State private var selected: Set<Int> = []
    @State private var choosing = false
    @State private var summary: String?
    @State private var importing = false

    var body: some View {
        List {
            Section {
                Button(location == nil ? "Choose Folder…" : "Choose Another Folder…") { choosing = true }
            } footer: {
                Text(location.map { "Reading \($0.lastPathComponent)" + ((result?.isDoom ?? false) ? ", a Doom configuration" : "") + "." }
                    ?? "The folder holding init.el, config.el or config.org.")
            }
            if let summary {
                Section { Text(summary) }
            } else if let result {
                EmacsImportSections(result: result, groups: result.groups(folders: false), selected: $selected,
                                    font: .system(.callout, design: .monospaced))
            }
        }
        .navigationTitle("Import from Emacs")
        .toolbar {
            if result != nil, summary == nil {
                Button("Import") { runImport() }.disabled(selected.isEmpty || importing)
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { chosen in
            if case .success(let url) = chosen { read(url) }
        }
    }

    private func read(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        location = url
        let scanned = EmacsImport.scan(EmacsImport.files(in: url))
        result = scanned
        selected = Set(scanned.groups(folders: false).flatMap(\.1).map(\.id))
        summary = nil
    }

    private func runImport() {
        guard let result else { return }
        importing = true
        let chosen = result.items.filter { selected.contains($0.id) }
        Task {
            summary = await EmacsImport.apply(chosen, workspace: nil, directory: model.configFolder ?? UserConfig.directory,
                                              writeConfig: model.configFolder != nil)
            model.reloadConfig()
            importing = false
        }
    }
}
#endif
