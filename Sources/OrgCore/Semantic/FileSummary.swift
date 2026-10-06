import Foundation

/// What Spotlight shows and searches for a file: its keywords, tags and headings.
public struct FileSummary: Sendable, Equatable {
    public var title: String?
    public var author: String?
    public var description: String?
    /// `#+FILETAGS` and every heading's tags, in order, once each.
    public var tags: [String]
    /// Heading titles, with TODO keywords, priorities and tags left out.
    public var headings: [String]

    public init(_ text: String) {
        let tree = OrgParser.parse(text)
        func keyword(_ name: String) -> String? {
            let pattern = "^[ \\t]*#\\+" + name + ":[ \\t]*(.*?)[ \\t]*$"
            guard let m = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines, .caseInsensitive])
                .firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
            let value = (text as NSString).substring(with: m.range(at: 1))
            return value.isEmpty ? nil : value
        }
        title = keyword("TITLE")
        author = keyword("AUTHOR")
        description = keyword("DESCRIPTION")
        let model = DocumentModel(tree: tree)
        var tags = (keyword("FILETAGS") ?? "").split { $0 == ":" || $0 == " " }.map(String.init)
        for heading in model.headings { tags += heading.localTags }
        var seen = Set<String>()
        self.tags = tags.filter { seen.insert($0).inserted }
        headings = model.headings.map { Links.normalizedTitle($0.title) }
    }
}
