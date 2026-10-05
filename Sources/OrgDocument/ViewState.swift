import OrgCore

/// Per-window state for one document: selection and folds, in UTF-16 offsets.
public struct ViewState: Sendable, Equatable {
    public var selection: [Range<Int>]
    /// Start offsets of folded headings.
    public var folds: Set<Int>

    public init(selection: [Range<Int>] = [0..<0], folds: Set<Int> = []) {
        self.selection = selection
        self.folds = folds
    }

    /// Maps through non-overlapping edits given in old coordinates.
    public func mapped(through edits: [TextEdit]) -> ViewState {
        let sorted = edits.sorted { $0.range.lowerBound < $1.range.lowerBound }
        return ViewState(
            selection: selection.map { mapOffset($0.lowerBound, sorted)..<mapOffset($0.upperBound, sorted) },
            folds: Set(folds.map { mapOffset($0, sorted) })
        )
    }

    /// Drops folds that no longer sit at the start of a heading.
    public func pruned(to tree: OrgTree) -> ViewState {
        let headings = Set(tree.root.descendants().filter { $0.kind == .heading }.map(\.range.lowerBound))
        return ViewState(selection: selection, folds: folds.intersection(headings))
    }
}

/// An offset before an edit stays put; one at the start of a replaced range stays at its start;
/// one inside it, at its end, or at an insertion point moves past the replacement.
func mapOffset(_ offset: Int, _ sortedEdits: [TextEdit]) -> Int {
    var shift = 0
    for edit in sortedEdits {
        let lower = edit.range.lowerBound, upper = edit.range.upperBound
        if offset < lower || (offset == lower && upper > lower) { return offset + shift }
        if offset <= upper { return lower + shift + edit.replacement.utf16.count }
        shift += edit.replacement.utf16.count - edit.range.count
    }
    return offset + shift
}
