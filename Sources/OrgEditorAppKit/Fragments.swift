#if os(macOS)
import AppKit
import OrgPresentation

/// A line of a block, on a band across the whole width of the view, as Emacs extends the
/// `org-block` face.
final class ShadedFragment: NSTextLayoutFragment, @unchecked Sendable {
    private var band: CGRect {
        let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        // Not under the empty line TextKit adds after a final newline.
        let height = textLineFragments.last { $0.characterRange.length > 0 }?.typographicBounds.maxY ?? layoutFragmentFrame.height
        return CGRect(x: -layoutFragmentFrame.minX, y: 0, width: width, height: height)
    }

    override var renderingSurfaceBounds: CGRect { super.renderingSurfaceBounds.union(band) }

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.setFillColor(Theme.blockBackground.cgColor)
        context.fill(band.offsetBy(dx: point.x, dy: point.y))
        // The band covers the view's selection highlight, so the selected text is drawn on it,
        // in the color the view uses: the theme's when focused, the system's muted one when not.
        if let manager = textLayoutManager {
            let active = Theme.focusedLayouts.contains(ObjectIdentifier(manager))
            context.setFillColor((active ? Theme.selection : NSColor.unemphasizedSelectedTextBackgroundColor).cgColor)
            let single = textLineFragments.count == 1
            for selection in manager.textSelections {
                for range in selection.textRanges where !range.isEmpty {
                    guard let part = range.intersection(rangeInElement), !part.isEmpty else { continue }
                    manager.enumerateTextSegments(in: part, type: .selection, options: [.rangeNotRequired]) { _, frame, _, _ in
                        var rect = frame.offsetBy(dx: point.x - self.layoutFragmentFrame.minX, dy: point.y - self.layoutFragmentFrame.minY)
                        // A one-line fragment's selection covers its band, leaving no gap to the next line.
                        if single { rect = CGRect(x: rect.minX, y: point.y, width: rect.width, height: self.band.height) }
                        context.fill(rect)
                        return true
                    }
                }
            }
        }
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}

extension NSAttributedString.Key {
    /// The character an entity shows as, on the entity's last character.
    static let orgEntityDisplay = NSAttributedString.Key("OrgEntityDisplay")
    /// The image an image link's line shows under it.
    static let orgImage = NSAttributedString.Key("OrgImage")
    /// A LaTeX fragment's typeset math, on its first character.
    static let orgLatex = NSAttributedString.Key("OrgLatex")
}

final class LatexBox: NSObject, @unchecked Sendable {
    let rendering: LatexPreview.Rendering
    /// An environment's image sits at the start of its first line, under the line's top.
    let environment: Bool
    init(_ rendering: LatexPreview.Rendering, environment: Bool) {
        self.rendering = rendering
        self.environment = environment
    }
}

