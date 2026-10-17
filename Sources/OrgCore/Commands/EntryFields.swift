import Foundation

/// An entry's heading parts, planning and notes, as a form edits them. The notes are the text
/// after the planning line, drawers and clock lines, up to the next heading, without trailing
/// blank lines.
public struct EntryFields: Equatable, Sendable {
    public var todo: String?
    /// The cookie's letter or number: `A`, `10`.
    public var priority: String?
    public var title: String
    public var tags: [String]
    /// The timestamps' text without brackets: `2026-10-17 Sat 18:00 +1w`.
    public var scheduled: String?
    public var deadline: String?
    public var notes: String

    public init(todo: String?, priority: String?, title: String, tags: [String], scheduled: String?, deadline: String?, notes: String) {
        self.todo = todo
        self.priority = priority
        self.title = title
        self.tags = tags
        self.scheduled = scheduled
        self.deadline = deadline
        self.notes = notes
    }

    /// The fields of the entry whose heading is at or before `offset`; nil before the first heading.
    public static func read(_ text: String, at offset: Int, settings: OrgSettings) -> EntryFields? {
        let buffer = EmacsBuffer(text, point: offset, settings: settings)
        guard (try? buffer.backToHeading()) != nil, let match = buffer.lookingAt(buffer.complexHeadingPattern) else { return nil }
        func group(_ i: Int) -> String? { match[i].map { buffer.substring($0.lowerBound, $0.upperBound) } }
        let notes = buffer.notesRange()
        return EntryFields(
            todo: group(2),
            priority: group(3).map { String($0.dropFirst(2).dropLast()) },
            title: group(4) ?? "",
            tags: group(5).map { $0.split(separator: ":").map(String.init) } ?? [],
            scheduled: buffer.planningValue(.scheduled),
            deadline: buffer.planningValue(.deadline),
            notes: buffer.substring(notes.lowerBound, notes.upperBound)
        )
    }
}

extension EmacsBuffer {
    /// The notes of the entry at point: from past its meta-data to before the trailing blanks
    /// of the entry's text.
    func notesRange() -> Range<Int> {
        saveExcursion {
            let end = entryEnd
            endOfMetaDataFull()
            let start = min(point, end)
            point = end
            skipBackward([32, 9, 10, 13])
            return start..<max(start, point)
        }
    }
}

/// Replaces the title of the entry's heading, keeping its keyword, priority and tags.
public struct SetHeadingTitle: OrgCommand {
    let text: String
    public init(title: String) { text = title }
    public var id: String { "org.heading.set-title" }
    public var title: String { "Set Heading Title" }
    public func applies(in context: EditContext) -> Bool { entryHeading(at: context.caret, in: context.tree) != nil }
    public func run(in context: EditContext) -> CommandStep {
        guard entryHeading(at: context.caret, in: context.tree) != nil else { return .failed("Before first headline") }
        // A heading is one line.
        let new = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return commitBuffer(context) { buffer in
            try buffer.saveExcursion {
                try buffer.backToHeading()
                guard let match = buffer.lookingAt(buffer.complexHeadingPattern) else { return }
                if let old = match[4] {
                    buffer.replace(old, with: new)
                } else if !new.isEmpty {
                    buffer.point = (1...3).compactMap { match[$0]?.upperBound }.max()!
                    buffer.insert(" " + new)
                }
                buffer.alignTags(onLineAt: buffer.point)
            }
        }
    }
}

/// Replaces the entry's notes (see `EntryFields.notes`).
public struct SetEntryNotes: OrgCommand {
    let notes: String
    public init(notes: String) { self.notes = notes }
    public var id: String { "org.entry.set-notes" }
    public var title: String { "Set Notes" }
    public func applies(in context: EditContext) -> Bool { entryHeading(at: context.caret, in: context.tree) != nil }
    public func run(in context: EditContext) -> CommandStep {
        guard entryHeading(at: context.caret, in: context.tree) != nil else { return .failed("Before first headline") }
        var new = notes
        while new.last?.isWhitespace == true { new.removeLast() }
        return commitBuffer(context) { buffer in
            buffer.saveExcursion {
                let old = buffer.notesRange()
                if !old.isEmpty {
                    // An emptied note takes its line break with it.
                    let end = new.isEmpty && buffer.character(at: old.upperBound) == 10 ? old.upperBound + 1 : old.upperBound
                    buffer.replace(old.lowerBound..<end, with: new)
                } else if !new.isEmpty {
                    buffer.point = old.lowerBound
                    if !buffer.bolp { buffer.insert("\n") }
                    buffer.insert(new + "\n")
                }
            }
        }
    }
}

/// Writes the changes made on a copy of the text back as one edit: the span between what the
/// two texts share at their start and end, when the text there still reads as it did.
public struct ReplaceChangedText: OrgCommand {
    public let edit: TextEdit
    let expected: String

    /// Nil when the texts are the same.
    public init?(from old: String, to new: String) {
        let a = Array(old.utf16)
        let b = Array(new.utf16)
        let shorter = min(a.count, b.count)
        var prefix = 0
        while prefix < shorter, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        while prefix > 0, prefix < a.count, UTF16.isTrailSurrogate(a[prefix]) { prefix -= 1 }
        while suffix > 0, UTF16.isTrailSurrogate(a[a.count - suffix]) { suffix -= 1 }
        guard a.count != b.count || prefix != a.count else { return nil }
        edit = TextEdit(range: prefix..<(a.count - suffix), replacement: String(decoding: b[prefix..<(b.count - suffix)], as: UTF16.self))
        expected = String(decoding: a[prefix..<(a.count - suffix)], as: UTF16.self)
    }

    public var id: String { "org.replace-changed-text" }
    public var title: String { "Replace Changed Text" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep {
        let text = context.text as NSString
        guard edit.range.upperBound <= text.length, text.substring(with: NSRange(edit.range)) == expected else {
            return .failed("The entry changed; nothing was saved.")
        }
        return .commit(EditResult(baseRevision: context.revision, edits: [edit], selection: nil, effects: []))
    }
}
