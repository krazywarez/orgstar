import Foundation

// Converting lines between headings, items and text, commenting headings and marking subtrees
// (Org 9.8.7): `org-toggle-comment`, `org-toggle-heading` (C-c *), `org-ctrl-c-minus` with
// `org-toggle-item` and `org-cycle-list-bullet` (C-c -), `org-mark-subtree`. Without a region
// the commands work on the caret's line; a selection is the region.

/// C-c ;: `org-toggle-comment`.
public struct ToggleComment: OrgCommand {
    public init() {}
    public var id: String { "org.heading.toggle-comment" }
    public var title: String { "Toggle COMMENT" }
    public func applies(in context: EditContext) -> Bool { entryHeading(at: context.caret, in: context.tree) != nil }
    public func run(in context: EditContext) -> CommandStep {
        guard entryHeading(at: context.caret, in: context.tree) != nil else { return .failed("Before first headline") }
        return commitBuffer(context) { buffer in
            buffer.saveExcursion {
                _ = try? buffer.backToHeading()
                guard let match = buffer.lookingAt(buffer.complexHeadingPattern) else { return }
                let commented = match[4].map { buffer.substring($0.lowerBound, $0.upperBound) }.map { $0 == "COMMENT" || $0.hasPrefix("COMMENT ") } ?? false
                buffer.point = (match[3] ?? match[2] ?? match[1]!).upperBound
                buffer.skipForward(EmacsBuffer.blanks)
                if buffer.point == 0 || ![32, 9].contains(buffer.character(at: buffer.point - 1)) { buffer.insert(" ") }
                if commented {
                    let start = buffer.point
                    let end = buffer.lineEnd(start)
                    if let space = buffer.searchForward(" ", bound: end, caseInsensitive: false) {
                        buffer.point = space[0]!.upperBound
                    } else {
                        buffer.point = end
                    }
                    buffer.skipForward(EmacsBuffer.blanks)
                    buffer.deleteRegion(start, buffer.point)
                } else {
                    buffer.insert("COMMENT")
                    if !buffer.eolp { buffer.insert(" ") }
                }
            }
        }
    }
}

extension EmacsBuffer {
    /// `org-at-comment-p`.
    var atCommentLine: Bool { lookingAtLine("^[ \\t]*#(?: |$)") }

    /// The region's (or the line's) bounds as the toggles take them: from the first non-blank
    /// line, to the region's end (the line's end when it ends inside a line).
    func toggleBounds(_ selection: Range<Int>, skipComments: Bool) -> (begin: Int, end: Marker) {
        func skipBlanks(_ pos: Int) -> Int {
            saveExcursion {
                point = pos
                if skipComments { while atCommentLine, forwardLine(1) == 0 {} }
                skipForward([32, 13, 9, 10])
                return lineStart(point)
            }
        }
        if selection.isEmpty {
            return (skipBlanks(lineStart(selection.lowerBound)), marker(lineEnd(selection.lowerBound)))
        }
        let end = selection.upperBound
        let begin = skipComments ? skipBlanks(selection.lowerBound) : saveExcursion { point = selection.lowerBound; skipForward([32, 13, 9, 10]); return lineStart(point) }
        return (begin, marker(skipComments ? (lineStart(end) == end ? end : lineEnd(end)) : end))
    }

    /// `org-current-level` of point's line, or nil before the first heading.
    var levelAtPoint: Int? { beforeFirstHeading ? nil : outlineLevel }
}