/// A paragraph with LaTeX previews: each drawn where its hidden fragment starts, on the line's
/// baseline, or at the top of an environment's first line.
final class LatexFragment: NSTextLayoutFragment, @unchecked Sendable {
    static func hasLatex(_ string: NSAttributedString) -> Bool {
        var found = false
        string.enumerateAttribute(.orgLatex, in: NSRange(location: 0, length: string.length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    /// Each preview and where it goes, in the fragment's coordinates.
    private var boxes: [(box: LatexBox, frame: CGRect)] {
        guard let string = (textElement as? NSTextParagraph)?.attributedString else { return [] }
        var out: [(LatexBox, CGRect)] = []
        string.enumerateAttribute(.orgLatex, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            guard let box = value as? LatexBox,
                  let line = textLineFragments.first(where: { NSLocationInRange(range.location, $0.characterRange) }) else { return }
            let bounds = line.typographicBounds
            let size = box.rendering.size
            if box.environment {
                out.append((box, CGRect(x: bounds.minX + line.locationForCharacter(at: range.location).x, y: bounds.minY + 2, width: size.width, height: size.height)))
            } else {
                let baseline = bounds.minY + line.glyphOrigin.y
                let top = max(bounds.minY, baseline - (size.height - box.rendering.descent))
                out.append((box, CGRect(x: bounds.minX + line.locationForCharacter(at: range.location).x, y: top, width: size.width, height: size.height)))
            }
        }
        return out
    }

    override var renderingSurfaceBounds: CGRect {
        boxes.reduce(super.renderingSurfaceBounds) { $0.union($1.frame) }
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        EntityFragment.drawEntities(of: self, at: point, in: context)
        for (box, frame) in boxes {
            let rect = frame.offsetBy(dx: point.x, dy: point.y)
            context.saveGState()
            // The context is flipped; the image is drawn upright.
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(box.rendering.image, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
    }
}

final class InlineImageBox: NSObject, @unchecked Sendable {
    let image: NSImage
    let size: CGSize
    init(image: NSImage, size: CGSize) {
        self.image = image
        self.size = size
    }
}

/// An image link's line drawn as the image, with the paragraph spacing making room for its
/// height.
final class ImageFragment: NSTextLayoutFragment, @unchecked Sendable {
    static func image(_ string: NSAttributedString) -> InlineImageBox? {
        var found: InlineImageBox?
        string.enumerateAttribute(.orgImage, in: NSRange(location: 0, length: string.length)) { value, _, stop in
            if let box = value as? InlineImageBox { found = box; stop.pointee = true }
        }
        return found
    }

    private var frame: CGRect? {
        guard let box = (textElement as? NSTextParagraph).flatMap({ Self.image($0.attributedString) }), let line = textLineFragments.first else { return nil }
        return CGRect(x: line.typographicBounds.minX, y: line.typographicBounds.minY + 2, width: box.size.width, height: box.size.height)
    }

    override var renderingSurfaceBounds: CGRect {
        frame.map { super.renderingSurfaceBounds.union($0) } ?? super.renderingSurfaceBounds
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let box = (textElement as? NSTextParagraph).flatMap({ Self.image($0.attributedString) }), let frame else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        box.image.draw(in: frame.offsetBy(dx: point.x, dy: point.y), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A paragraph with pretty entities: each is drawn as its character where the entity's last
/// (now invisible) character sits, so it takes one column as in Emacs.
final class EntityFragment: NSTextLayoutFragment, @unchecked Sendable {
    static func hasEntities(_ string: NSAttributedString) -> Bool {
        var found = false
        string.enumerateAttribute(.orgEntityDisplay, in: NSRange(location: 0, length: string.length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        Self.drawEntities(of: self, at: point, in: context)
    }

    static func drawEntities(of fragment: NSTextLayoutFragment, at point: CGPoint, in context: CGContext) {
        guard let string = (fragment.textElement as? NSTextParagraph)?.attributedString else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        string.enumerateAttribute(.orgEntityDisplay, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            guard let display = value as? String,
                  let line = fragment.textLineFragments.first(where: { NSLocationInRange(range.location, $0.characterRange) }) else { return }
            var attributes = string.attributes(at: range.location, effectiveRange: nil)
            attributes[.foregroundColor] = NSColor.textColor
            attributes[.orgEntityDisplay] = nil
            let x = line.locationForCharacter(at: range.location).x
            let bounds = line.typographicBounds
            NSAttributedString(string: display, attributes: attributes).draw(at: CGPoint(x: point.x + bounds.minX + x, y: point.y + bounds.minY))
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A heading line drawn with an ellipsis after it, like org's folded headings.
final class FoldedHeadingFragment: NSTextLayoutFragment, @unchecked Sendable {
    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        EntityFragment.drawEntities(of: self, at: point, in: context)
        guard let line = textLineFragments.first else { return }
        let bounds = line.typographicBounds
        let ellipsis = NSAttributedString(string: " …", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        ellipsis.draw(at: CGPoint(x: point.x + bounds.maxX, y: point.y + bounds.minY))
        NSGraphicsContext.restoreGraphicsState()
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.insetBy(dx: -40, dy: 0).offsetBy(dx: 40, dy: 0)
    }
}
#endif
