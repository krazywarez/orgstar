import Foundation

// Heading-line commands, matched to Emacs 31.1 / Org 9.8.7 by the oracle tests.

/// The heading whose line holds `offset`, for commands that act only on heading lines (org's
/// M-left, M-right, S-up and S-down do something else elsewhere).
func headingOnLine(at offset: Int, in tree: OrgTree) -> SyntaxNode? {
    guard let heading = entryHeading(at: offset, in: tree) else { return nil }
    let line = HeadingLine(heading)
    return offset >= line.start && offset <= line.contentEnd ? heading : nil
}

/// The heading of the entry holding `offset`, as `org-back-to-heading`; nil before the first
/// heading.
func entryHeading(at offset: Int, in tree: OrgTree) -> SyntaxNode? {
    let root = tree.root
    let position = offset >= root.range.upperBound ? max(0, root.range.upperBound - 1) : offset
    var node = root
    var heading: SyntaxNode?
    while let child = node.child(containing: position), child.kind == .section {
        heading = child.firstChild(.heading)
        node = child
    }
    return heading
}

/// The parts of a heading line, in offsets of the whole text.
struct HeadingLine {
    let start: Int
    /// End of the line's content, before its line break.
    let contentEnd: Int
    let stars: Range<Int>
    let todo: SyntaxToken?
    let priority: SyntaxToken?
    let tags: SyntaxToken?
    /// Where the title begins: past the stars, keyword, cookie and the blanks after them.
    let titleStart: Int

    init(_ heading: SyntaxNode) {
        let tokens = heading.tokens
        start = heading.range.lowerBound
        contentEnd = tokens.first { $0.kind == .newline }?.range.lowerBound ?? heading.range.upperBound
        stars = tokens.first { $0.kind == .stars }?.range ?? start..<start
        todo = tokens.first { $0.kind == .todoKeyword }
        priority = tokens.first { $0.kind == .priority }
        tags = tokens.first { $0.kind == .tags }
        var at = start
        for child in heading.green.children {
            guard case .token(let token) = child, [.stars, .whitespace, .todoKeyword, .priority].contains(token.kind) else { break }
            at += token.length
        }
        titleStart = min(at, contentEnd)
    }

    var level: Int { stars.count }
}

/// One line of text being edited, with a caret that moves the way Emacs moves point and
/// markers for each kind of edit, so commands land the caret where Emacs does.
struct LineBuffer {
    var text: NSMutableString
    /// Relative to the line start; nil when the caret is elsewhere in the document.
    var caret: Int?

    init(_ line: String, caret: Int?) {
        text = NSMutableString(string: line)
        self.caret = caret
    }

    var string: String { text as String }
    var length: Int { text.length }

    private mutating func edit(_ range: Range<Int>, _ replacement: String) -> Int {
        text.replaceCharacters(in: NSRange(range), with: replacement)
        return (replacement as NSString).length - range.count
    }

    /// `replace-match`: a caret strictly inside moves to the start; at or after the end it
    /// shifts with the text.
    mutating func replace(_ range: Range<Int>, with replacement: String) {
        let delta = edit(range, replacement)
        guard let position = caret else { return }
        if position >= range.upperBound, position > range.lowerBound {
            caret = position + delta
        } else if position > range.lowerBound {
            caret = range.lowerBound
        }
    }

    /// Deleting `range`, then `insert-before-markers`: a caret anywhere from the start to the
    /// end of the range ends up after the new text.
    mutating func replaceBeforeMarkers(_ range: Range<Int>, with replacement: String) {
        let delta = edit(range, replacement)
        guard let position = caret else { return }
        if position > range.upperBound {
            caret = position + delta
        } else if position >= range.lowerBound {
            caret = range.lowerBound + (replacement as NSString).length
        }
    }

    /// `insert` under `save-excursion`: a caret at the insertion point stays before the text.
    mutating func insert(_ string: String, at position: Int) {
        let delta = edit(position..<position, string)
        if let caret, caret > position { self.caret = caret + delta }
    }

