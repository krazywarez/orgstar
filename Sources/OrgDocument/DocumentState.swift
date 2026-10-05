import Foundation
import OrgCore

/// One open file: its text, tree, revision, undo history, and the bytes last read from or
/// written to disk, which are the base for merging external changes.
public struct DocumentState: Sendable {
    public enum EditError: Error, Equatable {
        case readOnly
        case staleRevision
        case overlappingEdits
    }

    public enum ExternalChange: Sendable, Equatable {
        case unchanged
        /// The buffer had no edits and now holds the disk version. Edits are in the old text's
        /// coordinates, for mapping view state.
        case reloaded([TextEdit])
        /// The disk version was merged into the edited buffer.
        case merged([TextEdit])
        /// Nothing changed in the buffer.
        case conflict([MergeConflict])
    }

    /// The bytes on disk as of the last read or write.
    public private(set) var source: SourceText
    public private(set) var text: String
    public private(set) var tree: OrgTree
    /// Increases on every change to `text`.
    public private(set) var revision = 0
    public let defaults: OrgSettings
    private var undoStack: [[TextEdit]] = []
    private var redoStack: [[TextEdit]] = []

    public init(bytes: [UInt8], defaults: OrgSettings = .default) {
        source = SourceText(bytes: bytes)
        text = source.text
        tree = OrgParser.parse(text, defaults: defaults)
        self.defaults = defaults
    }

    public var mergeBase: [UInt8] { source.originalBytes }
    public var isDirty: Bool { text != source.text }
    public var isEditable: Bool { source.isEditable }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Bytes to write for the current text, keeping the file's BOM.
    public func encodedText() throws -> [UInt8] {
        guard isEditable else { throw EditError.readOnly }
        return source.encode(text)
    }

    // MARK: - Editing

    /// Applies non-overlapping edits, computed against `baseRevision`, as one undo step.
    public mutating func apply(_ edits: [TextEdit], baseRevision: Int) throws {
        guard isEditable else { throw EditError.readOnly }
        guard baseRevision == revision else { throw EditError.staleRevision }
        let inverse = try applyGroup(edits)
        undoStack.append(inverse)
        redoStack = []
    }

    /// Reverts the last edit group. Returns the edits applied, for mapping view state.
    public mutating func undo() -> [TextEdit]? {
        guard let group = undoStack.popLast() else { return nil }
        redoStack.append(try! applyGroup(group))
        return group
    }

    public mutating func redo() -> [TextEdit]? {
        guard let group = redoStack.popLast() else { return nil }
        undoStack.append(try! applyGroup(group))
        return group
    }

    /// Applies `edits` (old coordinates) and returns their inverse (new coordinates).
    private mutating func applyGroup(_ edits: [TextEdit]) throws -> [TextEdit] {
        let sorted = edits.sorted { $0.range.lowerBound < $1.range.lowerBound }
        for (first, second) in zip(sorted, sorted.dropFirst()) where first.range.upperBound > second.range.lowerBound {
            throw EditError.overlappingEdits
        }
        var inverse: [TextEdit] = []
        var shift = 0
        for edit in sorted {
            let start = edit.range.lowerBound + shift
            inverse.append(TextEdit(range: start..<(start + edit.replacement.utf16.count), replacement: utf16Slice(text, edit.range)))
            shift += edit.replacement.utf16.count - edit.range.count
        }
        // Back to front, so earlier offsets stay valid.
        for edit in sorted.reversed() {
            tree = OrgParser.reparse(tree, oldText: text, edit: edit, defaults: defaults)
            text = edit.apply(to: text)
        }
        revision += 1
        return inverse
    }

    // MARK: - Commands

    /// Runs `command` at `selection` and applies its edits as one undo step.
    public mutating func run(
        _ command: any OrgCommand, selection: [Range<Int>], now: Date = Date(),
        calendar: Calendar = .current, answers: [String: String] = [:]
    ) throws -> CommandStep {
        let context = EditContext(
            revision: revision, text: text, tree: tree, selection: selection,
            now: now, calendar: calendar, answers: answers
        )
        let step = command.run(in: context)
        if case .commit(let result) = step, !result.edits.isEmpty {
            try apply(result.edits, baseRevision: result.baseRevision)
        }
        return step
    }

    // MARK: - Disk

    /// The file on disk now holds `bytes`. Reloads an unedited buffer, merges into an edited
    /// one, and makes `bytes` the new merge base unless the merge conflicts.
    public mutating func diskChanged(to bytes: [UInt8]) -> ExternalChange {
        guard bytes != mergeBase else { return .unchanged }
        let disk = SourceText(bytes: bytes)
        if !isDirty {
            let edits = lineEdits(from: text, to: disk.text)
            replaceText(with: disk.text, source: disk)
            return .reloaded(edits)
        }
        return mergeIn(disk, base: source.text, newSource: disk)
    }

    /// Our bytes are on disk, but they replaced `theirs`, which was based on `base`. Merges
    /// their changes into the buffer and leaves the merge base at our bytes.
    public mutating func mergeOverwritten(_ theirs: [UInt8], base: [UInt8]) -> ExternalChange {
        mergeIn(SourceText(bytes: theirs), base: SourceText(bytes: base).text, newSource: source)
    }

    private mutating func mergeIn(_ theirs: SourceText, base: String, newSource: SourceText) -> ExternalChange {
        guard theirs.isValidUTF8 else {
            return .conflict([MergeConflict(base: base, ours: text, theirs: theirs.text)])
        }
        switch threeWayMerge(base: base, ours: text, theirs: theirs.text) {
        case .merged(let merged):
            let edits = lineEdits(from: text, to: merged)
            replaceText(with: merged, source: newSource)
            return .merged(edits)
        case .conflict(let conflicts):
            return .conflict(conflicts)
        }
    }

    /// Records that `bytes` were written. The text stays as is; edits made since the write keep
    /// the buffer dirty.
    public mutating func didWrite(_ bytes: [UInt8]) {
        source = SourceText(bytes: bytes)
    }

    /// Undo history can't be mapped through an external change, so it is cleared.
    private mutating func replaceText(with newText: String, source newSource: SourceText) {
        source = newSource
        if newText != text {
            text = newText
            tree = OrgParser.parse(newText, defaults: defaults)
            revision += 1
        }
        undoStack = []
        redoStack = []
    }
}

func utf16Slice(_ text: String, _ range: Range<Int>) -> String {
    let start = String.Index(utf16Offset: range.lowerBound, in: text)
    let end = String.Index(utf16Offset: range.upperBound, in: text)
    return String(text.unicodeScalars[start..<end])
}
