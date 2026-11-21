#if os(iOS)
import CoreTransferable
import OrgApp
import OrgCore
import OrgPresentation
import SwiftUI
import UniformTypeIdentifiers

/// A file exported as HTML, Markdown, PDF, Word, RTF, plain text, ODT, iCalendar, LaTeX or ASCII,
/// written when the share sheet takes it.
struct OrgExport: Transferable {
    enum Format: CaseIterable {
        case html, markdown, pdf, docx, rtf, plainText, odt, icalendar
        case latex, ascii

        /// Whether it needs Pro now: every format but HTML and Markdown, until Pro is unlocked.
        @MainActor var locked: Bool { self != .html && self != .markdown && !ProAccess.shared.isUnlocked }

        var name: String {
            switch self {
            case .html: "HTML"
            case .markdown: "Markdown"
            case .pdf: "PDF"
            case .docx: "Word"
            case .rtf: "Rich Text (RTF)"
            case .plainText: "Plain Text"
            case .odt: "ODT"
            case .icalendar: "iCalendar"
            case .latex: "LaTeX"
            case .ascii: "Plain Text (ASCII)"
            }
        }

        var fileExtension: String {
            switch self {
            case .html: "html"
            case .markdown: "md"
            case .pdf: "pdf"
            case .docx: "docx"
            case .rtf: "rtf"
            case .plainText: "txt"
            case .odt: "odt"
            case .icalendar: "ics"
            case .latex: "tex"
            case .ascii: "txt"
            }
        }
    }

    let text: String
    let path: String
    let format: Format
    let settings: OrgSettings
    /// Made on the main actor, where the editor's highlighter is.
    let codeStyle: HTMLCodeStyle
    /// The subtree at this offset exported alone.
    var subtree: Int?

    /// The subtree's `EXPORT_FILE_NAME`, `#+EXPORT_FILE_NAME`'s name, or the file's, with the
    /// format's extension.
    var fileName: String {
        ExportScope.output(for: URL(fileURLWithPath: path), name: ExportScope.fileName(text, subtreeAt: subtree, settings: settings),
                           extension: format.fileExtension)
            .lastPathComponent
    }

