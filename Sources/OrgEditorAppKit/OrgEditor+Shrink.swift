#if os(macOS)
import AppKit
import OrgCore
import OrgDocument
import OrgPresentation

extension OrgEditor {
    // MARK: - Shrunk table columns


    /// Narrows `columns` of `table` and widens its others.
    private func setShrunk(_ columns: [Int], in table: Range<Int>) {
        shrunk.set(columns, in: table, text: textView.string)
        restyleOutsideEditing(table)
        invalidateLayout(lines: [table])
        redrawViews()
    }

    /// C-c TAB in a table: `org-table-toggle-column-width`; `shrink` for `org-table-shrink`,
    /// `expand` for `org-table-expand`.
    func tableColumnWidth(_ id: String) {
        switch shrunk.change(for: id, at: textView.selectedRange().location, in: textView.string) {
        case .notInTable: onMessage?("Not in a table")
        case .set(let columns, let table): setShrunk(columns, in: table)
        case .ask(let table, let current, let max):
            onPrompt?(Prompt(key: "columns", message: "Column ranges (e.g. 2-4 6-):")) { [weak self] answer in
                guard let self, let answer else { return }
                self.setShrunk(ShrunkColumns.toggled(current, TableShrink.columns(answer, max: max)), in: table)
            }
        }
    }

    /// Hides each shrunk segment's text and draws its display where the text was.
    func applyShrunk(_ range: Range<Int>, in storage: NSTextStorage) {
        guard !shrunk.isEmpty else { return }
        let cell = ("0" as NSString).size(withAttributes: [.font: theme.font]).width
        for segment in shrunk.segments where segment.range.overlaps(range) && segment.range.upperBound <= storage.length {
            let r = segment.range
            let shown = segment.display.count
            let kept = min(shown, r.count)
            if r.count > kept { storage.addAttributes(theme.hidden, range: NSRange(location: r.lowerBound, length: r.count - kept)) }
            guard kept > 0 else { continue }
            let visible = NSRange(location: r.upperBound - kept, length: kept)
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: visible)
            storage.addAttribute(.orgEntityDisplay, value: segment.display, range: NSRange(location: visible.location, length: 1))
            if shown > kept { storage.addAttribute(.kern, value: CGFloat(shown - kept) * cell, range: NSRange(location: NSMaxRange(visible) - 1, length: 1)) }
        }
    }

    /// Moves drawer and block folds through `edit`, checking again only those near it.
    func mapWrapperFolds(through edit: TextEdit, near affected: Range<Int>) {
        guard !wrapperHidden.isEmpty else { return }
        var mapped: [Int: Range<Int>] = [:]
        let entries = Array(wrapperHidden)
        // One pass maps every start and range.
        let moved = ViewState(selection: entries.flatMap { [$0.key..<$0.key, $0.value] }).mapped(through: [edit]).selection
        for i in entries.indices {
            let newStart = moved[2 * i].lowerBound
            let newRange = moved[2 * i + 1]
            if newStart <= affected.upperBound, newRange.upperBound >= affected.lowerBound {
                if let wrapper = Wrappers.starting(at: newStart, in: document.tree) { mapped[newStart] = wrapper.hidden }
            } else {
                mapped[newStart] = newRange
            }
        }
        wrapperHidden = mapped
        view.wrapperFolds = Set(mapped.keys)
    }

    /// TAB on the first or last line of a drawer or block folds or unfolds it; on a heading,
    /// cycles folded, children, subtree. Returns false elsewhere.
    @discardableResult
    public func cycleAtCaret() -> Bool {
        leaveSparseTree()
        let caret = textView.selectedRange().location
        guard let state = Presentation.cycle(at: caret, in: document.tree, foldState) else { return false }
        setFolds(state)
        // Off a closing line that folding hid, to the opening line, as org does.
        if let wrapper = Wrappers.toggleable(at: caret, in: document.tree), hidden.containing(caret) != nil { setCaret(wrapper.start) }
        return true
    }

    /// Doom's `za`, `zo` (on a heading line) and `zc` (anywhere in a subtree).
    func fold(_ id: String) {
        leaveSparseTree()
        let caret = textView.selectedRange().location
        let tree = document.tree
        let next: FoldState?
        if id == "org.fold.close" {
            next = Presentation.outline(tree).last { $0.start <= caret && (caret < $0.end || $0.end == utf16Length) }
                .map { Presentation.hideSubtree($0.start, foldState) }
        } else {
            next = Presentation.heading(containing: caret, in: tree).map {
                id == "org.fold.open" ? Presentation.openFold($0, in: tree, foldState) : Presentation.toggleFold($0, in: tree, foldState)
            }
        }
        if let next, next != foldState { setFolds(next) }
    }

    /// Shift-TAB: overview, contents, show all.
    public func cycleGlobal() {
        leaveSparseTree()
        let (visibility, state) = Presentation.cycleGlobal(from: globalVisibility, in: document.tree, wrapperFolds: view.wrapperFolds)
        globalVisibility = visibility
        setFolds(state)
    }

    /// Unfolds whatever hides `offset`, puts the caret there and scrolls to it.
    public func reveal(_ offset: Int) {
        let target = max(0, min(offset, utf16Length))
        if let narrowed, !(narrowed.lowerBound...narrowed.upperBound).contains(target) { narrow("org.widen") }
        unfold(around: target)
        setCaret(target)
        textView.scrollRangeToVisible(NSRange(location: target, length: 0))
    }

    /// Unfolds the headings whose folds hide `offset`, leaving the selection alone.
    func unfold(around offset: Int) {
        leaveSparseTree()
        var state = foldState
        for entry in Presentation.outline(document.tree) where entry.start < offset && offset < entry.end {
            state.folds.remove(entry.start)
            state.bodyFolds.remove(entry.start)
        }
        for start in state.wrapperFolds where Wrappers.starting(at: start, in: document.tree)?.hidden.contains(offset) == true {
            state.wrapperFolds.remove(start)
        }
        guard state != foldState else { return }
        setFolds(state)
    }

    /// Applies edits through the text view as one undo step, not merged with typing around it.
    func applyEdits(_ edits: [TextEdit]) {
        guard !edits.isEmpty, let storage = textView.textStorage else { return }
        textView.breakUndoCoalescing()
        textView.undoManager?.beginUndoGrouping()
        // By lines, so a fold between two changes stays.
        let text = storage.string
        for edit in edits.flatMap({ splitByLines($0, in: text) }).sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            let range = NSRange(edit.range)
            guard textView.shouldChangeText(in: range, replacementString: edit.replacement) else { continue }
            storage.replaceCharacters(in: range, with: edit.replacement)
            textView.didChangeText()
        }
        textView.undoManager?.endUndoGrouping()
        textView.breakUndoCoalescing()
    }

    func setCaret(_ offset: Int) {
        let clamped = max(0, min(offset, utf16Length))
        previousSelection = clamped
        textView.setSelectedRange(NSRange(location: clamped, length: 0))
    }
}
#endif