    /// `insert` at point: the caret moves past the text.
    mutating func insertAtCaret(_ string: String) {
        guard let position = caret else { return }
        let delta = edit(position..<position, string)
        caret = position + delta
    }
}

extension HeadingLine {
    /// Applies `edit` to the heading line in `context` and maps the caret: on the line it's
    /// placed by `edit`; after the line it shifts by the change in length.
    func commit(_ context: EditContext, _ edit: (inout LineBuffer) -> Void) -> CommandStep {
        let old = (context.text as NSString).substring(with: NSRange(start..<contentEnd))
        let caretOnLine = context.caret >= start && context.caret <= contentEnd
        var buffer = LineBuffer(old, caret: caretOnLine ? context.caret - start : nil)
        edit(&buffer)
        let new = buffer.string
        let delta = (new as NSString).length - (old as NSString).length
        let caret = buffer.caret.map { $0 + start } ?? (context.caret > contentEnd ? context.caret + delta : context.caret)
        guard new != old else { return .commit(EditResult(baseRevision: context.revision, edits: [], selection: [caret..<caret])) }
        return .commit(EditResult(
            baseRevision: context.revision,
            edits: [TextEdit(range: start..<contentEnd, replacement: new)],
            selection: [caret..<caret]
        ))
    }

    /// Offsets relative to the line start.
    func local(_ range: Range<Int>) -> Range<Int> { (range.lowerBound - start)..<(range.upperBound - start) }
}

// MARK: - Tags

/// `org--align-tags-here` with `org-tags-column` -77: tags end at column 77, or sit one blank
/// after the title when it is too long. Nothing changes when they are already there.
///
/// Commands align under `save-excursion`, where the caret is a marker: in the blanks before
/// the tags it ends up where they start. Aligning tags directly (`preservingColumn`) keeps the
/// caret's column instead, as org does for point.
func alignTags(_ buffer: inout LineBuffer, options: EditingOptions = .org, preservingColumn: Bool = false) {
    let line = buffer.string
    guard let match = line.range(of: "[ \\t]+(:[[:alnum:]_@#%]+)+:[ \\t]*$", options: .regularExpression) else { return }
    let matched = String(line[match])
    let tags = matched.trimmingCharacters(in: .whitespaces)
    let blankStart = (String(line[..<match.lowerBound]) as NSString).length
    let tagsStart = blankStart + (matched as NSString).range(of: tags).location
    // Columns as Emacs displays the line: link markup and, with the options, emphasis markers
    // don't count.
    let visible = VisibleLine(line, options: options)
    let prefixColumn = visible.column(at: blankStart)
    let currentColumn = visible.column(at: tagsStart)
    let tagsColumn = options.tagsColumn
    let target = tagsColumn >= 0 ? tagsColumn : abs(tagsColumn) - displayWidth(tags)
    let newColumn = max(target, prefixColumn + 1)
    guard newColumn != currentColumn else { return }
    let inBlanks = buffer.caret.map { $0 > blankStart && $0 <= tagsStart } ?? false
    let caretColumn: Int? = inBlanks && preservingColumn ? visible.column(at: buffer.caret!) : nil
    let old = buffer.caret
    buffer.text.replaceCharacters(in: NSRange(blankStart..<tagsStart), with: String(repeating: " ", count: newColumn - prefixColumn))
    let delta = (newColumn - prefixColumn) - (tagsStart - blankStart)
    if let caretColumn {
        buffer.caret = VisibleLine(buffer.string, options: options).offset(ofColumn: caretColumn)
    } else if inBlanks {
        buffer.caret = blankStart
    } else if let old, old > tagsStart {
        buffer.caret = old + delta
    }
}


// MARK: - TODO

public struct TodoCycle: OrgCommand {
    public init() {}
    public var id: String { "org.todo.cycle" }
    public var title: String { "Cycle TODO State" }

    public func applies(in context: EditContext) -> Bool {
        entryHeading(at: context.caret, in: context.tree) != nil
    }

