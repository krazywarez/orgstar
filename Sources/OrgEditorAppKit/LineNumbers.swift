#if os(macOS)
import AppKit

/// Line numbers in a margin left of the text, as `display-line-numbers-mode` shows them: one
/// per line of the file (folded lines skipped, wrapped lines numbered once), the caret's line
/// bright. Drawn by the text view itself: an `NSRulerView` stops TextKit 2 from drawing text.
extension OrgTextView {
    static let lineNumberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    /// Width of the margin for the largest line number, or 0 when numbers are off.
    func updateGutter() {
        var width: CGFloat = 0
        if showsLineNumbers {
            let lines = (string as NSString).components(separatedBy: "\n").count
            let digits = max(2, String(lines).count)
            width = ceil(("0" as NSString).size(withAttributes: [.font: Self.lineNumberFont]).width * CGFloat(digits) + 16)
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
        let caretLine = text.lineRange(for: NSRange(location: min(selectedRange().location, text.length), length: 0)).location
        let origin = textContainerOrigin
        let documentStart = content.documentRange.location
        guard let start = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, rect.minY - origin.y)))?.rangeInElement.location
            ?? layout.textViewportLayoutController.viewportRange?.location else { return }

        var counted = 0
        var line = 1
        layout.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + origin.y > rect.maxY { return false }
            let offset = content.offset(from: documentStart, to: fragment.rangeInElement.location)
            guard offset <= text.length else { return false }
            while counted < offset {
                if text.character(at: counted) == 10 { line += 1 }
                counted += 1
            }
            let label = NSAttributedString(string: "\(line)", attributes: [
                .font: Self.lineNumberFont,
                .foregroundColor: offset == caretLine ? NSColor.labelColor : NSColor.tertiaryLabelColor,
            ])
            let lineHeight = fragment.textLineFragments.first?.typographicBounds.height ?? frame.height
            let size = label.size()
            label.draw(at: NSPoint(x: gutter - size.width - 8, y: frame.minY + origin.y + (lineHeight - size.height) / 2))
            return true
        }
    }
}
#endif
