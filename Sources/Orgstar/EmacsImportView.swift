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
            if location == nil, let first = EmacsImport.defaultLocations().first { read(first) }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder, .item]) { chosen in
            if case .success(let url) = chosen { read(url) }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Import from Emacs").font(.headline)
                Text(location.map { "Reading \($0.path)" + ((result?.isDoom ?? false) ? ", with Doom's own org defaults" : "") } ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Choose…") { choosing = true }
        }
        .padding(12)
    }

    private func list(_ result: EmacsImport) -> some View {
        List {
            EmacsImportSections(result: result, groups: result.groups(folders: true), selected: $selected,
                                font: .system(.body, design: .monospaced))
        }
    }

    private func footnote(_ result: EmacsImport) -> String {
        var parts = ["\(result.skipped) variables not about org left alone"]
        if result.doomDefaultsLeftOut > 0 { parts.append("\(result.doomDefaultsLeftOut) Doom defaults orgstar has no use for") }
        return parts.joined(separator: "; ")
    }

    private func read(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        location = url
        let scanned = EmacsImport.scan(EmacsImport.files(in: url))
        result = scanned
        selected = Set(scanned.items.map(\.id))
        summary = nil
    }

    private func runImport() {
        guard let result else { return }
        importing = true
        let chosen = result.items.filter { selected.contains($0.id) }
        Task {
            summary = await EmacsImport.apply(chosen, workspace: workspace)
            importing = false
        }
    }
}