    /// No keyword, then each keyword of its sequence in order, then no keyword again.
    static func next(after current: String?, in settings: OrgSettings) -> String? {
        guard let current else {
            guard let first = settings.todoSequences.first else { return nil }
            return (first.active + first.done).first?.name
        }
        for sequence in settings.todoSequences {
            let names = (sequence.active + sequence.done).map(\.name)
            if let index = names.firstIndex(of: current) {
                return index + 1 < names.count ? names[index + 1] : nil
            }
        }
        return nil
    }

    /// As `org-todo`: the blanks after the stars, the keyword and the blanks after it are
    /// replaced by " NEXT " (or " " for no keyword) with `insert-before-markers`, then tags
    /// are aligned.
    /// `org-todo`, then the parent's TODO statistics, and the repeat of a repeating entry
    /// that became done.
    public func run(in context: EditContext) -> CommandStep {
        let previous = EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings).todoKeyword
        if context.options.fastTodoSelection, entryHeading(at: context.caret, in: context.tree) != nil,
           let fast = FastSelection.todo(context.tree.settings) {
            guard let answer = context.answers["todo"] else {
                return .prompt(Prompt(key: "todo", message: "TODO state: [a-z..]:Set [SPC]:clear", fast: fast))
            }
            guard let key = answer.first, let keyword = fast.keyword(for: key, current: previous) else { return .failed("Quit") }
            return SetTodo(keyword: keyword).run(in: context)
        }
        return followUp(context, cycle(in: context)) { buffer in
            try buffer.saveExcursion {
                buffer.updateParentTodoStatistics()
                try buffer.afterTodoChange(previous: previous, answers: context.answers)
            }
        }
    }

    private func cycle(in context: EditContext) -> CommandStep {
        guard let heading = entryHeading(at: context.caret, in: context.tree) else {
            return .failed("Before first headline")
        }
        let line = HeadingLine(heading)
        let next = Self.next(after: line.todo?.text, in: context.tree.settings)
        return line.commit(context) { buffer in
            let text = buffer.string as NSString
            let regionStart = line.stars.upperBound - line.start
            var regionEnd = regionStart
            while regionEnd < text.length, text.character(at: regionEnd) == 0x20 { regionEnd += 1 }
            if let todo = line.todo {
                regionEnd = line.local(todo.range).upperBound
                var blanks = regionEnd
                while blanks < text.length, text.character(at: blanks) == 0x20 { blanks += 1 }
                if blanks > regionEnd {
                    regionEnd = blanks
                } else if text.substring(from: regionEnd).allSatisfy({ $0 == " " || $0 == "\t" }) {
                    regionEnd = text.length
                }
            }
            buffer.replaceBeforeMarkers(regionStart..<regionEnd, with: next.map { " \($0) " } ?? " ")
            alignTags(&buffer, options: context.options)
        }
    }
}

/// S-right and S-left on a heading: `org-todo` with `right` or `left`, through every keyword
/// of every sequence.
public struct TodoShift: OrgCommand {
    public let right: Bool
    public init(right: Bool) { self.right = right }
    public var id: String { right ? "org.todo.next" : "org.todo.previous" }
    public var title: String { right ? "Next TODO Keyword" : "Previous TODO Keyword" }
    public func applies(in context: EditContext) -> Bool { headingOnLine(at: context.caret, in: context.tree) != nil }
    public func run(in context: EditContext) -> CommandStep {
        let keywords = context.tree.settings.todoSequences.flatMap { ($0.active + $0.done).map(\.name) }
        let current = EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings).todoKeyword
        let index = current.flatMap(keywords.firstIndex(of:))
        let next: String? = if right {
            index.map { $0 + 1 < keywords.count ? keywords[$0 + 1] : nil } ?? keywords.first
        } else {
            index.map { $0 > 0 ? keywords[$0 - 1] : nil } ?? keywords.last
        }
        return SetTodo(keyword: next).run(in: context)
    }
}

// MARK: - Priority

struct PriorityChange {
    let up: Bool

