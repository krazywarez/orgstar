#if os(iOS)
import OrgApp
import OrgCore
import OrgDocument
import OrgHighlight
import OrgPresentation
import UIKit

extension MobileEditor {
    // MARK: - Styling

    func load(_ text: String) {
        loading = true
        textView.textStorage.setAttributedString(NSAttributedString(string: text, attributes: theme.base))
        loading = false
        shaded.set(Presentation.shadedBlocks(document.tree), folded: [])
        restyle(0..<(text as NSString).length)
        textView.typingAttributes = theme.base
    }

    /// The text view's own colors, and the block band's.
    func applyThemeToView() {
        for view in textViews { applyThemeToView(view) }
        fragmentStyle.set(blockBackground: theme.color("block-background") ?? .clear, width: textView.bounds.width)
    }

    func applyThemeToView(_ view: UITextView) {
        view.backgroundColor = theme.color("background") ?? .systemBackground
        view.tintColor = theme.color("cursor")
        view.typingAttributes = theme.base
        themeSelection(view)
    }

    /// The selection in the theme's selection color: the text view's selection display
    /// interaction draws it with our highlight view; the cursor and handles keep the tint.
    private func themeSelection(_ textView: UITextView) {
        guard let interaction = textView.interactions.lazy.compactMap({ $0 as? UITextSelectionDisplayInteraction }).first else { return }
        let view = interaction.highlightView as? SelectionHighlightView ?? SelectionHighlightView()
        view.color = theme.color("selection") ?? UIColor.tintColor.withAlphaComponent(0.25)
        if interaction.highlightView !== view { interaction.highlightView = view }
        selectionColor = view.color
    }

    /// The highlight view draws under the text, so a block's band would cover it: blocks the
    /// selection enters or leaves are laid out again to draw it over their band.
    func redrawSelectedBlocks() {
        let selected = textView.selectedRange
        let range = selected.length > 0 ? selected.location..<NSMaxRange(selected) : nil
        let old = fragmentStyle.selection?.range
        fragmentStyle.set(selection: range, color: selectionColor)
        let touched = [old, range].compactMap { $0 }
        redraw(blocks: shaded.all.filter { block in touched.contains { $0.overlaps(block) } })
    }

    /// Lays `blocks` out again and asks their fragments, which are kept across layout passes,
    /// to draw again.
    private func redraw(blocks: [Range<Int>]) {
        for manager in layoutManagers {
            guard let content = manager.textContentManager else { continue }
            for block in blocks {
                guard let start = content.location(content.documentRange.location, offsetBy: block.lowerBound),
                      let end = content.location(start, offsetBy: block.count),
                      let textRange = NSTextRange(location: start, end: end) else { continue }
                manager.invalidateRenderingAttributes(for: textRange)
                manager.invalidateLayout(for: textRange)
            }
        }
        for view in textViews { view.setNeedsDisplay() }
    }

    /// The band behind blocks spans the view's width, or the widest line's when truncated;
    /// images are as wide as the view allows. Only the blocks read the band's width, so a
    /// wider line in a truncated file, which widens the band on each layout pass, redraws
    /// the blocks alone: laying the whole file out again moves the text under the view.
    func viewResized() {
        // With several views, the band spans the widest and images fit the narrowest.
        let band = fragmentStyle.blockBand
        let width = textViews.map { max($0.bounds.width, truncatesLines ? $0.contentSize.width : 0) }.max() ?? 0
        let narrowest = textViews.map(\.bounds.width).filter { $0 > 0 }.min() ?? textView.bounds.width
        let resized = imageWidth != narrowest
        guard band.width != width || resized else { return }
        fragmentStyle.set(blockBackground: band.color, width: width)
        imageWidth = narrowest
        guard resized else {
            redraw(blocks: shaded.all)
            return
        }
        keepingTopLine {
            if showsImages { restyle(0..<textView.textStorage.length) }
            for manager in layoutManagers {
                manager.invalidateRenderingAttributes(for: manager.documentRange)
                manager.invalidateLayout(for: manager.documentRange)
            }
        }
    }

