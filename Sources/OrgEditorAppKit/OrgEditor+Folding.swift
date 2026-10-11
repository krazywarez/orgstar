#if os(macOS)
import AppKit
import OrgCore
import OrgPresentation

extension OrgEditor {
    // MARK: - Folding

    public var foldState: FoldState {
        FoldState(folds: view.folds, bodyFolds: view.bodyFolds, wrapperFolds: view.wrapperFolds)
    }


    public func setFolds(_ state: FoldState) {
        setFolds(state, wrappers: nil)
    }

    /// `wrappers`, when given, holds every folded drawer and block.
    func setFolds(_ state: FoldState, wrappers: [Wrapper]?) {
        sparseHidden = nil
        view.folds = state.folds
        view.bodyFolds = state.bodyFolds
        view = view.pruned(to: document.tree, wrappers: false)
        // Found one by one, or all at once when there are many.
        let found = wrappers ?? (state.wrapperFolds.count > 32
            ? Wrappers.all(document.tree).filter { state.wrapperFolds.contains($0.start) }
            : state.wrapperFolds.compactMap { Wrappers.starting(at: $0, in: document.tree) })
        wrapperHidden = Dictionary(found.map { ($0.start, $0.hidden) }) { a, _ in a }
        view.wrapperFolds = Set(wrapperHidden.keys)
        updateHiddenAndLayout()
        orgTextView?.redrawLineNumbers()
        textView.needsDisplay = true
        let caret = textView.selectedRange().location
        if let range = hidden.containing(caret) { setCaret(range.lowerBound - 1) }
    }


    func updateHidden() {
        if let sparseHidden {
            let ns = textView.string as NSString
            // Headings whose next line is hidden show the fold ellipsis.
            let headings = Presentation.outline(document.tree).map(\.start).filter { start in
                let next = NSMaxRange(ns.lineRange(for: NSRange(location: start, length: 0)))
                return sparseHidden.contains { $0.contains(next) } && !sparseHidden.contains { $0.contains(start) }
            }
            folded.set(Set(headings).union(view.wrapperFolds))
            hidden.set(sparseHidden + Array(wrapperHidden.values) + narrowHidden)
            return
        }
        folded.set(view.folds.union(view.bodyFolds).union(view.wrapperFolds))
        hidden.set(Presentation.hiddenRanges(document.tree, folds: view.folds, bodyFolds: view.bodyFolds, wrapperRanges: Array(wrapperHidden.values)) + narrowHidden)
    }

    /// `updateHidden`, laying out again only the text that changed between hidden and shown
    /// and the headings whose fold mark changed. Laying out the whole file again makes TextKit
    /// estimate the height of everything above the window afresh, which moves the text under it.
    private func updateHiddenAndLayout() {
        let oldHidden = hidden.all
        let oldFolded = folded.all
        updateHidden()
        invalidateLayout(from: oldHidden, to: hidden.all)
        invalidateLayout(lines: oldFolded.symmetricDifference(folded.all).map { $0..<$0 })
    }

    /// Lays out again the ranges in `old` and not in `new`, and the other way round.
    func invalidateLayout(from old: [Range<Int>], to new: [Range<Int>]) {
        invalidateLayout(lines: Array(Set(old).symmetricDifference(new)))
    }

    /// Lays out `ranges` again, each widened to whole lines and to the line before it: the
    /// heading or opening line of a fold, whose fragment draws the fold mark.
    func invalidateLayout(lines ranges: [Range<Int>]) {
        guard !ranges.isEmpty, let content = textLayoutManager.textContentManager else { return }
        let text = textView.string as NSString
        for range in ranges {
            let lower = text.lineRange(for: NSRange(location: max(0, min(range.lowerBound, text.length) - 1), length: 0)).location
            let upper = NSMaxRange(text.lineRange(for: NSRange(location: min(range.upperBound, text.length), length: 0)))
            guard let start = content.location(content.documentRange.location, offsetBy: lower),
                  let end = content.location(start, offsetBy: upper - lower),
                  let textRange = NSTextRange(location: start, end: end) else { continue }
            textLayoutManager.invalidateLayout(for: textRange)
        }
    }

