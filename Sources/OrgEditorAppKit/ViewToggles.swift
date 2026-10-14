#if os(macOS)
import AppKit
import OrgCore
import OrgPresentation

/// Spell checking, line truncation and mouse clicks on heading stars and checkboxes.
extension OrgEditor {
    // MARK: - Spell checking

    public var spellChecking: Bool {
        get { textView.isContinuousSpellCheckingEnabled }
        set {
            for view in textViews { view.isContinuousSpellCheckingEnabled = newValue }
            if !newValue, let storage = textView.textStorage {
                storage.removeAttribute(.spellingState, range: NSRange(location: 0, length: storage.length))
            }
        }
    }

    func toggleSpellCheck() {
        spellChecking.toggle()
        onMessage?(spellChecking ? "Spell checking enabled" : "Spell checking disabled")
    }

    /// Ranges spell-fu skips in Org, for this revision of the text.
    func spellSkipped() -> [Range<Int>] {
        if let cached = spellSkipCache, cached.text == document.text { return cached.ranges }
        let ranges = isOrg ? SpellCheck.skipped(document.tree) : []
        spellSkipCache = (document.text, ranges)
        return ranges
    }

    // MARK: - Truncation

    /// `toggle-truncate-lines`: long lines run off the right edge instead of wrapping.
    public var truncatesLines: Bool {
        get { !(textView.textContainer?.widthTracksTextView ?? true) }
        set {
            guard let container = textView.textContainer, newValue != truncatesLines else { return }
            let scroll = textView.enclosingScrollView
            keepingTopLine {
                scroll?.hasHorizontalScroller = newValue
                textView.isHorizontallyResizable = newValue
                if newValue {
                    container.widthTracksTextView = false
                    container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                    textView.autoresizingMask = [.width, .height]
                } else {
                    let width = scroll?.contentSize.width ?? textView.frame.width
                    textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
                    container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
                    container.widthTracksTextView = true
                    textView.autoresizingMask = [.width]
                }
                textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
            }
            // Truncated lines take the whole width; wrapped ones the text width again.
            (textView as? OrgTextView)?.updateGutter()
            textView.needsDisplay = true
        }
    }

    func toggleTruncateLines() {
        truncatesLines.toggle()
        onMessage?(truncatesLines ? "Truncate long lines enabled" : "Truncate long lines disabled")
    }

    // MARK: - Clicks

    /// A click on a heading's stars cycles it; a click on a checkbox toggles it.
    func click(at offset: Int) -> Bool {
        guard isOrg else { return false }
        var node = document.tree.root
        while let child = node.child(containing: offset) ?? node.child(containing: offset - 1) {
            node = child
            if child.kind == .heading || child.kind == .item { break }
        }
        let tokens = node.tokens.filter { $0.range.lowerBound <= offset && offset <= $0.range.upperBound }
        if node.kind == .heading, tokens.contains(where: { $0.kind == .stars }) {
            setCaret(node.range.lowerBound)
            _ = cycleAtCaret()
            return true
        }
        if node.kind == .item, let box = tokens.first(where: { $0.kind == .checkbox }) {
            setCaret(box.range.lowerBound)
            run("org.checkbox.toggle")
            return true
        }
        return false
    }
}

extension OrgEditor: NSTextViewDelegate {
    public func textViewDidChangeSelection(_ notification: Notification) {
        // Another view's caret moving (a mapped selection, say) is its own business.
        guard (notification.object as AnyObject?) === textView else { return }
        selectionChanged()
        if completionPopup != nil, let popup = completionPopup, textView.selectedRange().location != popup.completion.range.upperBound {
            refreshCompletion()
        }
    }

    public func textDidChange(_ notification: Notification) {
        textTyped()
    }

    /// No spelling marks in code, links, dates, tags or keywords.
    public func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range affectedCharRange: NSRange) -> Int {
        guard value != 0 else { return value }
        let range = affectedCharRange.location..<NSMaxRange(affectedCharRange)
        return spellSkipped().contains { $0.overlaps(range) } ? 0 : value
    }
}
#endif