    /// Styles the whole file again.
    func restyleAll() {
        let interval = Perf.begin("editor.restyleAll")
        defer { interval.end() }
        keepingTopLine {
            restyle(0..<textView.textStorage.length)
            for manager in layoutManagers { manager.invalidateLayout(for: manager.documentRange) }
        }
    }

    /// Lays out `ranges` again, each widened to whole lines and to the line before it: the
    /// heading or opening line of a fold, whose fragment draws the fold mark. Laying out the
    /// whole file again makes TextKit estimate the height of everything above the view afresh,
    /// which moves the text under it.
    func invalidateLayout(lines ranges: [Range<Int>]) {
        guard !ranges.isEmpty else { return }
        let text = textView.textStorage.string as NSString
        for manager in layoutManagers {
            guard let content = manager.textContentManager else { continue }
            for range in ranges {
                let lower = text.lineRange(for: NSRange(location: max(0, min(range.lowerBound, text.length) - 1), length: 0)).location
                let upper = NSMaxRange(text.lineRange(for: NSRange(location: min(range.upperBound, text.length), length: 0)))
                guard let start = content.location(content.documentRange.location, offsetBy: lower),
                      let end = content.location(start, offsetBy: upper - lower),
                      let textRange = NSTextRange(location: start, end: end) else { continue }
                manager.invalidateLayout(for: textRange)
            }
        }
    }

