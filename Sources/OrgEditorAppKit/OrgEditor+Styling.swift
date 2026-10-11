#if os(macOS)
import AppKit
import OrgCore
import OrgPresentation

extension OrgEditor {
    // MARK: - Styling

    func restyleOutsideEditing(_ range: Range<Int>) {
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        restyle(range, in: storage)
        storage.endEditing()
    }

    /// Sets attributes for whole lines in `range`. Safe inside `didProcessEditing`, where
    /// attribute changes are allowed and characters must not change.
    func restyle(_ range: Range<Int>, in storage: NSTextStorage) {
        guard !range.isEmpty else { return }
        let whole = NSRange(range)
        storage.setAttributes(theme.base, range: whole)
        guard isOrg else {
            for run in plainRuns() where run.range.overlaps(range) {
                guard let clipped = clip(run.range, to: range) else { continue }
                theme.apply(.syntax(run.category), to: storage, range: clipped)
            }
            return
        }
        if indented {
            for line in Presentation.lineIndents(document.tree, in: range) {
                storage.addAttribute(.paragraphStyle, value: paragraphStyle(line.firstLine, line.wrapped), range: NSRange(line.range))
            }
        }
        let revealed = caretLine
        var scriptExclusions: [Range<Int>] = []
        for run in Presentation.styles(document.tree, in: range, highlighter: highlighter) {
            guard let clipped = clip(run.range, to: range) else { continue }
            if Presentation.skipsLeadingStars(run.role, indented: indented, hideStars: hideStars) { continue }
            if !showMarkup, Presentation.hidesWithMarkup(run.role, options: options), NSIntersectionRange(clipped, revealed).length == 0 {
                storage.addAttributes(theme.hidden, range: clipped)
            } else {
                theme.apply(run.role, to: storage, range: clipped)
            }
            if Presentation.excludesScripts(run.role) { scriptExclusions.append(run.range) }
        }
        if !showMarkup, options.prettyEntities { prettify(range, in: storage, revealed: revealed, scriptExclusions: scriptExclusions) }
        applyShrunk(range, in: storage)
        applyHighlights(range, in: storage)
        applyImages(range, in: storage, revealed: revealed)
        applyLatex(range, in: storage, revealed: revealed)
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
                if last > start { storage.addAttributes(theme.hidden, range: NSRange(location: start, length: last - start)) }
                storage.addAttributes([.foregroundColor: NSColor.clear, .orgEntityDisplay: display], range: NSRange(location: last, length: 1))
            case .script(let markers, let body, let superscript):
                for marker in markers {
                    storage.addAttributes(theme.hidden, range: NSRange(location: lineStart + marker.lowerBound, length: marker.count))
                }
                let size = theme.font.pointSize
                storage.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: size * 0.7, weight: .regular),
                    .baselineOffset: (superscript ? 0.3 : -0.3) * size,
                ], range: NSRange(location: lineStart + body.lowerBound, length: body.count))
            }
        }
    }

    /// Moving to another line shows its markup and hides the last one's.
    func revealCaretLine() {
        // LaTeX previews show their source on the caret's line whether or not markup shows.
        guard !showMarkup || showsLatex, isOrg else { return }
        let line = caretLine
        guard line != revealedLine else { return }
        let text = textView.string as NSString
        // The old line may have moved with edits since; restyle the line now at its start.
        let old = revealedLine.flatMap { $0.location <= text.length ? text.lineRange(for: NSRange(location: $0.location, length: 0)) : nil }
        revealedLine = line
        for range in [old, line].compactMap({ $0 }) where range.location < styledUpTo {
            restyleOutsideEditing(range.location..<NSMaxRange(range))
        }
    }

    /// Code highlights for the whole file in plain mode.
    private func plainRuns() -> [(range: Range<Int>, category: SyntaxCategory)] {
        guard case .plain(let language?) = mode, let highlighter else { return [] }
        if let codeRuns, codeRuns.revision == document.revision { return codeRuns.runs }
        let runs = highlighter.highlights(language: language, code: document.text)
        codeRuns = (document.revision, runs)
        return runs
    }

    private func paragraphStyle(_ firstLine: Int, _ wrapped: Int) -> NSParagraphStyle {
        let key = IndentKey(firstLine: firstLine, wrapped: wrapped)
        if let style = paragraphStyles[key] { return style }
        let style = theme.paragraphStyle(firstLine: firstLine, wrapped: wrapped)
        paragraphStyles[key] = style
        return style
    }

    private func clip(_ run: Range<Int>, to range: Range<Int>) -> NSRange? {
        let clipped = run.clamped(to: range)
        return clipped.isEmpty ? nil : NSRange(clipped)
    }

    /// The region an edit affects in one version of the tree: inside the innermost section
    /// holding the edited lines (plus the line after), every element that overlaps them or the
    /// line on either side. A changed heading line, or an added or removed heading, widens it
    /// to that section's whole own body. Run on the old and the new tree, the union covers
    /// elements that grew and elements that shrank.
    static func affectedRange(_ tree: OrgTree, _ text: NSString, _ start: Int, _ end: Int, touchedHeadings: Bool) -> Range<Int> {
        let lines = text.lineRange(for: NSRange(location: start, length: min(end + 1, text.length) - start))
        let lineRange = lines.location..<(lines.location + lines.length)
        let around = max(0, lineRange.lowerBound - 1)..<min(text.length, lineRange.upperBound + 1)
        var container = tree.root
        while let child = container.child(containing: lineRange.lowerBound),
              child.kind == .section || child.kind == .zerothSection,
              lineRange.upperBound <= child.range.upperBound {
            container = child
        }
        var lower = lineRange.lowerBound
        var upper = lineRange.upperBound
        // Tables and lists carry no styling of their own, so inside them only the rows or
        // items around the edit change, however large they are.
        func overlapping(_ nodes: [SyntaxNode]) -> [SyntaxNode] {
            nodes.filter { $0.range.overlaps(around) }.flatMap { node -> [SyntaxNode] in
                guard [.table, .plainList, .item].contains(node.kind) else { return [node] }
                let inner = overlapping(node.children(overlapping: around))
                return inner.isEmpty ? [node] : inner
            }
        }
        for child in overlapping(container.children(overlapping: around)) {
            lower = min(lower, child.range.lowerBound)
            upper = max(upper, child.range.upperBound)
        }
        let heading = container.firstChild(.heading)
        if touchedHeadings || heading.map({ $0.range.overlaps(lineRange) }) == true {
            lower = min(lower, container.range.lowerBound)
            upper = max(upper, container.firstChild(.section)?.range.lowerBound ?? container.range.upperBound)
        }
        return lower..<min(upper, text.length)
    }
}
#endif
