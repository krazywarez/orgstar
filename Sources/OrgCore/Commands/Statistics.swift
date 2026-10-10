import Foundation

// TODO statistics cookies (`org-update-parent-todo-statistics`, Org 9.8.7) with
// `org-provide-todo-statistics` t and `org-hierarchical-todo-statistics` t.

extension EmacsBuffer {
    /// A property of the entry at `heading` from its property drawer, or nil.
    func localProperty(_ name: String, heading: Int) -> String? {
        saveExcursion {
            point = heading
            forwardLine(1)
            if lookingAt(planningPattern) != nil { forwardLine(1) }
            guard lookingAt("^[ \\t]*:PROPERTIES:[ \\t]*$") != nil else { return nil }
            forwardLine(1)
            while !eobp, lookingAt("^[ \\t]*:END:[ \\t]*$") == nil {
                if let match = lookingAt("^[ \\t]*:([^:\\s]+):(?:[ \\t]+(.*?))?[ \\t]*$"),
                   substring(match[1]!.lowerBound, match[1]!.upperBound).caseInsensitiveCompare(name) == .orderedSame {
                    return match[2].map { substring($0.lowerBound, $0.upperBound) } ?? ""
                }
                if forwardLine(1) != 0 { break }
            }
            return nil
        }
    }

    var planningPattern: String { "^[ \\t]*(?:SCHEDULED|DEADLINE|CLOSED):" }

    /// A property with inheritance: the entry, then its ancestors. Returns the value and the
    /// heading it came from.
    func inheritedProperty(_ name: String) -> (value: String, from: Int)? {
        saveExcursion {
            guard (try? backToHeading()) != nil else { return nil }
            while true {
                if let value = localProperty(name, heading: point) { return (value, point) }
                let level = outlineLevel
                guard level > 1, let parent = saveExcursion({ () -> Int? in
                    while let previous = previousHeadingStart(before: point) {
                        point = previous
                        if headingLevel(atLine: previous)! < level { return previous }
                    }
                    return nil
                }) else { return nil }
                point = parent
            }
        }
    }

    /// `org-up-heading-safe`: the parent heading's level, with point on it, or nil.
    @discardableResult
    func upHeadingSafe() -> Int? {
        guard let start = try? backToHeading() else { return nil }
        let level = headingLevel(atLine: start)!
        var at = start
        // A top-level heading has no parent; without this the walk goes to the top of the file.
        while level > 1, let previous = previousHeadingStart(before: at) {
            at = previous
            if let parentLevel = headingLevel(atLine: previous), parentLevel < level {
                point = previous
                return parentLevel
            }
        }
        point = start
        return nil
    }

    /// `org-update-parent-todo-statistics` for the heading at point.
    func updateParentTodoStatistics() {
        let property = saveExcursion { () -> (value: String, from: Int)? in
            upHeadingSafe()
            return inheritedProperty("COOKIE_DATA")
        }
        let recursive = property.map { $0.value.range(of: "\\brecursive\\b", options: .regularExpression) != nil } ?? false
        let limit = property?.from ?? 0
        var first = true
        saveExcursion {
            beginningOfLine()
            let toggleLevel = outlineLevel
            while let level = upHeadingSafe(), recursive || first, point >= limit {
                first = false
                let data = (localProperty("COOKIE_DATA", heading: point) ?? "").lowercased()
                if data.range(of: "\\bcheckbox\\b", options: .regularExpression) != nil { return }
                let headingStart = point
                while let match = searchForward("((\\[[0-9]*%\\])|(\\[[0-9]*/[0-9]*\\]))", bound: lineEnd(point)) {
                    let cookieStart = match[0]!.lowerBound
                    let isPercent = match[2] != nil
                    guard isStatisticsCookie(at: cookieStart, headingStart: headingStart) else { continue }
                    var all = 0, done = 0
                    let after = point
                    point = headingStart
                    guard outlineNextHeading() else { return }
                    while let heading = lookingAt(complexHeadingPattern), let l1 = heading[1].map({ $0.count }), l1 > level {
                        let keyword = (recursive || l1 == toggleLevel) ? heading[2].map { substring($0.lowerBound, $0.upperBound) } : nil
                        if let keyword {
                            all += 1
                            if settings.isDone(keyword) { done += 1 }
                        }
                        outlineNextHeading()
                    }
                    point = after
                    let new = isPercent ? "[\(Int((100.0 * Double(done) / Double(max(1, all))).rounded(.down)))%]" : "[\(done)/\(all)]"
                    if new != substring(cookieStart, match[0]!.upperBound) {
                        let length = match[0]!.upperBound - cookieStart
                        point = cookieStart
                        insert(new)
                        deleteRegion(point, point + length)
                        let tags = saveExcursion { () -> [Range<Int>?]? in
                            beginningOfLine()
                            return lookingAt(SetTags.tagLine)
                        }
                        if let tagsRange = tags?[1], point < tagsRange.lowerBound { alignTags(onLineAt: point) }
                    }
                }
                point = headingStart
            }
        }
    }

    /// Whether the cookie text at `offset` on a heading line parses as a statistics cookie.
    private func isStatisticsCookie(at offset: Int, headingStart: Int) -> Bool {
        let line = substring(headingStart, lineEnd(headingStart)) + "\n"
        let tree = OrgParser.parse(line, defaults: settings)
        return tree.root.descendants().contains { $0.kind == .statisticsCookie && $0.range.contains(offset - headingStart) }
    }
}

/// Applies a command's result to a buffer, runs `then` on it, and commits the combined change:
/// for commands org follows with more edits, such as statistics updates.
func followUp(_ context: EditContext, _ step: CommandStep, _ then: (EmacsBuffer) throws -> Void) -> CommandStep {
    guard case .commit(let result) = step, !result.edits.isEmpty else { return step }
    let caret = result.selection?.first?.lowerBound ?? context.caret
    return commitBuffer(context) { buffer in
        for edit in result.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            buffer.replace(edit.range, with: edit.replacement)
        }
        buffer.point = caret
        try then(buffer)
    }
}
