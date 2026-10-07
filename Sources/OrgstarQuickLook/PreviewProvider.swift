import Foundation
import OrgCore
#if canImport(QuickLookUI)
import QuickLookUI
#else
import QuickLook
#endif

/// Quick Look's preview of an org file: the file as the HTML export renders it.
@objc(PreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let text = try String(contentsOf: request.fileURL, encoding: .utf8)
        let title = request.fileURL.deletingPathExtension().lastPathComponent
        let html = HTMLExport.page(text, fallbackTitle: title, settings: OrgSettings.default.resolvingSetupFiles(in: text, path: request.fileURL.path, read: OrgSettings.readFile), path: request.fileURL.path)
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 800, height: 800)) { _ in Data(html.utf8) }
    }
}
