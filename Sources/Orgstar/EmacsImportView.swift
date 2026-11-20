import OrgApp
import OrgCore
import SwiftUI

/// Import from Emacs: what was read from a configuration, to pick from before anything changes.
struct EmacsImportView: View {
    let workspace: WorkspaceModel?
    @Environment(\.dismiss) private var dismiss
    @State private var location: URL?
    @State private var result: EmacsImport?
    @State private var selected: Set<Int> = []
    @State private var choosing = false
    @State private var summary: String?
    @State private var importing = false
    /// Doom's own folder, chosen in the App Store build, where the sandbox can't find it.
    @State private var doomInstall: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let summary {
                Text(summary).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let result {
                list(result)
            } else {
                ContentUnavailableView("No Emacs configuration found", systemImage: "doc.questionmark",
                                       description: Text("Choose your init.el, or the folder holding it (~/.emacs.d, ~/.config/doom)."))
            }
            Divider()
            HStack {
                if let result, summary == nil {
                    Text(footnote(result)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if summary == nil {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Import") { runImport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selected.isEmpty || importing)
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
        .frame(width: 640, height: 560)
        .onAppear {
            // The sandbox can't look in the home folder, so the App Store build starts with the picker.
            #if APPSTORE
            if location == nil { DispatchQueue.main.async { choose() } }
            #else
            if location == nil, let first = EmacsImport.defaultLocations().first { read(first) }
            #endif
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder, .item]) { chosen in
            if case .success(let url) = chosen { read(url) }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Import from Emacs").font(.headline)
                Text(location.map { "Reading \($0.path)" + (withDoomDefaults ? ", with Doom's own org defaults" : "") } ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            #if APPSTORE
            if let result, result.isDoom, !result.doomDefaultsRead {
                Button("Choose Doom Folder…") { chooseDoom() }
                    .help("Doom's own org defaults are read from the folder Doom is installed in")
            }
            #endif
            Button("Choose…") { choose() }
        }
        .padding(12)
    }

    private var withDoomDefaults: Bool {
        #if APPSTORE
        result?.doomDefaultsRead ?? false
        #else
        result?.isDoom ?? false
        #endif
    }

    private func choose() {
        #if APPSTORE
        let message = String(localized: "Choose your init.el, or the folder holding it (~/.emacs.d, ~/.config/doom).",
                             comment: "Open panel for importing an Emacs configuration")
        if let url = GrantAccess.choose(at: EmacsImport.pickerLocation(), message: message, prompt: String(localized: "Choose"), files: true, hidden: true) {
            read(url)
        }
        #else
        choosing = true
        #endif
    }

    #if APPSTORE
    /// Doom's install folder, for its org defaults; the sandbox keeps orgstar from finding it.
    private func chooseDoom() {
        let message = String(localized: "Choose the folder Doom is installed in (~/.config/emacs or ~/.emacs.d) to read Doom's own org defaults.",
                             comment: "Open panel for Doom's install folder when importing from Emacs")
        guard let install = EmacsImport.doomInstallLocations().first,
              let url = GrantAccess.choose(at: install, message: message, prompt: String(localized: "Choose"), hidden: true),
              let location else { return }
        doomInstall = url
        read(location)
    }

    /// Asks for each folder the import adds, with an open panel at it, and adds the folders
    /// chosen there: the sandbox lets orgstar into those alone.
    private func chooseFolders(_ items: [EmacsImport.Item]) -> [String: URL] {
        var chosen: [String: URL] = [:]
        for path in EmacsImport.foldersToAdd(items, workspace: workspace) where chosen[path] == nil {
            let name = OrgPaths.abbreviatingWithTilde(OrgPaths.expandingTilde(path))
            let message = String(localized: "Choose \(name) to add it to the sidebar.", comment: "Open panel for a folder imported from Emacs")
            if let url = GrantAccess.choose(at: URL(fileURLWithPath: OrgPaths.expandingTilde(path)), message: message,
                                            prompt: String(localized: "Add Folder")) {
                chosen[path] = url
            }
        }
        return chosen
    }
    #endif

    private func list(_ result: EmacsImport) -> some View {
        List {
            EmacsImportSections(result: result, groups: result.groups(folders: true), selected: $selected,
                                font: .system(.body, design: .monospaced))
        }
    }

    private func footnote(_ result: EmacsImport) -> String {
        var parts = ["\(result.skipped) variables not about org left alone"]
        if result.doomDefaultsLeftOut > 0 { parts.append("\(result.doomDefaultsLeftOut) Doom defaults orgstar has no use for") }
        #if APPSTORE
        if result.isDoom, !result.doomDefaultsRead { parts.append("Doom's own org defaults skipped") }
        #endif
        return parts.joined(separator: "; ")
    }

    private func read(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        location = url
        #if APPSTORE
        let scanned = EmacsImport.scan(EmacsImport.files(in: url), doomDefaults: doomInstall.map(EmacsImport.doomDefaultFiles(in:)))
        #else
        let scanned = EmacsImport.scan(EmacsImport.files(in: url))
        #endif
        result = scanned
        selected = Set(scanned.items.map(\.id))
        summary = nil
    }

    private func runImport() {
        guard let result else { return }
        importing = true
        let chosen = result.items.filter { selected.contains($0.id) }
        #if APPSTORE
        let folders: [String: URL]? = chooseFolders(chosen)
        #else
        let folders: [String: URL]? = nil
        #endif
        Task {
            summary = await EmacsImport.apply(chosen, workspace: workspace, chosenFolders: folders)
            importing = false
        }
    }
}
