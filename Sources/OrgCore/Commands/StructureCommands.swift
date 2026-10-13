import Foundation

// Structure commands, ported from Org 9.8.7 onto `EmacsBuffer` and matched to Emacs by the
// oracle tests. Defaults as in org: `org-blank-before-new-entry` heading `auto`,
// `org-M-RET-may-split-line` t, `org-auto-align-tags` t.

extension EmacsBuffer {
    /// `org--blank-before-heading-p` for headings.
    var blankBeforeHeading: Bool {
        saveExcursion {
            if beforeFirstHeading, !outlineNextHeading() { return false }
            _ = try? backToHeading()
            if !bobp { return previousLineEmpty }
            if outlineNextHeading() { return previousLineEmpty }
            skipBackward(Self.blanks)
            return bolp ? previousLineEmpty : false
        }
    }

    /// `org-N-empty-lines-before-current`.
    func emptyLinesBeforeCurrent(_ n: Int) {
        let column = currentColumn
        forwardLine(0)
        if !bobp {
            let start = saveExcursion {
                skipBackward(Self.whitespace)
                return lineEnd(point)
            }
            deleteRegion(start, point - 1)
        }
        insert(String(repeating: "\n", count: n))
        moveToColumn(column)
    }

    /// The blank line `org-insert-heading` keeps before the next heading.
    func addBlankAfter(_ blank: Bool) {
        saveExcursion {
            endOfLine()
            guard !eobp else { return }
            point += 1
            if blank, atHeading { insert("\n") }
        }
    }

    /// `org-insert-heading` with no prefix, or with `respectContent` as C-RET.
    func insertHeading(respectContent: Bool, hidden: [Range<Int>]) throws {
        let blank = blankBeforeHeading
        let level = currentLevel
        let stars = String(repeating: "*", count: level ?? 1)
        // The caret at the end of a folded heading's line, just before its hidden body, is where
        // Emacs's point sits behind the ellipsis.
        let invisible = hidden.contains { $0.contains(max(point - 1, 0)) || (!$0.isEmpty && $0.lowerBound == point + 1 && atHeading && eolp) }
        if respectContent || invisible {
            if level == nil {
                outlineNextHeading()
            } else {
                try backToHeading()
                endOfSubtree(toHeading: true)
            }
            if !bolp { insert("\n") }
            if blank, saveExcursion({ point -= 1; return beforeFirstHeading }) {
                insert("\n")
                point -= 1
            }
            if level == nil, !eobp, !bobp {
                if atHeading { insert("\n") }
                point -= 1
            }
            if !(blank && previousLineEmpty) { emptyLinesBeforeCurrent(blank ? 1 : 0) }
            insert(stars + " \n")
            point -= 1
            addBlankAfter(blank)
        } else if atHeading {
            if bolp {
                if blank { saveExcursion { insert("\n") } }
                saveExcursion { insert(stars + " \n") }
                if !(blank && previousLineEmpty) { emptyLinesBeforeCurrent(blank ? 1 : 0) }
                endOfLine()
            } else if options.metaReturnMaySplitLine,
                      let match = saveExcursion({ () -> [Range<Int>?]? in beginningOfLine(); return lookingAt(complexHeadingPattern) }),
                      let title = match[4], title.lowerBound <= point, point <= title.upperBound {
                let split = substring(point, title.upperBound)
                deleteRegion(point, title.upperBound)
                if let blanks = lookingAt("[ \\t]*$") {
                    deleteRegion(blanks[0]!.lowerBound, blanks[0]!.upperBound)
                } else {
                    alignTags(onLineAt: point)
                }
                endOfLine()
                if blank { insert("\n") }
                insert("\n" + stars + " ")
                addBlankAfter(blank)
                if split.contains(where: { !$0.isWhitespace }) { insert(split) }
            } else {
                endOfLine()
                if blank { insert("\n") }
                insert("\n" + stars + " ")
                addBlankAfter(blank)
            }
        } else if bolp {
            insert(stars + " ")
            if !(blank && previousLineEmpty) { emptyLinesBeforeCurrent(blank ? 1 : 0) }
            addBlankAfter(blank)
        } else {
            if !options.metaReturnMaySplitLine { endOfLine() }
            insert("\n" + stars + " ")
            if !(blank && previousLineEmpty) { emptyLinesBeforeCurrent(blank ? 1 : 0) }
            addBlankAfter(blank)
        }
    }

    /// `org-forward-heading-same-level` over all headings, visible or not.
    func forwardHeadingSameLevel(_ count: Int) throws {
        let backward = count < 0
        if beforeFirstHeading {
            if backward { point = 0 } else { outlineNextHeading() }
            return
        }
        try backToHeading()
        if !backward { endOfLine() }
        let level = currentLevel ?? 0
        var remaining = abs(count)
        var result = point
        while remaining > 0, let found = backward ? searchHeadingBackward() : searchHeadingForward() {
            let l = headingLevel(atLine: found)!
            if l < level {
                remaining = 0
            } else if l == level {
                remaining -= 1
                result = point
            }
        }
        point = result
        forwardLine(0)
    }

