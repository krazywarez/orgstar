import Foundation

// Refiling, ported from org-refile.el and org.el (Org 9.8.7) with `org-log-refile` nil,
// `org-reverse-note-order` nil and `org-refile-keep` nil.

extension EmacsBuffer {
    /// `org-copy-subtree` called from Lisp: the subtree at point, with the blank lines after it.
    func copySubtree() throws -> String {
        try saveExcursion {
            let begin = try backToHeading()
            skipForward(Self.whitespace)
            endOfSubtree(toHeading: true)
            return point > begin ? substring(begin, point) : ""
        }
    }

    /// `org-map-region`.
    func mapRegion(_ begin: Int, _ end: Int, _ body: () throws -> Void) rethrows {
        try saveExcursion {
            let end = marker(end)
            defer { release(end) }
            point = begin
            if let heading = searchHeadingForward(), point < end.position {
                point = heading
                try body()
            }
            while true {
                outlineNextHeading()
                guard point < end.position, !eobp else { break }
                try body()
            }
        }
    }

    /// `org-paste-subtree` with a numeric level; `limit` ends the buffer there, as narrowing does.
    func pasteSubtree(level: Int, tree: String, limit: Int? = nil) throws {
        let oldLevel = tree.range(of: "(?m)^\\*+ ", options: .regularExpression).map { tree[$0].count - 1 } ?? -1
        let shift = oldLevel == -1 || oldLevel == level ? 0 : level - oldLevel
        if !(bolp && atHeading) {
            endOfLine()
            point = min(nextHeadingStart(after: point) ?? length, limit ?? length)
            if !bolp { insert("\n") }
        }
        var begin = point
        insert(tree)
        if !tree.hasSuffix("\n") { insert("\n") }
        let end = marker(point)
        defer { release(end) }
        point = begin
        skipForward(Self.whitespace)
        begin = point
        var remaining = shift
        while remaining != 0 {
            try mapRegion(begin, end.position) { try changeLevel(by: remaining > 0 ? 1 : -1) }
            remaining += remaining > 0 ? -1 : 1
        }
        point = begin
    }

    /// Inserts a refiled subtree as the last child of the heading at `target`, or at the end of
    /// the buffer as a top-level entry when `target` is nil.
    func refileInsert(_ tree: String, under target: Int?) throws {
        try saveExcursion {
            let level: Int
            if let target {
                point = target
                level = outlineLevel + 1
                let sibling = saveExcursion { nextSibling() }
                if let sibling { point = sibling } else { endOfSubtree(toHeading: true) }
            } else {
                level = 1
                point = length
            }
            if !bolp { insert("\n") }
            try pasteSubtree(level: level, tree: tree)
            alignTags(onLineAt: point)
        }
    }

    /// Range of the subtree at point with the blank lines after it, as org-refile deletes it.
    func subtreeRange() throws -> Range<Int> {
        try saveExcursion {
            let begin = try backToHeading()
            let end = endOfSubtree(toHeading: true)
            return begin..<end
        }
    }

    /// `org-refile` to a heading in this buffer, or to its end when `target` is nil.
    func refileWithinBuffer(to target: Int?) throws {
        let subtree = try subtreeRange()
        if let target, subtree.contains(target) {
            throw UserError(message: "Cannot refile to position inside the tree or region")
        }
        let tree = try copySubtree()
        let origin = marker(point, advances: true)
        defer { release(origin) }
        try refileInsert(tree, under: target)
        point = origin.position
        let range = try subtreeRange()
        deleteRegion(range.lowerBound, range.upperBound)
    }
}

/// C-c C-w within one file: moves the subtree at the caret under the heading starting at the
/// answer's offset, or to the end of the file for an empty answer.
public struct RefileWithinFile: OrgCommand {
    public init() {}
    public var id: String { "org.refile.local" }
    public var title: String { "Refile Within File" }
    public func applies(in context: EditContext) -> Bool { entryHeading(at: context.caret, in: context.tree) != nil }

    public func run(in context: EditContext) -> CommandStep {
        guard let answer = context.answers["refile"] else {
            return .prompt(Prompt(key: "refile", message: "Refile to:"))
        }
        return commitBuffer(context) { try $0.refileWithinBuffer(to: Int(answer)) }
    }
}

/// Refiling into another file: the edit to the source and the target's new text.
public enum Refile {
    public struct Result: Sendable, Equatable {
        public let source: EditResult
        public let target: TextEdit
    }

    public static func toOtherFile(source context: EditContext, target text: String, under heading: Int?) -> Result? {
        let target = EmacsBuffer(text, point: 0, settings: context.tree.settings, options: context.options)
        var tree = ""
        let step = commitBuffer(context) { buffer in
            tree = try buffer.copySubtree()
            try target.refileInsert(tree, under: heading)
            let range = try buffer.subtreeRange()
            buffer.deleteRegion(range.lowerBound, range.upperBound)
        }
        guard case .commit(let source) = step else { return nil }
        let edit = commitBuffer(EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [0..<0])) { buffer in
            buffer.replace(0..<buffer.length, with: target.string)
        }
        guard case .commit(let result) = edit else { return nil }
        return Result(source: source, target: result.edits.first ?? TextEdit(range: 0..<0, replacement: ""))
    }
}
