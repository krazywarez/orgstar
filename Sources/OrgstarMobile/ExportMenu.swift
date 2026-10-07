#if os(iOS)
import CoreTransferable
import OrgApp
import OrgCore
import SwiftUI
import UniformTypeIdentifiers

/// A file exported as HTML or Markdown, written when the share sheet takes it.
struct OrgExport: Transferable {
    enum Format { case html, markdown }

    let text: String
    let path: String
    let format: Format
    let settings: OrgSettings

    var fileName: String {
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return base + (format == .html ? ".html" : ".md")
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .html) { export in
            try export.write()
        }
        .exportingCondition { $0.format == .html }
        FileRepresentation(exportedContentType: UTType(filenameExtension: "md") ?? .plainText) { export in
            try export.write()
        }
        .exportingCondition { $0.format == .markdown }
    }

    private func write() throws -> SentTransferredFile {
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let settings = settings.resolvingSetupFiles(in: text, path: path, read: OrgSettings.readFile)
        let content = switch format {
        case .html: HTMLExport.page(text, fallbackTitle: base, settings: settings, path: path)
        case .markdown: MarkdownExport.document(text, settings: settings, path: path)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return SentTransferredFile(url)
    }
}

/// Sharing the file as HTML or Markdown: to another app, or saved with Save to Files.
struct ExportMenu: View {
    let path: String
    let text: String

    var body: some View {
        Menu("Export", systemImage: "square.and.arrow.up") {
            ForEach([(OrgExport.Format.html, "HTML"), (.markdown, "Markdown")], id: \.1) { format, name in
                let export = OrgExport(text: text, path: path, format: format, settings: OrgPreferences.orgSettings())
                ShareLink(item: export, preview: SharePreview(export.fileName)) { Text(name) }
            }
        }
    }
}
#endif
