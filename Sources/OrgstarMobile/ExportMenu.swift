#if os(iOS)
import CoreTransferable
import OrgApp
import OrgCore
import OrgPresentation
import SwiftUI
import UniformTypeIdentifiers

/// A file exported as HTML, Markdown or PDF, written when the share sheet takes it.
struct OrgExport: Transferable {
    enum Format: CaseIterable {
        case html, markdown, pdf, rtf, plainText

        var name: String {
            switch self {
            case .html: "HTML"
            case .markdown: "Markdown"
            case .pdf: "PDF"
            case .rtf: "Rich Text (RTF)"
            case .plainText: "Plain Text"
            }
        }

        var fileExtension: String {
            switch self {
            case .html: "html"
            case .markdown: "md"
            case .pdf: "pdf"
            case .rtf: "rtf"
            case .plainText: "txt"
            }
        }
    }

    let text: String
    let path: String
    let format: Format
    let settings: OrgSettings
    /// Made on the main actor, where the editor's highlighter is.
    let codeStyle: HTMLCodeStyle

    /// `#+EXPORT_FILE_NAME`'s name, or the file's, with the format's extension.
    var fileName: String {
        ExportScope.output(for: URL(fileURLWithPath: path), name: ExportScope.fileName(text, settings: settings), extension: format.fileExtension)
            .lastPathComponent
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .html) { try await $0.write() }
            .exportingCondition { $0.format == .html }
        FileRepresentation(exportedContentType: UTType(filenameExtension: "md") ?? .plainText) { try await $0.write() }
            .exportingCondition { $0.format == .markdown }
        FileRepresentation(exportedContentType: .pdf) { try await $0.write() }
            .exportingCondition { $0.format == .pdf }
        FileRepresentation(exportedContentType: .rtf) { try await $0.write() }
            .exportingCondition { $0.format == .rtf }
        FileRepresentation(exportedContentType: .plainText) { try await $0.write() }
            .exportingCondition { $0.format == .plainText }
    }

    private func write() async throws -> SentTransferredFile {
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let settings = settings.resolvingSetupFiles(in: text, path: path, read: OrgSettings.readFile)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName)
        switch format {
        case .html:
            try HTMLExport.page(text, fallbackTitle: base, settings: settings, path: path, codeStyle: codeStyle)
                .write(to: url, atomically: true, encoding: .utf8)
        case .markdown:
            try MarkdownExport.document(text, settings: settings, path: path).write(to: url, atomically: true, encoding: .utf8)
        case .pdf, .rtf, .plainText:
            let html = HTMLExport.page(text, fallbackTitle: base, settings: settings, path: path, codeStyle: codeStyle)
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            let data: Data = switch format {
            case .pdf: try await PDFExport.pdf(html: html, directory: directory)
            case .rtf: try await RichTextExport.rtf(html: html, directory: directory)
            default: Data(try await RichTextExport.plain(html: html, directory: directory).utf8)
            }
            try data.write(to: url, options: .atomic)
        }
        return SentTransferredFile(url)
    }
}

/// Sharing the file as HTML, Markdown, PDF, RTF or plain text: to another app, or saved with
/// Save to Files; or copying it as rich text.
struct ExportMenu: View {
    let path: String
    let text: String
    @Environment(MobileModel.self) private var model
    /// Shows what happened, as the screen's message line does.
    var report: (String) -> Void = { _ in }

    var body: some View {
        Menu("Export", systemImage: "square.and.arrow.up") {
            ForEach(OrgExport.Format.allCases, id: \.self) { format in
                let export = OrgExport(text: text, path: path, format: format, settings: OrgPreferences.orgSettings(),
                                       codeStyle: HTMLCodeStyle(highlighter: MobileEditor.highlighter, theme: model.theme))
                ShareLink(item: export, preview: SharePreview(export.fileName)) { Text(format.name) }
            }
            Divider()
            Button("Copy as Rich Text", systemImage: "doc.on.doc") { copy() }
        }
    }

    /// The file on the clipboard as HTML, RTF and plain text, to paste formatted.
    private func copy() {
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let settings = OrgPreferences.orgSettings().resolvingSetupFiles(in: text, path: path, read: OrgSettings.readFile)
        let html = HTMLExport.page(text, fallbackTitle: base, settings: settings, path: path,
                                   codeStyle: HTMLCodeStyle(highlighter: MobileEditor.highlighter, theme: model.theme))
        do {
            try RichTextExport.copy(html: html, directory: URL(fileURLWithPath: path).deletingLastPathComponent())
            report("Copied as rich text")
        } catch {
            report("\(error)")
        }
    }
}
#endif
