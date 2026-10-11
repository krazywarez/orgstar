#if os(macOS)
import AppKit
import OrgCore
import OrgPresentation

extension OrgEditor {
    // MARK: - LaTeX previews

    /// `org-latex-preview` over the whole buffer: fragments and environments show as typeset
    /// math, except on the caret's line.
    func toggleLatex() {
        showsLatex.toggle()
        refreshImages()
        if showsLatex {
            let count = LatexPreview.fragments(document.tree, in: 0..<utf16Length).count
            onMessage?("\(count) LaTeX \(count == 1 ? "fragment" : "fragments") previewed")
        } else {
            onMessage?("LaTeX previews removed")
        }
    }

    /// Each fragment's text hidden, as wide as its image, which `LatexFragment` draws; an
    /// environment's image covers its lines.
    func applyLatex(_ range: Range<Int>, in storage: NSTextStorage, revealed: NSRange) {
        guard showsLatex, isOrg else { return }
        let text = storage.string as NSString
        let scale = textView.window?.backingScaleFactor ?? 2
        let lineHeight = theme.font.ascender - theme.font.descender + theme.font.leading
        // The image is drawn in the appearance's color of the moment.
        var color = theme.foreground
        textView.effectiveAppearance.performAsCurrentDrawingAppearance { color = theme.foreground.usingColorSpace(.sRGB) ?? .textColor }
        for fragment in LatexPreview.fragments(document.tree, in: range) {
            let r = NSRange(fragment.range)
            guard r.length > 0, NSMaxRange(r) <= text.length, shaded.containing(r.location) == nil else { continue }
            let lines = text.lineRange(for: r)
            if NSLocationInRange(revealed.location, lines) || NSIntersectionRange(lines, revealed).length > 0 { continue }
            guard let rendering = LatexPreview.render(fragment.latex, display: fragment.display, fontSize: theme.font.pointSize,
                                                      color: color, scale: scale) else { continue }
            // Pretty entities in the source would draw over the image.
            storage.removeAttribute(.orgEntityDisplay, range: r)
            storage.addAttribute(.orgLatex, value: LatexBox(rendering, environment: fragment.environment), range: NSRange(location: r.location, length: 1))
            if fragment.environment {
                // The lines keep their height, under the image; a taller image makes room after them.
                storage.addAttributes([.foregroundColor: NSColor.clear, .underlineStyle: 0], range: r)
                let last = text.lineRange(for: NSRange(location: NSMaxRange(r) - 1, length: 0))
                let count = text.substring(with: lines).components(separatedBy: "\n").count - (text.substring(with: lines).hasSuffix("\n") ? 1 : 0)
                let style = (storage.attribute(.paragraphStyle, at: last.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                style.paragraphSpacing = max(style.paragraphSpacing, rendering.size.height + 4 - CGFloat(count) * (lineHeight + style.lineSpacing))
                storage.addAttribute(.paragraphStyle, value: style, range: last)
            } else {
                storage.addAttributes(theme.hidden, range: r)
                let hiddenWidth = text.substring(with: r).size(withAttributes: [.font: theme.hidden[.font] as! NSFont]).width
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