    func run(in context: EditContext) -> CommandStep {
        guard let heading = headingOnLine(at: context.caret, in: context.tree) else {
            return .failed("Not on a heading")
        }
        let line = HeadingLine(heading)
        let priorities = context.tree.settings.priorities
        guard let highest = Self.value(priorities.highest), let lowest = Self.value(priorities.lowest) else {
            return .failed("Unsupported priority range")
        }
        let numeric = Int(priorities.highest) != nil
        let current = line.priority.flatMap { Self.value(String($0.text.dropFirst(2).dropLast())) }
        // From no cookie, the first press sets the default, as `org-priority-start-cycle-with-default`.
        var new: Int?
        if let current {
            new = up ? current - 1 : current + 1
            if let value = new, value < highest || value > lowest { new = nil }
        } else {
            new = Self.value(priorities.default)
        }
        return Self.write(new.map { "[#\(Self.label($0, numeric: numeric))]" }, line: line, context: context)
    }

    /// Puts `cookie` on the heading, or with nil removes it.
    static func write(_ cookie: String?, line: HeadingLine, context: EditContext) -> CommandStep {
        line.commit(context) { buffer in
            if let existing = line.priority {
                let range = line.local(existing.range)
                if let cookie {
                    buffer.replace((range.lowerBound + 2)..<(range.upperBound - 1), with: String(cookie.dropFirst(2).dropLast()))
                } else {
                    // The cookie and one following space, as `org-priority-regexp` group 1.
                    let text = buffer.string as NSString
                    let space = range.upperBound < text.length && text.character(at: range.upperBound) == 0x20 ? 1 : 0
                    buffer.replace(range.lowerBound..<(range.upperBound + space), with: "")
                }
            } else if let cookie {
                if let todo = line.todo {
                    buffer.insert(" " + cookie, at: line.local(todo.range).upperBound)
                } else {
                    buffer.insert(cookie + " ", at: line.titleStart - line.start)
                }
            }
            alignTags(&buffer, options: context.options)
        }
    }

    /// A priority as a number: a letter's code point, or the number itself.
    static func value(_ text: String) -> Int? {
        if let number = Int(text) { return number }
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else { return nil }
        return Int(scalar.value)
    }

    static func label(_ value: Int, numeric: Bool) -> String {
        numeric ? String(value) : String(Character(Unicode.Scalar(UInt32(value))!))
    }
}

/// C-c ,: `org-priority` with `set`, asking for the priority (SPC removes it); with `value`,
/// that priority, or with " " none, as the speed keys 1, 2, 3 and 0 do.
public struct SetPriority: OrgCommand {
    let value: Character?
    public init(value: Character? = nil) { self.value = value }
    public var id: String {
        switch value {
        case nil: "org.priority.set"
        case " ": "org.priority.remove"
        case let v?: "org.priority.set-\(v.lowercased())"
        }
    }
    public var title: String {
        switch value {
        case nil: "Set Priority…"
        case " ": "Remove Priority"
        case let v?: "Set Priority \(v)"
        }
    }
    public func applies(in context: EditContext) -> Bool { headingOnLine(at: context.caret, in: context.tree) != nil }

    public func run(in context: EditContext) -> CommandStep {
        guard let heading = headingOnLine(at: context.caret, in: context.tree) else { return .failed("Not on a heading") }
        let priorities = context.tree.settings.priorities
        let numeric = Int(priorities.lowest) != nil
        let answer: String
        if let value {
            answer = String(value)
        } else if let given = context.answers["priority"] {
            answer = given
        } else {
            let message = "Priority \(priorities.highest)-\(priorities.lowest), SPC to remove:"
            if numeric, (Int(priorities.lowest) ?? 0) >= 10 { return .prompt(Prompt(key: "priority", message: message)) }
            guard let high = PriorityChange.value(priorities.highest), let low = PriorityChange.value(priorities.lowest), high <= low else {
                return .failed("Unsupported priority range")
            }
            let items: [FastSelection.Item] = (high...low).map { v in
                let label = PriorityChange.label(v, numeric: numeric)
                return .option(key: Character(label.lowercased()), name: label)
            } + [.option(key: " ", name: "remove")]
            return .prompt(Prompt(key: "priority", message: message, fast: FastSelection(items: items, multiple: false)))
        }
        let line = HeadingLine(heading)
        if answer == " " {
            guard line.priority != nil else { return .failed("No priority cookie found in line") }
            return PriorityChange.write(nil, line: line, context: context)
        }
        let new = numeric ? Int(answer.trimmingCharacters(in: .whitespaces)) : PriorityChange.value(answer.uppercased())
        guard let new, let high = PriorityChange.value(priorities.highest), let low = PriorityChange.value(priorities.lowest), new >= high, new <= low else {
            return .failed(numeric ? "Priority must be a number between `\(priorities.highest)' and `\(priorities.lowest)'"
                : "Priority must be between `\(priorities.highest)' and `\(priorities.lowest)'")
        }
        return PriorityChange.write("[#\(PriorityChange.label(new, numeric: numeric))]", line: line, context: context)
    }
}