    /// Posted with the message, for the screen's message line, when the LaTeX or ASCII export
    /// refuses the file: the share sheet shows no reason.
    static let refused = Notification.Name("OrgExportRefused")

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .html) { try await $0.write() }
            .exportingCondition { $0.format == .html }
        FileRepresentation(exportedContentType: UTType(filenameExtension: "md") ?? .plainText) { try await $0.write() }
            .exportingCondition { $0.format == .markdown }
        FileRepresentation(exportedContentType: .pdf) { try await $0.write() }
            .exportingCondition { $0.format == .pdf }
        FileRepresentation(exportedContentType: UTType(filenameExtension: "docx") ?? .data) { try await $0.write() }
            .exportingCondition { $0.format == .docx }
        FileRepresentation(exportedContentType: .rtf) { try await $0.write() }
            .exportingCondition { $0.format == .rtf }
        FileRepresentation(exportedContentType: .plainText) { try await $0.write() }
            .exportingCondition { $0.format == .plainText }
        FileRepresentation(exportedContentType: UTType(filenameExtension: "odt") ?? .data) { try await $0.write() }
            .exportingCondition { $0.format == .odt }
        FileRepresentation(exportedContentType: .calendarEvent) { try await $0.write() }
            .exportingCondition { $0.format == .icalendar }
        FileRepresentation(exportedContentType: UTType(filenameExtension: "tex") ?? .plainText) { try await $0.write() }
            .exportingCondition { $0.format == .latex }
        FileRepresentation(exportedContentType: .plainText) { try await $0.write() }
            .exportingCondition { $0.format == .ascii }
    }

    /// The page HTML export makes of `text`, the file at `path`, with its setup files.
    @MainActor
    static func html(_ text: String, path: String, theme: ThemeSpec) -> String {
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let settings = OrgPreferences.orgSettings().resolvingSetupFiles(in: text, path: path, read: OrgSettings.readFile)
        return HTMLExport.page(text, fallbackTitle: base, settings: settings, path: path,
                               codeStyle: HTMLCodeStyle(highlighter: MobileEditor.highlighter, theme: theme), language: OrgPreferences.exportLanguage())
    }

    private func write() async throws -> SentTransferredFile {
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let settings = settings.resolvingSetupFiles(in: text, path: path, read: OrgSettings.readFile)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName)
        let text = subtree.flatMap { ExportScope.subtree(self.text, at: $0, settings: settings) } ?? self.text
        switch format {
        case .html:
            try HTMLExport.page(text, fallbackTitle: base, settings: settings, path: path, codeStyle: codeStyle, language: OrgPreferences.exportLanguage())
                .write(to: url, atomically: true, encoding: .utf8)
        case .markdown:
            try MarkdownExport.document(text, settings: settings, path: path).write(to: url, atomically: true, encoding: .utf8)
        case .latex:
            let content: String
            do {
                content = try LaTeXExport.document(text, settings: settings, path: path, language: OrgPreferences.exportLanguage(), file: true)
            } catch let error as LaTeXExport.Unsupported {
                let message = "Can't export to LaTeX: \(error.reason)"
                await MainActor.run { NotificationCenter.default.post(name: Self.refused, object: message) }
                throw error
            }
            try content.write(to: url, atomically: true, encoding: .utf8)
        case .ascii:
            let content: String
            do {
                content = try ASCIIExport.document(text, settings: settings, path: path, language: OrgPreferences.exportLanguage(), file: true)
            } catch let error as ASCIIExport.Unsupported {
                let message = "Can't export to plain text: \(error.reason)"
                await MainActor.run { NotificationCenter.default.post(name: Self.refused, object: message) }
                throw error
            }
            try content.write(to: url, atomically: true, encoding: .utf8)
        case .odt:
            try ODTExport.document(text, settings: settings, path: path, language: OrgPreferences.exportLanguage())
                .write(to: url, options: .atomic)
        case .icalendar:
            try ICalendarFiles.export(self.text, path: path, settings: settings, options: OrgPreferences.icalendarOptions(),
                                      subtree: subtree, destination: url)
        case .docx:
            let html = HTMLExport.page(text, fallbackTitle: base, settings: settings, path: path, codeStyle: codeStyle, language: OrgPreferences.exportLanguage())
            try await RichTextExport.docx(html: html, directory: URL(fileURLWithPath: path).deletingLastPathComponent()).write(to: url, options: .atomic)
        case .pdf, .rtf, .plainText:
            let html = HTMLExport.page(text, fallbackTitle: base, settings: settings, path: path, codeStyle: codeStyle, language: OrgPreferences.exportLanguage())
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            let data: Data = switch format {
            case .pdf: try await PDFExport.pdf(html: html, directory: directory, options: OrgPreferences.pdfOptions())
            case .rtf: try await RichTextExport.rtf(html: html, directory: directory)
            default: Data(try await RichTextExport.plain(html: html, directory: directory).utf8)
            }
            try data.write(to: url, options: .atomic)
        }
        return SentTransferredFile(url)
    }
}

/// Sharing the file as HTML, Markdown, PDF, Word, RTF, plain text, ODT, iCalendar, LaTeX or ASCII: to another app, or saved with
/// Save to Files; or copying it as rich text.
struct ExportMenu: View {
    let path: String
    let text: String
    @Environment(MobileModel.self) private var model
    /// Shows what happened, as the screen's message line does.
    var report: (String) -> Void = { _ in }
    /// Offers the subtree at the caret alone, where there is a caret.
    var exportSubtree: (() -> Void)?