/// C-c *: `org-toggle-heading`. Headings lose their stars; items become headings, their
/// checkboxes TODO or DONE; other lines become headings one level below the current entry.
public struct ToggleHeading: OrgCommand {
    public init() {}
    public var id: String { "org.heading.toggle" }
    public var title: String { "Toggle Heading" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep {
        var toggled = false
        let step = commitBuffer(context) { buffer in
            let (begin, end) = buffer.toggleBounds(context.selection.first ?? context.caret..<context.caret, skipComments: true)
            defer { buffer.release(end) }
            // Point is at the region's end, as in Emacs.
            let caret = buffer.marker(context.selection.first?.upperBound ?? buffer.point)
            defer {
                buffer.point = caret.position
                buffer.release(caret)
            }
            buffer.point = begin
            if buffer.atHeading {
                while buffer.point < end.position {
                    if buffer.atHeading, let stars = buffer.lookingAt("\\*+ ") {
                        buffer.deleteRegion(stars[0]!.lowerBound, stars[0]!.upperBound)
                        toggled = true
                    }
                    if buffer.forwardLine(1) != 0 { break }
                }
            } else if buffer.inItem() == buffer.point {
                let done = context.tree.settings.todoSequences.first?.done.first?.name ?? "DONE"
                let todo = context.tree.settings.todoSequences.first?.active.first?.name ?? "TODO"
                let structure = buffer.listStruct()
                let selected = structure.filter { $0.pos >= begin && $0.pos < end.position }
                let base = selected.map(\.ind).min() ?? 0
                // Org takes the level after deleting the items: that of whatever follows them
                // (a heading's own, or its section's), one deeper.
                let bottom = structure.map(\.end).max() ?? end.position
                let level = buffer.saveExcursion { () -> Int in
                    buffer.point = min(bottom, end.position + 1, buffer.length)
                    return buffer.beforeFirstHeading ? 0 : buffer.outlineLevel
                }
                // The last first, so earlier positions stay.
                for item in selected.reversed() {
                    let depth = Set(selected.filter { $0.ind < item.ind && $0.ind >= base }.map(\.ind)).count
                    buffer.point = item.pos
                    let lineEnd = buffer.lineEnd(item.pos)
                    var text = buffer.substring(item.pos, lineEnd)
                    text = text.replacingOccurrences(of: "^[ \\t]*\\S+[ \\t]+(\\[@[^\\]]*\\][ \\t]*)?", with: "", options: .regularExpression)
                    var keyword = ""
                    if let box = item.checkbox {
                        text = text.replacingOccurrences(of: "^\\[[ X-]\\][ \\t]*", with: "", options: .regularExpression)
                        keyword = (box == "[X]" ? done : todo) + " "
                    }
                    buffer.deleteRegion(item.pos, lineEnd)
                    buffer.insert(String(repeating: "*", count: level + 1 + depth) + " " + keyword + text)
                    toggled = true
                }
                // Org replaces the items as one piece, so a point inside them ends at its start.
                if let first = selected.first, caret.position > first.pos { caret.position = first.pos }
            } else {
                let stars = String(repeating: "*", count: buffer.levelAtPoint ?? 0) + "*" + " "
                while buffer.point < end.position {
                    if !buffer.atHeading, buffer.inItem() != buffer.point, !buffer.atCommentLine,
                       let match = buffer.lookingAt("([ \\t]*)(\\S)") {
                        buffer.deleteRegion(match[1]!.lowerBound, match[1]!.upperBound)
                        buffer.point = buffer.lineStart(buffer.point)
                        buffer.insert(stars)
                        toggled = true
                    }
                    if buffer.forwardLine(1) != 0 { break }
                }
            }
        }
        if case .commit = step, !toggled { return .failed("Cannot toggle heading from here") }
        return step
    }
}

/// C-c - outside tables: `org-ctrl-c-minus`. On an item without a region the list's bullets
/// cycle (`org-cycle-list-bullet`); otherwise `org-toggle-item`: items lose their bullets,
/// headings become items with their text, other lines become items.
public struct ToggleItem: OrgCommand {
    public init() {}
    public var id: String { "org.item.toggle" }
    public var title: String { "Toggle Item" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep {
        let region = context.selection.first.map { !$0.isEmpty } ?? false
        if !region, EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings).inItem() != nil {
            return commitBuffer(context) { try $0.cycleListBullet() }
        }
        return commitBuffer(context) { buffer in
            let (begin, end) = buffer.toggleBounds(context.selection.first ?? context.caret..<context.caret, skipComments: false)
            defer { buffer.release(end) }
            // Point is at the region's end, as in Emacs.
            let caret = buffer.marker(context.selection.first?.upperBound ?? buffer.point)
            defer {
                buffer.point = caret.position
                buffer.release(caret)
            }
            buffer.point = begin
            if buffer.inItem() == buffer.point {
                while buffer.point < end.position {
                    if buffer.inItem() == buffer.point, let match = buffer.lookingAt("[ \\t]*(\\S+[ \\t]+)") {
                        buffer.deleteRegion(match[1]!.lowerBound, match[1]!.upperBound)
                    }
                    if buffer.forwardLine(1) != 0 { break }
                }
            } else if buffer.atHeading {
                let refLevel = buffer.outlineLevel
                var reference = refLevel
                while buffer.point < end.position {
                    guard buffer.atHeading else {
                        if buffer.forwardLine(1) != 0 { break }
                        continue
                    }
                    let level = buffer.outlineLevel
                    let delta = max(0, level - reference)
                    if level < reference { reference = level }
                    let todo = buffer.todoKeyword
                    buffer.deleteMetadata()
                    guard let match = buffer.lookingAt(buffer.todoLinePattern) else { break }
                    buffer.deleteRegion(buffer.point, match[3]?.lowerBound ?? buffer.lineEnd(buffer.point))
                    buffer.insert("- ")
                    buffer.indentLineTo(delta * 2)
                    if let todo {
                        // The checkbox goes through the list's repair, with any list above.
                        buffer.point = buffer.lineStart(buffer.point)
                        let at = buffer.point
                        var structure = buffer.listStruct()
                        let old = structure
                        structure.set(at) { $0.checkbox = context.tree.settings.isDone(todo) ? "[X]" : "[ ]" }
                        buffer.writeStruct(&structure, structure.parents, old: old)
                        buffer.point = at
                    }
                    // The section's text down to the region's end belongs to the item.
                    let sectionEnd = buffer.saveExcursion { () -> Int in
                        Capture.nextHeading(buffer)
                        return buffer.point
                    }
                    if buffer.forwardLine(1) != 0 { break }
                    buffer.shiftText(to: (delta + 1) * 2, until: min(end.position, sectionEnd))
                }
            } else {
                while buffer.point < end.position {
                    if !buffer.atHeading, buffer.inItem() != buffer.point, let match = buffer.lookingAt("([ \\t]*)(\\S)") {
                        buffer.point = match[2]!.lowerBound
                        buffer.insert("- ")
                        buffer.point = buffer.lineStart(buffer.point)
                    }
                    if buffer.forwardLine(1) != 0 { break }
                }
            }
        }
    }
}

extension EmacsBuffer {
    /// `org-list--delete-metadata`: the heading's tags, planning line and property drawer go.
    func deleteMetadata() {
        saveExcursion {
            let start = point
            if let line = lookingAt(SetTags.tagLine), let tags = line[1] {
                var from = tags.lowerBound
                while from > start, let c = character(at: from - 1), c == 32 || c == 9 { from -= 1 }
                deleteRegion(from, lineEnd(start))
            }
            point = start
            let afterHeading = lineEnd(start) < length ? lineEnd(start) + 1 : length
            point = afterHeading
            if lookingAt(Self.planningLinePattern) != nil { forwardLine(1) }
            if let drawer = looking(Self.propertyDrawerPattern) {
                point = drawer[0]!.upperBound
                forwardLine(1)
            }
            skipForward([32, 9, 10, 13])
            let end = eobp ? point : lineStart(point)
            if end > afterHeading { deleteRegion(afterHeading, end) }
        }
    }