    /// `re-search-forward "^\\*+ " nil 'move`: point to the match end, or the buffer end.
    /// Returns the heading's line start.
    func searchHeadingForward() -> Int? {
        var line = bolp ? point : lineEnd(point) + 1
        while line <= length {
            if let level = headingLevel(atLine: line) {
                point = line + level + 1
                return line
            }
            line = lineEnd(line) + 1
        }
        point = length
        return nil
    }

    /// `re-search-backward "^\\*+ " nil 'move`: point to the match start, or the buffer start.
    /// The match must end by point.
    func searchHeadingBackward() -> Int? {
        var line = lineStart(point)
        if let level = headingLevel(atLine: line), line + level + 1 <= point {
            point = line
            return line
        }
        while line > 0 {
            line = lineStart(line - 1)
            if headingLevel(atLine: line) != nil {
                point = line
                return line
            }
        }
        point = 0
        return nil
    }

    /// `org-promote` or `org-demote` on the heading at point.
    func changeLevel(by delta: Int) throws {
        try saveExcursion {
            try backToHeading()
            let level = headingLevel(atLine: point)!
            guard level + delta >= 1 else { throw UserError(message: "Cannot promote to level 0.  UNDO to recover if necessary") }
            replace(point..<(point + level + 1), with: String(repeating: "*", count: level + delta) + " ")
            alignTags(onLineAt: point)
        }
    }

    /// `org-fix-position-after-promote`.
    func fixPositionAfterPromote() {
        let position = point
        let match = saveExcursion { () -> [Range<Int>?]? in
            forwardLine(0)
            return lookingAt(todoLinePattern)
        }
        guard let match, match[1]?.upperBound == position || match[2]?.upperBound == position else { return }
        if eobp || eolp {
            insert(" ")
        } else if character(at: point) == 32 {
            point += 1
        }
    }

    /// `org-map-tree` over the subtree at point.
    func mapTree(_ body: () throws -> Void) throws {
        try backToHeading()
        let level = outlineLevel
        try saveExcursion {
            try body()
            while true {
                outlineNextHeading()
                guard outlineLevel > level, !eobp else { break }
                try body()
            }
        }
    }

    /// `org-back-over-empty-lines` with blank lines before headings on (`auto`).
    func backOverEmptyLines() {
        let position = point
        skipBackward(Self.whitespace)
        forwardLine(1)
        point = min(point, position)
    }

    /// `org-move-subtree-down`; negative counts move up.
    func moveSubtree(_ count: Int) throws {
        let column = currentColumn
        try backToHeading()
        let begin = point
        endOfSubtree(toHeading: true)
        if !eobp { point -= 1 }
        outlineNextHeading()
        let end = point
        point = begin
        for _ in 0..<abs(count) {
            let found = count > 0 ? nextSibling() : previousSibling()
            guard found != nil, atHeading, bolp else {
                point = begin
                throw UserError(message: "Cannot move past superior level or buffer limit")
            }
        }
        if count > 0 {
            endOfSubtree(toHeading: true)
            saveExcursion {
                backOverEmptyLines()
                if !bolp { insert("\n") }
            }
        }
        let insertion = marker(point)
        defer { release(insertion) }
        let subtree = substring(begin, end)
        deleteRegion(begin, end)
        if !bolp, character(at: point) == Self.newline { point += 1 }
        let at = point
        insertBeforeMarkers(subtree)
        insertion.position = at
        if !bolp { insert("\n") }
        point = insertion.position
        skipForward(Self.whitespace)
        moveToColumn(column)
    }
}

private func headingCommand(_ context: EditContext, _ body: (EmacsBuffer) throws -> Void) -> CommandStep {
    commitBuffer(context, body)
}

// MARK: - Inserting