    var body: some View {
        Menu("Export", systemImage: "square.and.arrow.up") {
            ForEach(OrgExport.Format.allCases, id: \.self) { format in
                if format.locked {
                    Button("\(format.name) (orgstar+)") { ProAccess.shared.allows(.export) }
                } else {
                    let export = OrgExport(text: text, path: path, format: format, settings: OrgPreferences.orgSettings(),
                                           codeStyle: HTMLCodeStyle(highlighter: MobileEditor.highlighter, theme: model.theme))
                    ShareLink(item: export, preview: SharePreview(export.fileName)) { Text(format.name) }
                }
            }
            if let exportSubtree {
                Button("Export Subtree…", systemImage: "list.bullet.indent") { exportSubtree() }
            }
            if let calendars = AgendaCalendars(model: model) {
                Divider()
                if OrgExport.Format.icalendar.locked {
                    Button("Agenda Files to iCalendar (orgstar+)") { ProAccess.shared.allows(.export) }
                } else {
                    Button("Export Agenda Files to iCalendar", systemImage: "calendar") { report(calendars.exportEach()) }
                    ShareLink(item: calendars, preview: SharePreview(calendars.fileName)) {
                        Label("Combine Agenda Files into iCalendar", systemImage: "calendar.badge.plus")
                    }
                }
            }
            Divider()
            Button("Copy as Rich Text", systemImage: "doc.on.doc") { if ProAccess.shared.allows(.export) { report(Self.copy(path: path, text: text, theme: model.theme)) } }
        }
    }

    /// The file on the clipboard as HTML, RTF and plain text, to paste formatted. Returns a message.
    @MainActor
    static func copy(path: String, text: String, theme: ThemeSpec) -> String {
        let html = OrgExport.html(text, path: path, theme: theme)
        do {
            try RichTextExport.copy(html: html, directory: URL(fileURLWithPath: path).deletingLastPathComponent())
            return "Copied as rich text"
        } catch {
            return "\(error)"
        }
    }
}

/// The agenda files as iCalendar: each to a calendar beside it
/// (`org-icalendar-export-agenda-files`), or all in one calendar to share
/// (`org-icalendar-combine-agenda-files`), named as `org-icalendar-combined-agenda-file` is.
struct AgendaCalendars: Transferable {
    let paths: [String]
    /// The open files' text, which may not be saved yet.
    let open: [String: String]

    /// Nil without agenda files.
    @MainActor init?(model: MobileModel) {
        guard let paths = model.workspace?.agendaFilePaths(), !paths.isEmpty else { return nil }
        self.paths = paths
        open = Dictionary(model.session.openDocuments.map { ($0.path, $0.document.text) }, uniquingKeysWith: { first, _ in first })
    }

    var fileName: String { (OrgPreferences.icalendarCombinedFile() as NSString).lastPathComponent }

    private func read(_ path: String) -> (text: String, settings: OrgSettings)? {
        guard let text = open[path] ?? (try? String(contentsOfFile: path, encoding: .utf8)) else { return nil }
        return (text, OrgPreferences.orgSettings().resolvingSetupFiles(in: text, path: path, read: OrgSettings.readFile))
    }

    /// Writes each agenda file's calendar beside it. Returns a message.
    func exportEach() -> String {
        do {
            let written = try ICalendarFiles.exportEach(paths, options: OrgPreferences.icalendarOptions(), read: read)
            return "Exported \(written.count) agenda files to iCalendar"
        } catch {
            return "Can't export: \(error.localizedDescription)"
        }
    }

    /// The combined calendar, in a new temporary folder.
    func combined() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return try ICalendarFiles.combine(paths, to: folder.appendingPathComponent(fileName).path, options: OrgPreferences.icalendarOptions(), read: read)
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .calendarEvent) { SentTransferredFile(try $0.combined()) }
    }
}

/// The subtree at `caret` shared alone, in each of the export formats.
struct SubtreeExportScreen: View {
    let path: String
    let text: String
    let caret: Int
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(OrgExport.Format.allCases.filter { !$0.locked }, id: \.self) { format in
                let export = OrgExport(text: text, path: path, format: format, settings: OrgPreferences.orgSettings(),
                                       codeStyle: HTMLCodeStyle(highlighter: MobileEditor.highlighter, theme: model.theme), subtree: caret)
                ShareLink(item: export, preview: SharePreview(export.fileName)) { Text(format.name) }
            }
            .navigationTitle("Export Subtree")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}
#endif
