#if os(iOS)
import OrgApp
import OrgCore
import SwiftUI

/// Import from Emacs: a configuration folder (a synced `~/.config/doom` or `~/.emacs.d`), read
/// and picked from before anything changes. Settings go into the configuration
/// folder's config.toml when there is one. Agenda folders name the Mac's paths, so each is
/// added as the folder chosen for it on this device.
struct EmacsImportScreen: View {
    let model: MobileModel
    @State private var location: URL?
    @State private var result: EmacsImport?
    @State private var selected: Set<Int> = []
    @State private var choosing = false
    @State private var summary: String?
    @State private var importing = false
    /// The folders chosen on this device, by the Mac path they stand for.
    @State private var folders: [String: URL] = [:]
    /// The Mac path the folder picker is choosing for.
    @State private var folderFor: String?
    @State private var choosingFolder = false

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
                EmacsImportSections(result: result, groups: result.groups(folders: true), selected: $selected,
                                    font: .system(.callout, design: .monospaced))
                let paths = EmacsImport.foldersToAdd(result.items.filter { selected.contains($0.id) }, workspace: model.workspace)
                if !paths.isEmpty {
                    Section {
                        ForEach(paths, id: \.self) { path in
                            Button {
                                folderFor = path
                                choosingFolder = true
                            } label: {
                                LabeledContent(path, value: folders[path]?.lastPathComponent ?? "Choose…")
                            }
                        }
                    } header: {
                        Text("Folders on this device")
                    } footer: {
                        Text("Choose the folder on this device for each one. Folders not chosen aren't added.")
                    }
                }
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
        .background {
            // A second importer on the same view would replace the first.
            Color.clear.fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { chosen in
                guard let path = folderFor, case .success(let url) = chosen else { return }
                // Access starts when the import adds it.
                folders[path] = url
            }
        }
    }

    private func read(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        location = url
        let scanned = EmacsImport.scan(EmacsImport.files(in: url))
        result = scanned
        selected = Set(scanned.groups(folders: true).flatMap(\.1).map(\.id))
        folders = [:]
        summary = nil
    }

    private func runImport() {
        guard let result else { return }
        importing = true
        let chosen = result.items.filter { selected.contains($0.id) }
        Task {
            summary = await EmacsImport.apply(chosen, workspace: model.workspace, directory: model.configFolder ?? UserConfig.directory,
                                              writeConfig: model.configFolder != nil, chosenFolders: folders)
            model.reloadConfig()
            importing = false
        }
    }
}
#endif
