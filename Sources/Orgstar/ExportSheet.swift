import AppKit
import SwiftUI

/// Export… (`app.export-dialog`): the format, where the file goes, and whether to open it after.
struct ExportSheet: View {
    let source: URL
    /// Whether the caret is in a subtree that can be exported alone.
    let inSubtree: Bool
    /// The default destination for an extension, with or without the subtree.
    let target: (_ ext: String, _ subtree: Bool) -> URL
    let export: (_ format: String, _ destination: URL, _ open: Bool, _ subtree: Bool, _ bodyOnly: Bool) -> Void
    @AppStorage("exportFormat") private var format = "html"
    @AppStorage("exportOpenAfter") private var openAfter = false
    @AppStorage("exportBodyOnly") private var bodyOnly = false
    @AppStorage("pdfMargin") private var pdfMargin = 50
    @AppStorage("pdfFont") private var pdfFont = ""
    @AppStorage("pdfPageNumbers") private var pdfPageNumbers = true
    @State private var subtree = false
    @State private var destination: URL?
    @Environment(\.dismiss) private var dismiss

    static let formats: [(id: String, title: String, ext: String)] = [
        ("html", "HTML", "html"), ("markdown", "Markdown", "md"), ("print-pdf", "PDF", "pdf"), ("docx", "Word", "docx"),
        ("rtf", "Rich Text (RTF)", "rtf"), ("plain-text", "Plain text", "txt"), ("pdf", "PDF via LaTeX (Emacs)", "pdf"),
        ("odt", "ODT (Emacs)", "odt"), ("latex", "LaTeX (Emacs)", "tex"), ("text", "Plain text, ASCII (Emacs)", "txt"),
        ("icalendar", "iCalendar", "ics"),
    ]

    private var ext: String { Self.formats.first { $0.id == format }?.ext ?? "html" }
    private var chosen: URL { destination ?? target(ext, subtree) }
    /// PDF and ODT are whole documents.
    private var allowsBodyOnly: Bool { !["pdf", "print-pdf", "odt", "docx", "rtf", "plain-text", "icalendar"].contains(format) }

    var body: some View {
        Form {
            Picker("Format", selection: $format) {
                ForEach(Self.formats, id: \.id) { Text($0.title).tag($0.id) }
            }
            .onChange(of: format) { destination = destination.map { $0.deletingPathExtension().appendingPathExtension(ext) } }
            Picker("Scope", selection: $subtree) {
                Text("Whole file").tag(false)
                Text("Subtree at the caret").tag(true)
            }
            .disabled(!inSubtree)
            Toggle("Body only", isOn: $bodyOnly)
                .disabled(!allowsBodyOnly)
                .help("Leave out the title and page wrapper, as Org's body-only export")
            if format == "print-pdf" {
                Stepper("Margins: \(pdfMargin) pt", value: $pdfMargin, in: 18...144, step: 6)
                Picker("Font", selection: $pdfFont) {
                    Text("The export's own").tag("")
                    Divider()
                    ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Page numbers", isOn: $pdfPageNumbers)
            }
            LabeledContent("Destination") {
                HStack {
                    Text(chosen.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
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
                    export(format, chosen, openAfter, subtree && inSubtree, bodyOnly && allowsBodyOnly)
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
        panel.directoryURL = chosen.deletingLastPathComponent()
        panel.nameFieldStringValue = chosen.lastPathComponent
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }
}