/// M-RET on a heading or text: `org-insert-heading`.
public struct InsertHeading: OrgCommand {
    public init() {}
    public var id: String { "org.heading.insert" }
    public var title: String { "Insert Heading" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep {
        headingCommand(context) { try $0.insertHeading(respectContent: context.options.insertHeadingRespectContent, hidden: context.hidden) }
    }
}

/// C-RET: `org-insert-heading-respect-content`.
public struct InsertHeadingAfterSubtree: OrgCommand {
    public init() {}
    public var id: String { "org.heading.insert-after-subtree" }
    public var title: String { "Insert Heading After Subtree" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep {
        headingCommand(context) { try $0.insertHeading(respectContent: true, hidden: context.hidden) }
    }
}

/// M-S-RET on a heading or text: `org-insert-todo-heading`.
public struct InsertTodoHeading: OrgCommand {
    public init() {}
    public var id: String { "org.heading.insert-todo" }
    public var title: String { "Insert TODO Heading" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep {
        headingCommand(context) { buffer in
            try buffer.insertHeading(respectContent: context.options.insertHeadingRespectContent, hidden: context.hidden)
            let previous = buffer.saveExcursion { () -> String? in
                try? buffer.forwardHeadingSameLevel(-1)
                guard let match = buffer.lookingAt(buffer.todoLinePattern), let keyword = match[2] else { return nil }
                return buffer.substring(keyword.lowerBound, keyword.upperBound)
            }
            let keyword = previous.flatMap { context.tree.settings.isDone($0) ? nil : $0 } ?? buffer.keywordsInOrder.first ?? "TODO"
            buffer.forwardLine(0)
            if let stars = buffer.lookingAt("\\*+ ") {
                buffer.point = stars[0]!.upperBound
                buffer.insert(keyword + " ")
            }
            buffer.updateParentTodoStatistics()
        }
    }
}

// MARK: - Moving and levels

/// M-up on a heading: `org-move-subtree-up`.
public struct MoveSubtreeUp: OrgCommand {
    public init() {}
    public var id: String { "org.subtree.up" }
    public var title: String { "Move Subtree Up" }
    public func applies(in context: EditContext) -> Bool { headingOnLine(at: context.caret, in: context.tree) != nil }
    public func run(in context: EditContext) -> CommandStep { headingCommand(context) { try $0.moveSubtree(-1) } }
}

/// M-down on a heading: `org-move-subtree-down`.
public struct MoveSubtreeDown: OrgCommand {
    public init() {}
    public var id: String { "org.subtree.down" }
    public var title: String { "Move Subtree Down" }
    public func applies(in context: EditContext) -> Bool { headingOnLine(at: context.caret, in: context.tree) != nil }
    public func run(in context: EditContext) -> CommandStep { headingCommand(context) { try $0.moveSubtree(1) } }
}

/// M-S-left on a heading: `org-promote-subtree`.
public struct PromoteSubtree: OrgCommand {
    public init() {}
    public var id: String { "org.subtree.promote" }
    public var title: String { "Promote Subtree" }
    public func applies(in context: EditContext) -> Bool { headingOnLine(at: context.caret, in: context.tree) != nil }
    public func run(in context: EditContext) -> CommandStep {
        headingCommand(context) { buffer in
            try buffer.saveExcursion {
                try buffer.backToHeading()
                try buffer.mapTree { try buffer.changeLevel(by: -1) }
            }
            buffer.fixPositionAfterPromote()
        }
    }
}

/// M-S-right on a heading: `org-demote-subtree`.
public struct DemoteSubtree: OrgCommand {
    public init() {}
    public var id: String { "org.subtree.demote" }
    public var title: String { "Demote Subtree" }
    public func applies(in context: EditContext) -> Bool { headingOnLine(at: context.caret, in: context.tree) != nil }
    public func run(in context: EditContext) -> CommandStep {
        headingCommand(context) { buffer in
            try buffer.saveExcursion {
                try buffer.backToHeading()
                try buffer.mapTree { try buffer.changeLevel(by: 1) }
            }
            buffer.fixPositionAfterPromote()
        }
    }
}

// MARK: - Motion

/// C-c C-n: `org-next-visible-heading`.
public struct NextHeading: OrgCommand {
    public init() {}
    public var id: String { "org.heading.next" }
    public var title: String { "Next Heading" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep {
        headingCommand(context) { buffer in
            buffer.endOfLine()
            var found = buffer.nextHeadingStart(after: buffer.point)
            while let start = found, context.hidden.contains(where: { $0.contains(start) }) {
                found = buffer.nextHeadingStart(after: start)
            }
            buffer.point = found ?? buffer.length
        }
    }
}

/// C-c C-p: `org-previous-visible-heading`.
public struct PreviousHeading: OrgCommand {
    public init() {}
    public var id: String { "org.heading.previous" }
    public var title: String { "Previous Heading" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep {
        headingCommand(context) { buffer in
            buffer.forwardLine(0)
            var found = buffer.previousHeadingStart(before: buffer.point)
            while let start = found, context.hidden.contains(where: { $0.contains(start) }) {
                found = buffer.previousHeadingStart(before: start)
            }
            buffer.point = found ?? 0
        }
    }
}

/// C-c C-f: `org-forward-heading-same-level`.
public struct ForwardSameLevel: OrgCommand {
    public init() {}
    public var id: String { "org.heading.forward-same-level" }
    public var title: String { "Next Heading at Same Level" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep { headingCommand(context) { try $0.forwardHeadingSameLevel(1) } }
}

/// C-c C-b: `org-backward-heading-same-level`.
public struct BackwardSameLevel: OrgCommand {
    public init() {}
    public var id: String { "org.heading.backward-same-level" }
    public var title: String { "Previous Heading at Same Level" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep { headingCommand(context) { try $0.forwardHeadingSameLevel(-1) } }
}

/// C-c C-u: `outline-up-heading`.
public struct UpHeading: OrgCommand {
    public init() {}
    public var id: String { "org.heading.up" }
    public var title: String { "Up to Parent Heading" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep {
        headingCommand(context) { buffer in
            do {
                try buffer.backToHeading()
            } catch {
                throw EmacsBuffer.UserError(message: "before first heading")
            }
            let start = buffer.outlineLevel
            guard start > 1 else { throw EmacsBuffer.UserError(message: "Already at top level of the outline") }
            var level = start
            while level >= start, !buffer.bobp {
                buffer.outlinePreviousHeading()
                level = buffer.outlineLevel
            }
        }
    }
}
