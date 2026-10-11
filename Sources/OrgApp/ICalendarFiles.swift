import Foundation
import OrgCore

/// Writing iCalendar files: one file or subtree (`org-icalendar-export-to-ics`), each agenda
/// file beside itself (`org-icalendar-export-agenda-files`), or all of them in one
/// (`org-icalendar-combine-agenda-files`).
public enum ICalendarFiles {
    /// Exports `text`, the file at `path`, to `destination` or where `EXPORT_FILE_NAME` says,
    /// else beside it. `subtree` exports the subtree at that offset alone.
    @discardableResult
    public static func export(
        _ text: String, path: String, settings: OrgSettings, options: ICalendarOptions, subtree: Int? = nil, destination: URL? = nil
    ) throws -> URL {
        let target = destination ?? ExportScope.output(
            for: URL(fileURLWithPath: path), name: ExportScope.fileName(text, subtreeAt: subtree, settings: settings), extension: "ics")
        let text = ExportPreprocess.includes(text, directory: URL(fileURLWithPath: path).deletingLastPathComponent())
        let calendar = ICalendarExport.calendar(text, name: (path as NSString).lastPathComponent, settings: settings, options: options, subtree: subtree)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try calendar.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    /// Each file in `paths` to its own calendar. `read` gives a file's text and settings.
    public static func exportEach(_ paths: [String], options: ICalendarOptions, read: (String) -> (text: String, settings: OrgSettings)?) throws -> [URL] {
        try paths.compactMap { path in
            guard let file = read(path) else { return nil }
            return try export(file.text, path: path, settings: file.settings, options: options)
        }
    }

    /// The files in `paths` in one calendar at `destination`.
    @discardableResult
    public static func combine(
        _ paths: [String], to destination: String, options: ICalendarOptions, read: (String) -> (text: String, settings: OrgSettings)?
    ) throws -> URL {
        let files = paths.compactMap { path in
            read(path).map { ((path as NSString).lastPathComponent, ExportPreprocess.includes($0.text, directory: URL(fileURLWithPath: path).deletingLastPathComponent()), $0.settings) }
        }
        let url = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ICalendarExport.combined(files, options: options).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