    /// The `shift-text` of `org-toggle-item`: lines from point to `end` move so the least
    /// indented one sits at `column`; blank lines and headings stay. Point ends at `end`'s line.
    func shiftText(to column: Int, until limit: Int) {
        let end = marker(limit)
        defer { release(end) }
        var minimum = 1000
        saveExcursion {
            while point < end.position {
                let indentation = currentIndentation
                if lookingAt("^[ \\t]*$") != nil || atHeading {
                } else if indentation == 0 {
                    minimum = 0
                    break
                } else if indentation < minimum {
                    minimum = indentation
                }
                if forwardLine(1) != 0 { break }
            }
        }
        let delta = column - minimum
        while point < end.position {
            if lookingAt("^[ \\t]*$") == nil, !atHeading { indentLineTo(currentIndentation + delta) }
            if forwardLine(1) != 0 { break }
        }
    }

    var currentIndentation: Int {
        saveExcursion {
            point = lineStart(point)
            skipForward([32, 9])
            return currentColumn
        }
    }

    /// `org-cycle-list-bullet`: the list's bullets go through `-`, `+`, `*` (not at the
    /// margin), `1.`, `1)` and, with alphabetical lists, `a.`, `A.`, `a)`, `A)`.
    func cycleListBullet() throws {
        guard let item = inItem() else { throw UserError(message: "Not at an item") }
        let origin = marker(point)
        defer { release(origin) }
        point = item
        var structure = listStruct()
        let prevs = structure.prevs
        let parents = structure.parents
        let first = structure.listBegin(point, prevs)
        let ind = structure.ind(point)
        let bulletLength = (structure.bullet(point) as NSString).length
        let offset = origin.position - (point + ind)
        let offset2 = origin.position - (point + ind + bulletLength)
        let bullet = structure.bullet(first)
        let alpha = useAlphabeticalBullets(first, structure, prevs)
        func has(_ pattern: String) -> Bool { bullet.range(of: pattern, options: .regularExpression) != nil }
        let current = has("[a-z]\\.") ? "a." : has("[a-z]\\)") ? "a)" : has("[A-Z]\\.") ? "A." : has("[A-Z]\\)") ? "A)"
            : has("\\.") ? "1." : has("\\)") ? "1)" : bullet.trimmingCharacters(in: .whitespaces)
        let description = structure.item(point)?.tag != nil
        var choices = ["-", "+"]
        if lookingAt("\\S") == nil { choices.append("*") }
        if !description { choices += ["1.", "1)"] }
        if alpha, !description { choices += ["a.", "A.", "a)", "A)"] }
        let index = choices.firstIndex(of: current).map { $0 + 1 } ?? choices.count
        let new = choices[index % choices.count]
        let old = structure
        structure.set(first) { $0.bullet = bulletString(new) }
        fixBullets(&structure, prevs)
        fixIndentation(&structure, parents)
        applyStruct(structure, old)
        point = origin.position
        let updated = listStruct()
        point = lineStart(point)
        if offset2 >= 0, let at = updated.item(point) {
            point += at.ind + (at.bullet as NSString).length + offset2
        } else if offset >= 0, let at = updated.item(point) {
            point += at.ind + offset
        } else {
            point = origin.position
        }
    }
}

/// C-c @ (and the speed key @) on a heading: `org-mark-subtree`, the subtree selected from its heading.
public struct MarkSubtree: OrgCommand {
    public init() {}
    public var id: String { "org.subtree.mark" }
    public var title: String { "Mark Subtree" }
    public func applies(in context: EditContext) -> Bool { entryHeading(at: context.caret, in: context.tree) != nil }
    public func run(in context: EditContext) -> CommandStep {
        let buffer = EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings)
        guard !buffer.beforeFirstHeading, (try? buffer.backToHeading()) != nil else { return .failed("Not in a subtree") }
        let start = buffer.point
        Capture.endOfSubtree(buffer, heading: start)
        return .commit(EditResult(baseRevision: context.revision, edits: [], selection: [start..<buffer.point]))
    }
}
