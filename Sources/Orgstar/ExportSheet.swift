import AppKit
import SwiftUI

/// Export… (`app.export-dialog`): the format, where the file goes, and whether to open it after.
struct ExportSheet: View {
    let source: URL
    let export: (_ format: String, _ destination: URL, _ open: Bool) -> Void
    @AppStorage("exportFormat") private var format = "html"
    @AppStorage("exportOpenAfter") private var openAfter = false
    @State private var destination: URL?
    @Environment(\.dismiss) private var dismiss

    static let formats: [(id: String, title: String, ext: String)] = [
        ("html", "HTML", "html"), ("markdown", "Markdown", "md"), ("pdf", "PDF (Emacs)", "pdf"),
        ("odt", "ODT (Emacs)", "odt"), ("latex", "LaTeX (Emacs)", "tex"), ("text", "Plain text (Emacs)", "txt"),
    ]

    private var ext: String { Self.formats.first { $0.id == format }?.ext ?? "html" }
    private var target: URL { destination ?? source.deletingPathExtension().appendingPathExtension(ext) }

    var body: some View {
        Form {
            Picker("Format", selection: $format) {
                ForEach(Self.formats, id: \.id) { Text($0.title).tag($0.id) }
            }
            .onChange(of: format) { destination = destination.map { $0.deletingPathExtension().appendingPathExtension(ext) } }
            LabeledContent("Destination") {
                HStack {
                    Text(target.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…") { choose() }
                }
            }
            Toggle("Open after export", isOn: $openAfter)
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export") {
                    export(format, target, openAfter)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520)
    }

    private func choose() {
        let panel = NSSavePanel()
        panel.directoryURL = target.deletingLastPathComponent()
        panel.nameFieldStringValue = target.lastPathComponent
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }
}
