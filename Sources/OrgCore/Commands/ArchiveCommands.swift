import Foundation

// Archiving in place (org-archive.el, Org 9.8.7): `org-toggle-archive-tag` and
// `org-archive-to-archive-sibling` with `org-archive-sibling-heading` "Archive" and
// `org-archive-reversed-order` nil.

/// C-c C-x a: `org-toggle-archive-tag`. Setting the tag folds the subtree.
public struct ToggleArchiveTag: OrgCommand {
    public init() {}
    public var id: String { "org.archive.toggle-tag" }
    public var title: String { "Toggle ARCHIVE Tag" }
    public func applies(in context: EditContext) -> Bool { entryHeading(at: context.caret, in: context.tree) != nil }
    public func run(in context: EditContext) -> CommandStep {
        guard let heading = entryHeading(at: context.caret, in: context.tree) else { return .failed("Before first headline") }
        var tags = HeadingLine(heading).tags.map { (context.text as NSString).substring(with: NSRange($0.range)).split(separator: ":").map(String.init) } ?? []
        let set = !tags.contains("ARCHIVE")
        if set { tags.append("ARCHIVE") } else { tags.removeAll { $0 == "ARCHIVE" } }
        guard case .commit(let result) = SetTags.set(tags, in: context) else { return SetTags.set(tags, in: context) }
        let start = heading.range.lowerBound
        var effects = result.effects + [.message("Subtree \(set ? "archived" : "unarchived")")]
        var selection = [context.caret..<context.caret]
        if set {
            effects.insert(.fold(start), at: 0)
            let line = (context.text as NSString).lineRange(for: NSRange(location: context.caret, length: 0)).location
            selection = [line..<line]
        }
        return .commit(EditResult(baseRevision: result.baseRevision, edits: result.edits, selection: selection, effects: effects))
    }
}

/// C-c C-x A: `org-archive-to-archive-sibling`.
public struct ArchiveToSibling: OrgCommand {
    public init() {}
    public var id: String { "org.archive.to-sibling" }
    public var title: String { "Archive to Archive Sibling" }
    public func applies(in context: EditContext) -> Bool { entryHeading(at: context.caret, in: context.tree) != nil }

    public func run(in context: EditContext) -> CommandStep {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = context.calendar
        formatter.timeZone = context.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd EEE HH:mm"
        let time = formatter.string(from: context.now)
        var sibling = 0
        let step = commitBuffer(context) { buffer in
            try buffer.backToHeading()
            let level = buffer.outlineLevel
            let leader = String(repeating: "*", count: level) + " "
            let pos = buffer.marker(buffer.point, advances: true)
            defer { buffer.release(pos) }
            var end: Int?
            if buffer.upHeadingSafe() == nil {
                end = buffer.length
                buffer.point = 0
            }
            let begin = buffer.point
            let e = buffer.marker(end ?? buffer.saveExcursion { buffer.endOfSubtree(toHeading: true) })
            defer { buffer.release(e) }
            buffer.point = begin
            let pattern = "^" + NSRegularExpression.escapedPattern(for: leader) + "[ \\t]*Archive[ \\t]*:ARCHIVE:"
            if buffer.searchForward(pattern, bound: e.position, caseInsensitive: false) == nil {
                buffer.point = e.position
                if !buffer.bolp { buffer.insert("\n") }
                buffer.insert(leader + "Archive\n")
                buffer.forwardLine(-1)
                buffer.endOfLine()
                buffer.insert(" :ARCHIVE:")
                buffer.alignTags(onLineAt: buffer.point)
            }
            buffer.beginningOfLine()
            let archive = buffer.marker(buffer.point)
            defer { buffer.release(archive) }
            buffer.endOfSubtree(toHeading: true)
            let target = buffer.marker(buffer.point)
            defer { buffer.release(target) }
            // `org-cut-subtree` at the entry, then `org-paste-subtree` one level below.
            buffer.point = pos.position
            let tree = try buffer.copySubtree()
            let range = try buffer.subtreeRange()
            buffer.deleteRegion(range.lowerBound, range.upperBound)
            buffer.point = target.position
            try buffer.pasteSubtree(level: level + 1, tree: tree)
            buffer.entryPut("ARCHIVE_TIME", time)
            buffer.point = archive.position
            sibling = archive.position
            buffer.updateParentTodoStatistics()
            buffer.point = pos.position
            if buffer.lookingAt("[ \\t]*$") != nil, let next = buffer.nextHeadingStart(after: buffer.point) { buffer.point = next }
        }
        guard case .commit(let result) = step else { return step }
        return .commit(EditResult(baseRevision: result.baseRevision, edits: result.edits, selection: result.selection, effects: result.effects + [.fold(sibling)]))
    }
}
