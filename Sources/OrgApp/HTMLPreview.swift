import Foundation

/// Export to HTML and Open where the page is shown from a temporary file (iOS, in Quick Look):
/// the images go in the page, as nothing is beside it there.
public enum HTMLPreview {
    /// Writes `html` (an `HTMLExport.page`) as `name` in a new temporary folder. `directory` is
    /// the Org file's folder, where relative image links are read from.
    public static func write(_ html: String, directory: URL?, name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-html-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try PDFExport.inliningImages(html, directory: directory).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
