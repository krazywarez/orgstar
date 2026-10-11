#if os(iOS)
import OrgCore
import OrgPresentation
import UIKit

extension MobileEditor {
    // MARK: - LaTeX previews

    /// `org-latex-preview` over the whole buffer: fragments and environments show as typeset
    /// math, except on the caret's line.
    func toggleLatex() {
        showsLatex.toggle()
        restyleAll()
        if showsLatex {
            let count = LatexPreview.fragments(document.tree, in: 0..<textView.textStorage.length).count
            onMessage?("\(count) LaTeX \(count == 1 ? "fragment" : "fragments") previewed")
        } else {
            onMessage?("LaTeX previews removed")
        }
    }

    /// As the Mac editor: each fragment hidden and as wide as its image, which
    /// `OrgLineFragment` draws; an environment's image covers its lines.
    func applyLatex(_ range: Range<Int>, in storage: NSTextStorage, revealed: NSRange) {
        guard showsLatex else { return }
        let text = storage.string as NSString
        let scale = textView.traitCollection.displayScale
        let color = theme.foreground.resolvedColor(with: textView.traitCollection)
        let lineHeight = theme.font.lineHeight
        for fragment in LatexPreview.fragments(document.tree, in: range) {
            let r = NSRange(fragment.range)
            guard r.length > 0, NSMaxRange(r) <= text.length, shaded.containing(r.location) == nil else { continue }
            let lines = text.lineRange(for: r)
            if NSLocationInRange(revealed.location, lines) || NSIntersectionRange(lines, revealed).length > 0 { continue }
            guard let rendering = LatexPreview.render(fragment.latex, display: fragment.display, fontSize: theme.font.pointSize,
                                                      color: color, scale: scale) else { continue }
            // Pretty entities in the source would draw over the image.
            storage.removeAttribute(.orgEntityDisplay, range: r)
            storage.removeAttribute(.orgEntityColor, range: r)
            storage.addAttribute(.orgLatex, value: LatexBox(rendering, environment: fragment.environment), range: NSRange(location: r.location, length: 1))
            if fragment.environment {
                storage.addAttributes([.foregroundColor: UIColor.clear, .underlineStyle: 0], range: r)
                let last = text.lineRange(for: NSRange(location: NSMaxRange(r) - 1, length: 0))
                let body = text.substring(with: lines)
                let count = body.components(separatedBy: "\n").count - (body.hasSuffix("\n") ? 1 : 0)
                let style = (storage.attribute(.paragraphStyle, at: last.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                style.paragraphSpacing = max(style.paragraphSpacing, rendering.size.height + 4 - CGFloat(count) * (lineHeight + style.lineSpacing))
                storage.addAttribute(.paragraphStyle, value: style, range: last)
            } else {
                storage.addAttributes(theme.hidden, range: r)
                let hiddenWidth = text.substring(with: r).size(withAttributes: [.font: theme.hidden[.font] as! UIFont]).width
                storage.addAttribute(.kern, value: max(0, rendering.size.width - hiddenWidth), range: NSRange(location: NSMaxRange(r) - 1, length: 1))
                let line = text.lineRange(for: NSRange(location: r.location, length: 0))
                let style = (storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                style.minimumLineHeight = max(style.minimumLineHeight, lineHeight, rendering.ascent + rendering.descent + 2)
                storage.addAttribute(.paragraphStyle, value: style, range: line)
            }
        }
    }
}
#endif
