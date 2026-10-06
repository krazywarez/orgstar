import Foundation

/// The regions `org-narrow-to-subtree` and `org-narrow-to-block` (Org 9.8.7) narrow to. The
/// editor shows only that text until `widen`.
public enum Narrowing {
    public struct Failure: Error, Equatable {
        public let message: String
    }

    /// `org-narrow-to-subtree`: the heading at or above `offset` and its subtree, without the
    /// newline before the next heading.
    public static func subtree(at offset: Int, in text: String) throws -> Range<Int> {
        let buffer = EmacsBuffer(text, point: offset)
        guard (try? buffer.backToHeading()) != nil else { throw Failure(message: "Before first headline") }
        let start = buffer.point
        buffer.endOfSubtree(toHeading: true)
        if buffer.atHeading, !buffer.eobp { buffer.point -= 1 }
        return start..<buffer.point
    }

    /// `org-narrow-to-block` through `org-narrow-to-element`: a src, example, export, comment
    /// or verse block with the blank lines after it; for other blocks, from their opening or
    /// closing line, the lines between.
    public static func block(at offset: Int, in text: String) throws -> Range<Int> {
        let tree = OrgParser.parse(text)
        let buffer = EmacsBuffer(text, point: offset)
        var probe = offset
        // Blank lines after a block belong to it.
        if buffer.lookingAtLine("^[ \\t]*$") {
            buffer.point = buffer.lineStart(offset)
            buffer.skipBackward([32, 9, 10, 13])
            probe = buffer.lineStart(buffer.point)
        }
        let objects: Set<SyntaxKind> = [.bold, .italic, .underline, .strikeThrough, .verbatim, .code, .link, .linkDescription, .timestamp,
                                        .footnoteReference, .statisticsCookie, .target, .macro, .inlineSourceBlock, .latexFragment, .lineBreak, .superscript, .subscript, .entity, .radioTarget]
        var chain: [SyntaxNode] = []
        var node = tree.root
        while let child = node.child(containing: probe) {
            chain.append(child)
            node = child
        }
        guard let block = chain.last(where: { !objects.contains($0.kind) }), block.kind == .block,
              let wrapper = Wrappers.starting(at: block.range.lowerBound, in: tree) else { throw Failure(message: "Not in a block") }
        let opening = buffer.substring(block.range.lowerBound, buffer.lineEnd(block.range.lowerBound))
        let name = opening.firstMatch(of: /(?i)#\+begin_(\S*)/).map { $0.1.lowercased() } ?? ""
        let contentsBegin = min(buffer.length, buffer.lineEnd(block.range.lowerBound) + 1)
        if ["src", "example", "export", "comment", "verse"].contains(name) {
            buffer.point = wrapper.closeLine
            buffer.forwardLine(1)
            while !buffer.eobp, buffer.lookingAt("[ \\t]*$") != nil, buffer.forwardLine(1) == 0 {}
            return block.range.lowerBound..<buffer.point
        }
        guard probe < contentsBegin || probe >= wrapper.closeLine, contentsBegin < wrapper.closeLine else { throw Failure(message: "Not in a block") }
        return contentsBegin..<wrapper.closeLine
    }
}

/// C-c C-j: `org-goto` with `outline-path-completion`: a heading of this file by its path.
public struct GotoHeading: OrgCommand {
    public init() {}
    public var id: String { "org.goto" }
    public var title: String { "Go to Heading…" }
    public func applies(in context: EditContext) -> Bool { true }

    static func targets(_ context: EditContext) -> [(path: String, start: Int)] {
        let model = DocumentModel(tree: context.tree)
        var seen: Set<String> = []
        return model.headings.indices.compactMap { index in
            let path = model.outlinePath(of: index).map(Self.plainTitle).joined(separator: "/")
            guard seen.insert(path).inserted else { return nil }
            return (path, model.headings[index].headingRange.lowerBound)
        }
    }

    /// The title as completion shows it: links as their descriptions, no trailing blanks.
    static func plainTitle(_ title: String) -> String {
        Links.displayFormat(title).trimmingCharacters(in: .whitespaces)
    }

    public func run(in context: EditContext) -> CommandStep {
        let targets = Self.targets(context)
        guard !targets.isEmpty else { return .failed("No headings") }
        guard let answer = context.answers["goto"] else {
            return .prompt(Prompt(key: "goto", message: "Goto:", choices: targets.map(\.path)))
        }
        guard let target = targets.first(where: { $0.path == answer }) else { return .failed("No such heading") }
        return .commit(EditResult(baseRevision: context.revision, edits: [], selection: [target.start..<target.start]))
    }
}