    /// Runs `change`, which lays the whole file out again, and brings the line that was at the
    /// top of the window back there. TextKit estimates the height of text it hasn't laid out,
    /// so the same scroll position lands on different text after a fresh layout.
    func keepingTopLine(_ change: () -> Void) {
        guard let scroll = textView.enclosingScrollView, let content = textLayoutManager.textContentManager else { return change() }
        let visible = scroll.documentVisibleRect
        let top = visible.minY - textView.textContainerOrigin.y
        let start = content.documentRange.location
        let anchor = textLayoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, top))).map {
            (offset: content.offset(from: start, to: $0.rangeInElement.location), within: top - $0.layoutFragmentFrame.minY)
        }
        change()
        guard let anchor, anchor.offset > 0, let location = content.location(start, offsetBy: anchor.offset),
              let above = NSTextRange(location: start, end: location) else { return }
        // Styled now, not in the background passes, which would lay the text out again.
        while styledUpTo < anchor.offset { styleNextChunk(Self.styleChunk) }
        textLayoutManager.ensureLayout(for: above)
        guard let fragment = textLayoutManager.textLayoutFragment(for: location) else { return }
        let frame = fragment.layoutFragmentFrame
        let y = frame.minY + textView.textContainerOrigin.y + max(0, min(anchor.within, frame.height))
        textLayoutManager.ensureLayout(for: CGRect(x: 0, y: frame.minY, width: frame.width, height: 2 * visible.height))
        // The view grows to the laid-out height on its next layout pass; the scroll needs it now.
        let needed = textLayoutManager.usageBoundsForTextContainer.maxY + textView.textContainerOrigin.y + textView.textContainerInset.height
        if textView.frame.height < needed { textView.setFrameSize(NSSize(width: textView.frame.width, height: needed)) }
        textView.scroll(NSPoint(x: visible.minX, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: - Sparse trees


    func showSparseTree(_ points: [Int], highlights: [Range<Int>]) {
        let text = textView.string
        var state = foldState
        for start in state.wrapperFolds where points.contains(where: { Wrappers.starting(at: start, in: document.tree)?.hidden.contains($0) == true }) {
            state.wrapperFolds.remove(start)
        }
        sparseHidden = nil
        setFolds(state)
        sparseHidden = SparseTree.hidden(points, in: text, tree: document.tree)
        self.highlights = highlights
        keepingTopLine {
            updateHiddenAndLayout()
            restyleOutsideEditing(0..<utf16Length)
        }
        orgTextView?.redrawLineNumbers()
        textView.needsDisplay = true
        let caret = textView.selectedRange().location
        if let range = hidden.containing(caret) { setCaret(max(0, range.lowerBound - 1)) }
    }

    /// Leaves a sparse tree for ordinary folds: headings with something shown below them
    /// open, the others folded.
    func leaveSparseTree() {
        guard let sparse = sparseHidden else { return }
        sparseHidden = nil
        let outline = Presentation.outline(document.tree)
        let ns = textView.string as NSString
        var open: Set<Int> = []
        for entry in outline where !sparse.contains(where: { $0.contains(entry.start) }) {
            var parent = entry.parent
            while let p = parent {
                open.insert(outline[p].start)
                parent = outline[p].parent
            }
            let next = NSMaxRange(ns.lineRange(for: NSRange(location: entry.start, length: 0)))
            if next < entry.end, !sparse.contains(where: { $0.contains(next) }) { open.insert(entry.start) }
        }
        var state = foldState
        state.folds = Set(outline.map(\.start)).subtracting(open)
        state.bodyFolds = []
        setFolds(state)
    }

    func clearHighlights() {
        guard !highlights.isEmpty else { return }
        let old = highlights
        highlights = []
        for range in old where range.upperBound <= utf16Length { restyleOutsideEditing(range) }
    }

    func applyHighlights(_ range: Range<Int>, in storage: NSTextStorage) {
        for highlight in highlights where highlight.overlaps(range) && highlight.upperBound <= storage.length {
            storage.addAttribute(.backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.45), range: NSRange(highlight.clamped(to: range)))
        }
    }

    // MARK: - Narrowing


    func narrow(_ id: String) {
        let caret = textView.selectedRange().location
        do {
            switch id {
            case "org.narrow.subtree": narrowed = try Narrowing.subtree(at: caret, in: textView.string)
            // `org-toggle-narrow-to-subtree`.
            case "org.narrow.toggle": narrowed = narrowed == nil ? try Narrowing.subtree(at: caret, in: textView.string) : nil
            case "org.narrow.block": narrowed = try Narrowing.block(at: caret, in: textView.string)
            default: narrowed = nil
            }
        } catch let failure as Narrowing.Failure {
            onMessage?(failure.message)
            return
        } catch {
            return
        }
        updateHiddenAndLayout()
        orgTextView?.redrawLineNumbers()
        textView.needsDisplay = true
        if let narrowed {
            setCaret(max(narrowed.lowerBound, min(caret, narrowed.upperBound)))
            textView.scrollRangeToVisible(NSRange(location: narrowed.lowerBound, length: 0))
        } else {
            textView.scrollRangeToVisible(NSRange(location: caret, length: 0))
        }
    }

    /// What narrowing hides: the text before the region, and the lines after it.
    private var narrowHidden: [Range<Int>] {
        guard let narrowed else { return [] }
        let length = utf16Length
        var ranges: [Range<Int>] = []
        if narrowed.lowerBound > 0 { ranges.append(0..<narrowed.lowerBound) }
        let ns = textView.string as NSString
        let tail = narrowed.upperBound < length && ns.character(at: narrowed.upperBound) == 10 ? narrowed.upperBound + 1 : narrowed.upperBound
        if tail < length { ranges.append(tail..<length) }
        return ranges
    }
}
#endif
