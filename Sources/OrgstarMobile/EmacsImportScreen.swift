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
                ForEach(groups(result), id: \.0) { title, items in
                    Section(title) {
                        ForEach(items) { item in
                            Toggle(isOn: Binding { selected.contains(item.id) } set: { on in
                                if on { selected.insert(item.id) } else { selected.remove(item.id) }
                            }) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.summary).font(.system(.callout, design: .monospaced))
                                    Text([item.name == item.summary ? nil : item.name, item.source.isEmpty ? nil : item.source].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                let notes = result.unsupported.map { ($0.id, $0.name, $0.reason, $0.source) } + result.unreadable.map { ($0.id, $0.name, $0.reason, $0.source) }
                if !notes.isEmpty || !result.problems.isEmpty {
                    Section("Not imported") {
                        ForEach(result.problems, id: \.self) { Text($0).foregroundStyle(.red) }
                        ForEach(notes, id: \.0) { note in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(note.1).font(.system(.callout, design: .monospaced))
                                Text("\(note.2) · \(note.3)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
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
    }

    private func groups(_ result: EmacsImport) -> [(String, [EmacsImport.Item])] {
        [
            ("Settings", result.items.filter { if case .setting = $0.change { true } else { false } }),
            ("Capture templates", result.items.filter { if case .capture = $0.change { true } else { false } }),
            ("Key bindings", result.items.filter { if case .binding = $0.change { true } else { false } }),
            ("Structure templates", result.items.filter { if case .structureTemplate = $0.change { true } else { false } }),
            ("Agenda views", result.items.filter { if case .view = $0.change { true } else { false } }),
        ].filter { !$0.1.isEmpty }
    }

    private func read(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        location = url
        let scanned = EmacsImport.scan(EmacsImport.files(in: url))
        result = scanned
        selected = Set(groups(scanned).flatMap(\.1).map(\.id))
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
