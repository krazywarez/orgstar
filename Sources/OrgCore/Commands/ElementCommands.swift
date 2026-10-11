import Foundation

// Org 9.8.7: `org-insert-drawer` (C-c C-x d), `org-drag-element-forward` and
// `org-drag-element-backward` (M-<down> and M-<up> away from headings, items and tables), and
// `org-cycle-list-bullet` both ways (S-<right> and S-<left> on items).

/// C-c C-x d: `org-insert-drawer`. Asks for the name; inserts an empty drawer at the caret,
/// or puts the selected lines in it.
public struct InsertDrawer: OrgCommand {
    public init() {}
    public var id: String { "org.drawer.insert" }
    public var title: String { "Insert Drawer" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep {
        guard let name = context.answers["drawer"] else { return .prompt(Prompt(key: "drawer", message: "Drawer:")) }
        guard (":" + name + ":").range(of: "^:[-_\\w]+:$", options: .regularExpression) != nil else { return .failed("Invalid drawer name") }
        let region = context.selection.first.flatMap { $0.isEmpty ? nil : $0 }
        return commitBuffer(context) { buffer in
            guard let region else {
                if !buffer.bolp { buffer.insert("\n") }
                buffer.insert(":\(name):\n\n:END:\n")
                buffer.forwardLine(-2)
                return
            }
            let end = buffer.marker(region.upperBound)
            defer { buffer.release(end) }
            buffer.point = buffer.lineStart(region.lowerBound)
            if buffer.searchForward("^\\*+ ", bound: end.position, caseInsensitive: false) != nil {
                throw EmacsBuffer.UserError(message: "Drawers cannot contain headlines")
            }
            // The drawer opens on the region's first non-blank line and closes after its last,
            // at the section's indentation, and the caret ends before `:END:`.
            buffer.point = region.lowerBound
            buffer.skipForward([32, 9, 10, 13])
            buffer.point = buffer.lineStart(buffer.point)
            buffer.insert(":\(name):\n")
            buffer.point = end.position
            buffer.skipBackward([32, 9, 10, 13])
            buffer.insert("\n:END:")
            if !buffer.eolp { buffer.insert("\n") }
            buffer.point = buffer.lineStart(buffer.point) - 1
            if buffer.lookingAtLine("^:END:") == nil { buffer.point = buffer.lineStart(max(0, buffer.point - 1)) - 1 }
        }
    }
}

/// M-<down> and M-<up> on other elements: `org-drag-element-forward` and
/// `org-drag-element-backward`, the element swapped with the next or previous one in the same
/// section, drawer or block, the blank lines between them kept.
public struct DragElement: OrgCommand {
    public let forward: Bool
    public init(forward: Bool) { self.forward = forward }
    public var id: String { forward ? "org.element.drag-forward" : "org.element.drag-backward" }
    public var title: String { forward ? "Drag Element Forward" : "Drag Element Backward" }
    public func applies(in context: EditContext) -> Bool { true }

    /// An element with its affiliated keywords, the blank lines after it, and where its own
    /// text ends (the end of its last non-blank line).
    struct Unit {
        let begin: Int
        var end: Int
        let bodyEnd: Int
        let node: SyntaxNode
        let isHeading: Bool
    }

    /// The elements of `container`, whose ranges count from `base` in `ns`.
    static func units(_ container: SyntaxNode, _ ns: NSString, base: Int = 0) -> [Unit] {
        var units: [Unit] = []
        var affiliated: Int?
        for child in container.children {
            if child.kind == .heading, child.range.lowerBound == container.range.lowerBound { continue }
            if child.kind == .affiliatedKeyword {
                affiliated = affiliated ?? base + child.range.lowerBound
                continue
            }
            if child.kind == .zerothSection {
                units += Self.units(child, ns, base: base)
                continue
            }
            var bodyEnd = base + child.range.upperBound
            while bodyEnd > base + child.range.lowerBound, [10, 13, 32, 9].contains(ns.character(at: bodyEnd - 1)) { bodyEnd -= 1 }
            let begin = affiliated ?? base + child.range.lowerBound
            affiliated = nil
            if var last = units.popLast() {
                last.end = begin
                units.append(last)
            }
            units.append(Unit(begin: begin, end: base + container.range.upperBound, bodyEnd: bodyEnd, node: child, isHeading: child.kind == .section || child.kind == .heading))
        }
        return units
    }