public struct PriorityUp: OrgCommand {
    public init() {}
    public var id: String { "org.priority.up" }
    public var title: String { "Raise Priority" }
    public func applies(in context: EditContext) -> Bool { headingOnLine(at: context.caret, in: context.tree) != nil }
    public func run(in context: EditContext) -> CommandStep { PriorityChange(up: true).run(in: context) }
}

public struct PriorityDown: OrgCommand {
    public init() {}
    public var id: String { "org.priority.down" }
    public var title: String { "Lower Priority" }
    public func applies(in context: EditContext) -> Bool { headingOnLine(at: context.caret, in: context.tree) != nil }
    public func run(in context: EditContext) -> CommandStep { PriorityChange(up: false).run(in: context) }
}

// MARK: - Promote and demote

public struct PromoteHeading: OrgCommand {
    public init() {}
    public var id: String { "org.heading.promote" }
    public var title: String { "Promote Heading" }
    public func applies(in context: EditContext) -> Bool { headingOnLine(at: context.caret, in: context.tree) != nil }

    public func run(in context: EditContext) -> CommandStep {
        guard let heading = headingOnLine(at: context.caret, in: context.tree) else { return .failed("Not on a heading") }
        let line = HeadingLine(heading)
        guard line.level > 1 else { return .failed("Cannot promote to level 0") }
        return line.commit(context) { buffer in
            buffer.replace(0..<(line.level + 1), with: String(repeating: "*", count: line.level - 1) + " ")
            alignTags(&buffer, options: context.options)
            fixPositionAfterPromote(&buffer, settings: context.tree.settings)
        }
    }
}

public struct DemoteHeading: OrgCommand {
    public init() {}
    public var id: String { "org.heading.demote" }
    public var title: String { "Demote Heading" }
    public func applies(in context: EditContext) -> Bool { headingOnLine(at: context.caret, in: context.tree) != nil }

    public func run(in context: EditContext) -> CommandStep {
        guard let heading = headingOnLine(at: context.caret, in: context.tree) else { return .failed("Not on a heading") }
        let line = HeadingLine(heading)
        return line.commit(context) { buffer in
            buffer.replace(0..<(line.level + 1), with: String(repeating: "*", count: line.level + 1) + " ")
            alignTags(&buffer, options: context.options)
            fixPositionAfterPromote(&buffer, settings: context.tree.settings)
        }
    }
}

/// `org-fix-position-after-promote`: a caret right after the stars or the keyword steps over
/// the following space, or adds one at the end of the line.
func fixPositionAfterPromote(_ buffer: inout LineBuffer, settings: OrgSettings) {
    guard let caret = buffer.caret else { return }
    let tree = OrgParser.parse(buffer.string + "\n", defaults: settings)
    guard let heading = tree.root.firstChild(.section)?.firstChild(.heading) else { return }
    let line = HeadingLine(heading)
    let anchors = [line.stars.upperBound, line.todo?.range.upperBound].compactMap { $0 }
    guard anchors.contains(caret) else { return }
    if caret == buffer.length {
        buffer.insertAtCaret(" ")
    } else if buffer.text.character(at: caret) == 0x20 {
        buffer.caret = caret + 1
    }
}