    /// Runs `change`, which lays the whole file out again, and brings the line that was at the
    /// top of the view back there. TextKit estimates the height of text it hasn't laid out,
    /// so the same scroll position lands on different text after a fresh layout.
    func keepingTopLine(_ change: () -> Void) {
        guard let manager = textView.textLayoutManager, let content = manager.textContentManager else { return change() }
        let inset = textView.textContainerInset
        let top = textView.contentOffset.y + textView.adjustedContentInset.top - inset.top
        let start = content.documentRange.location
        let anchor = manager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, top))).map {
            (offset: content.offset(from: start, to: $0.rangeInElement.location), within: top - $0.layoutFragmentFrame.minY)
        }
        change()
        guard let anchor, anchor.offset > 0, let location = content.location(start, offsetBy: anchor.offset),
              let above = NSTextRange(location: start, end: location) else { return }
        manager.ensureLayout(for: above)
        guard let fragment = manager.textLayoutFragment(for: location) else { return }
        let frame = fragment.layoutFragmentFrame
        manager.ensureLayout(for: CGRect(x: 0, y: frame.minY, width: frame.width, height: 2 * textView.bounds.height))
        // The view grows to the laid-out height on its next layout pass; the scroll needs it now.
        let needed = manager.usageBoundsForTextContainer.maxY + inset.top + inset.bottom
        if textView.contentSize.height < needed { textView.contentSize.height = needed }
        let y = frame.minY + inset.top + max(0, min(anchor.within, frame.height)) - textView.adjustedContentInset.top
        textView.contentOffset = CGPoint(x: textView.contentOffset.x, y: y)
    }

    /// Styles are set after the edit has been processed, as TextKit asks.
    func scheduleRestyle(_ range: Range<Int>) {
        if let pending = restyleScheduled {
            restyleScheduled = min(pending.lowerBound, range.lowerBound)..<max(pending.upperBound, range.upperBound)
            return
        }
        restyleScheduled = range
        DispatchQueue.main.async { [weak self] in
            guard let self, let range = self.restyleScheduled else { return }
            self.restyleScheduled = nil
            self.shaded.set(Presentation.shadedBlocks(self.document.tree), folded: [])
            // Small files are restyled whole: a heading or block line changes what follows it.
            let length = self.textView.textStorage.length
            self.restyle(length < 60_000 ? 0..<length : range)
            self.updateHidden()
            self.textView.typingAttributes = self.theme.base
        }
    }

    private var caretLine: NSRange {
        let text = textView.textStorage.string as NSString
        return text.lineRange(for: NSRange(location: min(textView.selectedRange.location, text.length), length: 0))
    }

    /// Sets attributes for the whole lines in `range`, as the Mac editor does.
    func restyle(_ range: Range<Int>) {
        let interval = Perf.begin("editor.restyle")
        defer { interval.end() }
        let storage = textView.textStorage
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }
        let lower = min(range.lowerBound, ns.length)
        let lines = ns.lineRange(for: NSRange(location: lower, length: min(range.count, ns.length - lower)))
        let whole = lines.location..<NSMaxRange(lines)
        storage.beginEditing()
        storage.setAttributes(theme.base, range: lines)
        if indented {
            for line in Presentation.lineIndents(document.tree, in: whole) {
                storage.addAttribute(.paragraphStyle, value: paragraphStyle(line.firstLine, line.wrapped), range: NSRange(line.range))
            }
        }
        let revealed = caretLine
        var scriptExclusions: [Range<Int>] = []
        for run in Presentation.styles(document.tree, in: whole, highlighter: Self.highlighter) {
            let clipped = NSIntersectionRange(NSRange(run.range), lines)
            guard clipped.length > 0 else { continue }
            if Presentation.skipsLeadingStars(run.role, indented: indented, hideStars: hideStars) { continue }
            if !showMarkup, Presentation.hidesWithMarkup(run.role, options: options), NSIntersectionRange(clipped, revealed).length == 0 {
                storage.addAttributes(theme.hidden, range: clipped)
            } else {
                theme.apply(run.role, to: storage, range: clipped)
            }
            if Presentation.excludesScripts(run.role) { scriptExclusions.append(run.range) }
        }
        if !showMarkup, options.prettyEntities { prettify(whole, in: storage, revealed: revealed, scriptExclusions: scriptExclusions) }
        applyShrunk(whole, in: storage)
        applyImages(whole, in: storage, revealed: revealed)
        applyLatex(whole, in: storage, revealed: revealed)
        storage.endEditing()
    }

    func paragraphStyle(_ firstLine: Int, _ wrapped: Int) -> NSParagraphStyle {
        if let style = paragraphStyles[[firstLine, wrapped]] { return style }
        let style = theme.paragraphStyle(firstLine: firstLine, wrapped: wrapped)
        paragraphStyles[[firstLine, wrapped]] = style
        return style
    }

    /// `org-pretty-entities`: entities drawn as their character over the entity's last
    /// character (the rest hidden), sub/superscripts raised without their markers.
    private func prettify(_ range: Range<Int>, in storage: NSTextStorage, revealed: NSRange, scriptExclusions: [Range<Int>]) {
        let runs = Presentation.prettyRuns(
            storage.string as NSString, in: range, revealedLine: revealed.location, inBlock: { shaded.containing($0) != nil },
            scriptExclusions: scriptExclusions, subSuperscriptsNeedBraces: options.subSuperscriptsNeedBraces
        )
        for (lineStart, run) in runs {
            switch run {
            case .entity(let r, let display):
                let start = lineStart + r.lowerBound
                let last = lineStart + r.upperBound - 1
                let color = storage.attribute(.foregroundColor, at: last, effectiveRange: nil) as? UIColor ?? theme.foreground
                if last > start { storage.addAttributes(theme.hidden, range: NSRange(location: start, length: last - start)) }
                storage.addAttributes([.foregroundColor: UIColor.clear, .orgEntityDisplay: display, .orgEntityColor: color], range: NSRange(location: last, length: 1))
            case .script(let markers, let body, let superscript):
                for marker in markers {
                    storage.addAttributes(theme.hidden, range: NSRange(location: lineStart + marker.lowerBound, length: marker.count))
                }
                let size = theme.font.pointSize
                storage.addAttributes([
                    .font: theme.font.withSize(size * 0.7),
                    .baselineOffset: (superscript ? 0.3 : -0.3) * size,
                ], range: NSRange(location: lineStart + body.lowerBound, length: body.count))
            }
        }
    }

    /// Moving to another line shows its markup and hides the last one's.
    func revealCaretLine() {
        // LaTeX previews show their source on the caret's line whether or not markup shows.
        guard !showMarkup || showsLatex else { return }
        let line = caretLine
        guard line != revealedLine else { return }
        let text = textView.textStorage.string as NSString
        // The old line may have moved with edits since; restyle the line now at its start.
        let old = revealedLine.flatMap { $0.location <= text.length ? text.lineRange(for: NSRange(location: $0.location, length: 0)) : nil }
        revealedLine = line
        for range in [old, line].compactMap({ $0 }) {
            restyle(range.location..<NSMaxRange(range))
        }
    }
}
#endif
