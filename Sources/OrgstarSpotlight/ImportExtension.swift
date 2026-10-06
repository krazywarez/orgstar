import CoreSpotlight
import Foundation
import OrgCore

/// Spotlight's importer for org files: the text, plus the title, author, tags and headings.
@objc(ImportExtension)
final class ImportExtension: CSImportExtension {
    override func update(_ attributes: CSSearchableItemAttributeSet, forFileAt contentURL: URL) throws {
        let text = try String(contentsOf: contentURL, encoding: .utf8)
        let summary = FileSummary(text)
        attributes.textContent = text
        attributes.title = summary.title ?? contentURL.deletingPathExtension().lastPathComponent
        if let author = summary.author { attributes.authorNames = [author] }
        if let description = summary.description { attributes.contentDescription = description }
        attributes.keywords = summary.tags + summary.headings
    }
}
