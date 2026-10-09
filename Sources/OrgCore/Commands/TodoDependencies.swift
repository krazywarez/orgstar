import Foundation

// TODO dependencies (Org 9.8.7): `org-block-todo-from-children-or-siblings-or-parent` with
// `org-enforce-todo-dependencies`, `org-block-todo-from-checkboxes` with
// `org-enforce-todo-checkbox-dependencies`, `org-entry-blocked-p` and
// `org-toggle-ordered-property` with `org-track-ordered-property-with-tag` nil.

extension EmacsBuffer {
    /// `org-not-done-heading-regexp`.
    var notDoneHeadingPattern: String? {
        let names = settings.todoSequences.flatMap { $0.active.map(\.name) }
        guard !names.isEmpty else { return nil }
        return "^(\\*+)(?: +(" + names.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + "))(?: +(.*?))?[ \\t]*$"
    }

    /// `org-get-heading` for the heading at point.
    func orgGetHeading() -> String {
        saveExcursion {
            _ = try? backToHeading()
            guard let match = lookingAt(complexHeadingPattern) else { return "" }
            let parts = [match[2], match[3]].map { $0.map { substring($0.lowerBound, $0.upperBound) } }
                + [match[4].map { substring($0.lowerBound, $0.upperBound) } ?? "", match[5].map { substring($0.lowerBound, $0.upperBound) }]
            return parts.compactMap { $0 }.joined(separator: " ")
        }
    }

    /// Whether the heading at `heading` has a not-done keyword.
    private func isNotDone(at heading: Int) -> Bool {
        saveExcursion {
            point = heading
            return todoKeyword.map { keywordsInOrder.contains($0) && !settings.isDone($0) } ?? false
        }
    }

    /// `ORDERED` on the entry at `heading`, as `org-not-nil` of `org-entry-get`.
    private func isOrdered(_ heading: Int) -> Bool {
        localProperty("ORDERED", heading: heading).map { $0 != "nil" } ?? false
    }

    /// `org-block-todo-from-children-or-siblings-or-parent` for the entry at point becoming
    /// done: the heading that blocks it, or nil.
    func hierarchyBlocker() -> String? {
        saveExcursion {
            guard let start = try? backToHeading() else { return nil }
            let level = headingLevel(atLine: start)!
            outlineNextHeading()
            while !eobp, outlineLevel > level {
                if isNotDone(at: point) { return orgGetHeading() }
                outlineNextHeading()
            }
            guard let notDone = notDoneHeadingPattern else { return nil }
            point = start
            var pos = start
            guard upHeadingSafe() != nil else { return nil }
            var parent = point
            if isOrdered(parent) {
                forwardLine(1)
                if let match = searchForward(notDone, bound: pos, caseInsensitive: false) { return substring(match[0]!.lowerBound, match[0]!.upperBound) }
            }
            // An ancestor blocked by its own ordered siblings blocks its subtree.
            while true {
                point = parent
                guard lookingAt(notDone) != nil else { return nil }
                pos = point
                guard upHeadingSafe() != nil else { return nil }
                parent = point
                if isOrdered(parent) {
                    forwardLine(1)
                    if searchForward(notDone, bound: pos, caseInsensitive: false) != nil { return orgGetHeading() }
                }
            }
        }
    }

    /// `org-block-todo-from-checkboxes`: an unchecked or partly checked box in the entry's
    /// own text, outside blocks lists can't be in.
    func hasOpenCheckbox() -> Bool {
        saveExcursion {
            guard let start = try? backToHeading() else { return false }
            outlineNextHeading()
            let end = point
            point = start
            let pattern = itemBeginningPattern + "(?:\\[@(?:start:)?([0-9]+|[A-Za-z])\\][ \\t]*)?\\[[- ]\\]"
            while searchForward(pattern, bound: end, caseInsensitive: false) != nil {
                if !inBlock(Self.forbiddenBlocks) { return true }
            }
            return false
        }
    }

    /// `org-in-block-p`: point is in a block of one of the types, between the headings around it.
    func inBlock(_ names: [String]) -> Bool {
        saveExcursion {
            let pos = point
            let up = saveExcursion { () -> Int in outlinePreviousHeading(); return point }
            let down = saveExcursion { () -> Int in outlineNextHeading(); return point }
            for name in names {
                let begin = "^[ \\t]*#\\+begin_" + NSRegularExpression.escapedPattern(for: name)
                let end = "^[ \\t]*#\\+end_" + NSRegularExpression.escapedPattern(for: name)
                point = pos
                guard let open = searchBackward(begin, bound: up) else { continue }
                let beg = open[0]!.lowerBound
                point = open[0]!.upperBound
                guard let close = searchForward(end, bound: down), close[0]!.upperBound > pos else { continue }
                point = close[0]!.lowerBound
                if searchBackward(begin, bound: beg + 1) == nil { return true }
            }
            return false
        }
    }

    /// `org-blocker-hook` as `org-todo` runs it for a change from `from` to `to`, with the
    /// checkbox hook first, as `org-mode` adds them: the message refusing the change, or nil.
    func todoBlockedMessage(from: String?, to: String?) -> String? {
        let checkboxes = options.enforceTodoCheckboxDependencies
        let dependencies = options.enforceTodoDependencies
        guard checkboxes || dependencies, let to, settings.isDone(to), !(from.map(settings.isDone) ?? false) else { return nil }
        let heading = saveExcursion { try? backToHeading() }
        guard let heading, localProperty("NOBLOCKING", heading: heading).map({ $0 == "nil" }) ?? true else { return nil }
        let reason: String
        if checkboxes, hasOpenCheckbox() {
            reason = "contained checkboxes"
        } else if dependencies, let blocker = hierarchyBlocker() {
            reason = "\"\(blocker)\""
        } else {
            return nil
        }
        return "TODO state change from \(from ?? "nil") to \(to) blocked (by \(reason))"
    }

    /// Throws the refusal of a change from `from` to `to`, if it is blocked.
    func checkTodoBlocking(from: String?, to: String?) throws {
        if let message = todoBlockedMessage(from: from, to: to) { throw UserError(message: message) }
    }
}

/// C-c C-x o: `org-toggle-ordered-property`.
public struct ToggleOrderedProperty: OrgCommand {
    public init() {}
    public var id: String { "org.property.toggle-ordered" }
    public var title: String { "Toggle ORDERED Property" }
    public func applies(in context: EditContext) -> Bool { entryHeading(at: context.caret, in: context.tree) != nil }
    public func run(in context: EditContext) -> CommandStep {
        commitBuffer(context) { buffer in
            try buffer.saveExcursion {
                let heading = try buffer.backToHeading()
                if buffer.localProperty("ORDERED", heading: heading).map({ $0 != "nil" }) ?? false {
                    buffer.entryDelete("ORDERED")
                    buffer.message = "Subtasks can be completed in arbitrary order"
                } else {
                    buffer.entryPut("ORDERED", "t")
                    buffer.message = "Subtasks must be completed in sequence"
                }
            }
        }
    }
}