    /// A drawer or a block other than src, example, export, comment and verse: its lines are
    /// elements.
    static func isGreater(_ node: SyntaxNode) -> Bool {
        if node.kind == .drawer { return true }
        guard node.kind == .block, let type = node.text.firstMatch(of: /^[ \t]*#\+(?i:begin)_(\S+)/)?.1.lowercased() else { return false }
        return !["src", "example", "export", "comment", "verse"].contains(type)
    }

    /// The element `org-element-at-point` finds at `offset`, with its siblings: the deepest
    /// section, drawer or greater block's units, and its place among them.
    static func locate(_ offset: Int, tree: OrgTree, text: NSString) -> (units: [Unit], index: Int)? {
        // The innermost section (or the text before the first heading) holding the offset.
        var container = tree.root
        func holds(_ node: SyntaxNode) -> Bool {
            node.range.lowerBound <= offset && (offset < node.range.upperBound || (offset == node.range.upperBound && offset == text.length))
        }
        while let section = container.children.first(where: { ($0.kind == .section || $0.kind == .zerothSection) && holds($0) }) { container = section }
        var base = 0
        while true {
            let units = Self.units(container, text, base: base)
            guard let index = units.lastIndex(where: { $0.begin <= offset }) else { return nil }
            let unit = units[index]
            // Inside a drawer or a greater block, below its first line and above its last: its
            // contents' elements.
            let opening = NSMaxRange(text.lineRange(for: NSRange(location: base + unit.node.range.lowerBound, length: 0)))
            let closing = text.lineRange(for: NSRange(location: unit.bodyEnd, length: 0)).location
            if Self.isGreater(unit.node), offset >= opening, offset < closing {
                let inner = OrgParser.parse(text.substring(with: NSRange(location: opening, length: closing - opening)))
                guard !Self.units(inner.root, text, base: opening).isEmpty else { return (units, index) }
                container = inner.root
                base = opening
                continue
            }
            return (units, index)
        }
    }

    public func run(in context: EditContext) -> CommandStep {
        let ns = context.text as NSString
        let caret = context.caret
        let failure = forward ? "Cannot drag element forward" : "Cannot drag element backward"
        guard let (units, index) = Self.locate(caret, tree: context.tree, text: ns), !units[index].isHeading else { return .failed(failure) }
        let other = forward ? index + 1 : index - 1
        guard units.indices.contains(other), !units[other].isHeading else { return .failed(failure) }
        let (a, b) = forward ? (units[index], units[other]) : (units[other], units[index])
        let bodyA = ns.substring(with: NSRange(location: a.begin, length: a.bodyEnd - a.begin))
        let bodyB = ns.substring(with: NSRange(location: b.begin, length: b.bodyEnd - b.begin))
        let middle = ns.substring(with: NSRange(location: a.bodyEnd, length: b.begin - a.bodyEnd))
        let edit = TextEdit(range: a.begin..<b.bodyEnd, replacement: bodyB + middle + bodyA)
        let newCaret: Int
        if forward {
            let lineAfterB = b.bodyEnd < ns.length ? b.bodyEnd + 1 : b.bodyEnd
            let lineAfterA = a.bodyEnd < ns.length ? a.bodyEnd + 1 : a.bodyEnd
            newCaret = caret + (lineAfterB - b.begin) + (a.end - lineAfterA)
        } else {
            newCaret = a.begin + (caret - b.begin)
        }
        return .commit(EditResult(baseRevision: context.revision, edits: [edit], selection: [newCaret..<newCaret]))
    }
}

/// S-<right> and S-<left> on an item: `org-cycle-list-bullet`, the list's bullets to the next
/// kind, or with `previous` the one before.
public struct CycleBullet: OrgCommand {
    public let previous: Bool
    public init(previous: Bool) { self.previous = previous }
    public var id: String { previous ? "org.item.bullet-previous" : "org.item.bullet-next" }
    public var title: String { previous ? "Previous Bullet Type" : "Next Bullet Type" }
    public func applies(in context: EditContext) -> Bool {
        EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings).inItem() != nil
    }
    public func run(in context: EditContext) -> CommandStep {
        commitBuffer(context) { try $0.cycleListBullet(previous: previous) }
    }
}
