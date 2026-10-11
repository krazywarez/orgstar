import Foundation

// Editing in column view (org-colview.el, Org 9.8.7): `org-columns-edit-value` and
// `org-columns-next-allowed-value` for the entry whose heading holds the caret.

extension EditContext {
    /// The same context with the caret at `offset`.
    func at(_ offset: Int) -> EditContext {
        EditContext(revision: revision, text: text, tree: tree, selection: [offset..<offset], now: now, calendar: calendar,
                    answers: answers, hidden: hidden, options: options, knownTags: knownTags, lastCommand: lastCommand)
    }

    /// The same context with `more` answers.
    func answering(_ more: [String: String]) -> EditContext {
        EditContext(revision: revision, text: text, tree: tree, selection: selection, now: now, calendar: calendar,
                    answers: answers.merging(more) { $1 }, hidden: hidden, options: options, knownTags: knownTags, lastCommand: lastCommand)
    }
}

/// `e` in column view: `org-columns-edit-value` with the value given. ITEM edits the headline,
/// TODO, PRIORITY, TAGS, SCHEDULED and DEADLINE go through their commands, and other
/// properties are set in the entry's drawer.
public struct SetColumnValue: OrgCommand {
    public let property: String
    public let value: String
    public init(property: String, value: String) {
        self.property = property
        self.value = value
    }
    public var id: String { "org.columns.edit-value" }
    public var title: String { "Edit Column Value" }
    public func applies(in context: EditContext) -> Bool { entryHeading(at: context.caret, in: context.tree) != nil }

    public func run(in context: EditContext) -> CommandStep {
        guard let heading = entryHeading(at: context.caret, in: context.tree) else { return .failed("Before first headline") }
        let value = self.value.trimmingCharacters(in: .whitespaces)
        let here = context.at(heading.range.lowerBound)
        switch property.uppercased() {
        case "CLOCKSUM", "CLOCKSUM_T", "ALLTAGS", "BLOCKED", "CLOSED", "FILE", "TIMESTAMP", "TIMESTAMP_IA":
            return .failed("This special column cannot be edited")
        case "ITEM":
            // `org-edit-headline`.
            return commitBuffer(here) { buffer in
                guard let match = buffer.lookingAt(buffer.complexHeadingPattern) else { return }
                let old = match[4].map { buffer.substring($0.lowerBound, $0.upperBound) }
                guard old != value else { return }
                if let title = match[4] {
                    buffer.replace(title.lowerBound..<title.upperBound, with: value)
                } else {
                    buffer.point = (match[3] ?? match[2] ?? match[1])!.upperBound
                    buffer.insert(" " + value)
                }
                buffer.alignTags(onLineAt: heading.range.lowerBound)
            }
        case "TODO":
            return SetTodo(keyword: value.isEmpty ? nil : value).run(in: here)
        case "PRIORITY":
            return SetPriority(value: value.isEmpty ? " " : nil).run(in: value.isEmpty ? here : here.answering(["priority": value]))
        case "TAGS":
            let tags = value.split(whereSeparator: { $0 == ":" || $0 == " " }).map(String.init)
            return SetTags.set(tags, in: here)
        case "SCHEDULED", "DEADLINE":
            let deadline = property.uppercased() == "DEADLINE"
            if value.isEmpty { return RemovePlanning(deadline: deadline).run(in: here) }
            return SetPlanning(deadline: deadline).run(in: here.answering(["date": value]))
        default:
            // Column keys are upper case, as `org-columns-compile-format` reads them, and so is
            // the line `org-entry-put` writes.
            return SetProperty(key: property.uppercased(), value: value).run(in: here)
        }
    }
}

/// `n` and `p` in column view: `org-columns-next-allowed-value`, the next (or previous) of the
/// property's allowed values, `[ ]` and `[X]` for a checkbox summary, or a day later (or
/// earlier) for SCHEDULED and DEADLINE.
public struct NextColumnValue: OrgCommand {
    public let property: String
    /// The column's summary operator, for checkbox columns.
    public let summary: String?
    public let previous: Bool
    public init(property: String, summary: String? = nil, previous: Bool = false) {
        self.property = property
        self.summary = summary
        self.previous = previous
    }
    public var id: String { previous ? "org.columns.previous-value" : "org.columns.next-value" }
    public var title: String { previous ? "Previous Allowed Value" : "Next Allowed Value" }
    public func applies(in context: EditContext) -> Bool { entryHeading(at: context.caret, in: context.tree) != nil }

    public func run(in context: EditContext) -> CommandStep {
        guard let heading = entryHeading(at: context.caret, in: context.tree) else { return .failed("Before first headline") }
        let key = property.uppercased()
        if key == "ITEM" { return .failed("Cannot edit item headline from here") }
        if key == "SCHEDULED" || key == "DEADLINE" {
            // The planning timestamp a day later or earlier.
            let ns = context.text as NSString
            let next = NSMaxRange(ns.lineRange(for: NSRange(location: heading.range.lowerBound, length: 0)))
            guard next < ns.length else { return .failed("No \(key) in this entry") }
            let line = ns.lineRange(for: NSRange(location: next, length: 0))
            let found = ns.range(of: key + ": *<", options: .regularExpression, range: line)
            guard found.location != NSNotFound else { return .failed("No \(key) in this entry") }
            return ShiftTimestampDay(later: !previous).run(in: context.at(NSMaxRange(found)))
        }
        var allowed = PropertyValues.allowed(property, at: heading.range.lowerBound, text: context.text, tree: context.tree)?.values ?? []
        if allowed.isEmpty, let summary, ["X", "X/", "X%"].contains(summary) { allowed = ["[ ]", "[X]"] }
        guard !allowed.isEmpty else { return .failed("Allowed values for this property have not been defined") }
        if previous { allowed.reverse() }
        let model = DocumentModel(tree: context.tree)
        guard let index = model.headings.firstIndex(where: { $0.headingRange.lowerBound == heading.range.lowerBound }) else { return .failed("Before first headline") }
        let current = ColumnView.value(key, heading: index, model: model, text: context.text as NSString, clocksum: [:])
        let new: String
        if let i = allowed.firstIndex(of: current) {
            if allowed.count == 1 { return .failed("Only one allowed value for this property") }
            new = i + 1 < allowed.count ? allowed[i + 1] : allowed[0]
        } else {
            new = allowed[0]
        }
        return SetColumnValue(property: property, value: new).run(in: context)
    }
}
