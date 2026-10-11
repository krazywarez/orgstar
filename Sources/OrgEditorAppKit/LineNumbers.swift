#if os(macOS)
import AppKit

/// `display-line-numbers-type`: `t`, `relative` or `visual`.
public enum LineNumbersType: String, Sendable {
    case absolute = "t", relative, visual
}

/// Line numbers in a margin left of the text, as `display-line-numbers-mode` shows them: one
/// per line of the file (folded lines skipped, wrapped lines numbered once), the caret's line
/// bright. Drawn by the text view itself: an `NSRulerView` stops TextKit 2 from drawing text.
extension OrgTextView {
    /// Width of the margin for the largest line number, or 0 when numbers are off.
    func updateGutter() {
        var width: CGFloat = 0
        if showsLineNumbers {
            let lines = lineIndex?.lineCount ?? 1
            let digits = max(2, String(lines).count)
            width = ceil(("0" as NSString).size(withAttributes: [.font: lineNumberFont]).width * CGFloat(digits) + 16)
        }
        if textContainerInset.width != width {
            textContainerInset = NSSize(width: width, height: textContainerInset.height)
            needsDisplay = true
        }
    }

    func drawLineNumbers(in rect: NSRect) {
        guard showsLineNumbers, let layout = textLayoutManager, let content = layout.textContentManager else { return }
        let gutter = textContainerInset.width
        guard rect.minX < gutter else { return }
        let text = string as NSString
        let caret = min(selectedRange().location, text.length)
        let caretLine = text.lineRange(for: NSRange(location: caret, length: 0)).location
        let caretNumber = lineIndex?.line(of: caretLine) ?? 1
        let origin = textContainerOrigin
        let documentStart = content.documentRange.location
        guard let start = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, rect.minY - origin.y)))?.rangeInElement.location
            ?? layout.textViewportLayoutController.viewportRange?.location else { return }

        // The screen lines to number: each paragraph's first, or every one for visual numbers.
        struct Row { var y: CGFloat; var height: CGFloat; var line: Int; var hasCaret: Bool }
        var rows: [Row] = []
        layout.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + origin.y > rect.maxY { return false }
            let offset = content.offset(from: documentStart, to: fragment.rangeInElement.location)
            guard offset <= text.length else { return false }
            let line = lineIndex?.line(of: offset) ?? 1
            let lines = lineNumbersType == .visual ? fragment.textLineFragments : Array(fragment.textLineFragments.prefix(1))
            if lines.isEmpty {
                rows.append(Row(y: frame.minY + origin.y, height: frame.height, line: line, hasCaret: offset == caretLine))
            }
            for (index, lineFragment) in lines.enumerated() {
                let range = lineFragment.characterRange
                let begin = offset + range.location
                let last = index == fragment.textLineFragments.count - 1
                let hasCaret = lineNumbersType == .visual
                    ? caret >= begin && (caret < begin + range.length || (last && caret <= begin + range.length))
                    : offset == caretLine
                rows.append(Row(y: frame.minY + origin.y + lineFragment.typographicBounds.minY, height: lineFragment.typographicBounds.height,
                                line: line, hasCaret: hasCaret))
            }
            return true
        }
        let caretRow = rows.firstIndex { $0.hasCaret }
        for (index, row) in rows.enumerated() {
            let number: Int
            switch lineNumbersType {
            case .absolute: number = row.line
            // The caret's line keeps its own number, as `display-line-numbers-current-absolute` has it.
            case .relative: number = row.hasCaret ? row.line : abs(row.line - caretNumber)
            case .visual:
                if row.hasCaret {
                    number = row.line
                } else if let caretRow {
                    number = abs(index - caretRow)
                } else {
                    number = abs(row.line - caretNumber)
                }
            }
            let label = NSAttributedString(string: "\(number)", attributes: [
                .font: lineNumberFont,
                .foregroundColor: row.hasCaret ? currentLineNumberColor : lineNumberColor,
            ])
            let size = label.size()
            label.draw(at: NSPoint(x: gutter - size.width - 8, y: row.y + (row.height - size.height) / 2))
        }
    }
}
#endif
