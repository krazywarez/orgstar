#if os(iOS)
import OrgApp
import OrgCore
import OrgDocument
import OrgHighlight
import OrgPresentation
import UIKit

/// Ranges read by TextKit's delegate callbacks.
final class LockedRanges: @unchecked Sendable {
    private let lock = NSLock()
    private var ranges: [Range<Int>] = []
    private var starts: Set<Int> = []

    func set(_ new: [Range<Int>], folded: Set<Int>) { lock.withLock { ranges = new; starts = folded } }
    var all: [Range<Int>] { lock.withLock { ranges } }
    func covers(_ start: Int, _ end: Int) -> Bool { lock.withLock { ranges.contains { $0.lowerBound <= start && end <= $0.upperBound } } }
    func isFolded(_ start: Int) -> Bool { lock.withLock { starts.contains(start) } }
    var folded: Set<Int> { lock.withLock { starts } }
    func containing(_ offset: Int) -> Range<Int>? { lock.withLock { ranges.first { $0.contains(offset) } } }
}

/// What layout fragments draw beyond the text, read by TextKit's delegate callbacks.
final class FragmentStyle: @unchecked Sendable {
    private let lock = NSLock()
    private var band: (color: UIColor, width: CGFloat) = (.clear, 0)
    private var selected: (range: Range<Int>, color: UIColor)?

    func set(blockBackground color: UIColor, width: CGFloat) { lock.withLock { band = (color, width) } }
    var blockBand: (color: UIColor, width: CGFloat) { lock.withLock { band } }
    /// The selection, which a block's fragment draws over its band, as the Mac's fragments do.
    func set(selection range: Range<Int>?, color: UIColor) { lock.withLock { selected = range.map { ($0, color) } } }
    var selection: (range: Range<Int>, color: UIColor)? { lock.withLock { selected } }
}

/// A text view that offers hardware-keyboard presses to the editor's keymap first.
final class KeyedTextView: UITextView {
    var keyHandler: ((UIKey) -> Bool)?
    /// Keys the editor took, whose release the text system doesn't see. Optional: made by
    /// UIKit's `init(usingTextLayoutManager:)`, the view skips Swift's default values.
    private var handled: Set<UIKeyboardHIDUsage>?
    /// Called after each layout pass, as the view's size settles.
    var onLayout: (() -> Void)?
    /// The text container's width while lines are truncated.
    static let truncatedWidth: CGFloat = 100_000

    /// Long lines run off the right edge and the view scrolls sideways.
    var truncates: Bool {
        get { !textContainer.widthTracksTextView }
        set {
            textContainer.widthTracksTextView = !newValue
            if newValue {
                textContainer.size = CGSize(width: Self.truncatedWidth, height: CGFloat.greatestFiniteMagnitude)
            } else {
                textContainer.size = CGSize(width: bounds.width - textContainerInset.left - textContainerInset.right, height: CGFloat.greatestFiniteMagnitude)
                contentOffset.x = 0
            }
            showsHorizontalScrollIndicator = newValue
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        // The text view sets its container's width to its own when it lays out.
        if truncates, textContainer.size.width != Self.truncatedWidth {
            textContainer.size = CGSize(width: Self.truncatedWidth, height: CGFloat.greatestFiniteMagnitude)
        }
        super.layoutSubviews()
        // The text view sizes its content to its own width; truncated lines need the widest
        // laid-out line's.
        if truncates, let manager = textLayoutManager {
            let width = ceil(manager.usageBoundsForTextContainer.maxX + textContainerInset.left + textContainerInset.right)
            if contentSize.width < width { contentSize.width = width }
        }
        onLayout?()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest: Set<UIPress> = []
        for press in presses {
            if let key = press.key, keyHandler?(key) == true {
                handled = (handled ?? []).union([key.keyCode])
            } else {
                rest.insert(press)
            }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.filter { press in
            guard let code = press.key?.keyCode, handled?.contains(code) == true else { return true }
            handled?.remove(code)
            return false
        }
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }
}

extension NSAttributedString.Key {
    /// The character an entity shows as, on the entity's last character.
    static let orgEntityDisplay = NSAttributedString.Key("OrgEntityDisplay")
    /// The color the entity's character is drawn in.
    static let orgEntityColor = NSAttributedString.Key("OrgEntityColor")
    /// The image an image link's line shows under it.
    static let orgImage = NSAttributedString.Key("OrgImage")
}

final class InlineImageBox: NSObject, @unchecked Sendable {
    let image: UIImage
    let size: CGSize
    init(image: UIImage, size: CGSize) {
        self.image = image
        self.size = size
    }
}

/// Selected text's background, in one color however the rects overlap.
final class SelectionHighlightView: UIView, UITextSelectionHighlightView {
    var selectionRects: [UITextSelectionRect] = [] { didSet { setNeedsDisplay() } }
    var color: UIColor = .clear { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SelectionHighlightView, _) in view.setNeedsDisplay() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        let path = UIBezierPath()
        for selection in selectionRects where !selection.rect.isEmpty { path.append(UIBezierPath(rect: selection.rect)) }
        color.setFill()
        path.fill()
    }
}

/// A line drawn with more than its text, as the Mac editor's fragments draw them: a folded
/// line's ellipsis, a block's band across the view, an image under an image link, and pretty
/// entities' characters where the entities' last (invisible) characters sit.
final class OrgLineFragment: NSTextLayoutFragment, @unchecked Sendable {
    var folded = false
    var band: (color: UIColor, width: CGFloat)?
    var image: InlineImageBox?
    /// For a block's lines: where the fragment starts, and where the selection is read.
    var start = 0
    var style: FragmentStyle?

    static func image(_ string: NSAttributedString) -> InlineImageBox? {
        var found: InlineImageBox?
        string.enumerateAttribute(.orgImage, in: NSRange(location: 0, length: string.length)) { value, _, stop in
            if let box = value as? InlineImageBox { found = box; stop.pointee = true }
        }
        return found
    }

    static func hasEntities(_ string: NSAttributedString) -> Bool {
        var found = false
        string.enumerateAttribute(.orgEntityDisplay, in: NSRange(location: 0, length: string.length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    var bandRect: CGRect? {
        guard let band else { return nil }
        // Not under the empty line TextKit adds after a final newline.
        let height = textLineFragments.last { $0.characterRange.length > 0 }?.typographicBounds.maxY ?? layoutFragmentFrame.height
        // The width as it is now: the view may have been laid out since this fragment was made.
        let width = style?.blockBand.width ?? band.width
        return CGRect(x: -layoutFragmentFrame.minX, y: 0, width: max(width, layoutFragmentFrame.maxX), height: height)
    }

    private var imageRect: CGRect? {
        guard let image, let line = textLineFragments.first else { return nil }
        return CGRect(x: line.typographicBounds.minX, y: line.typographicBounds.minY + 2, width: image.size.width, height: image.size.height)
    }

    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        if folded { bounds = bounds.insetBy(dx: -40, dy: 0).offsetBy(dx: 40, dy: 0) }
        for rect in [bandRect, imageRect].compactMap({ $0 }) { bounds = bounds.union(rect) }
        return bounds
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if let band, let rect = bandRect {
            context.saveGState()
            context.setFillColor(band.color.cgColor)
            context.fill(rect.offsetBy(dx: point.x, dy: point.y))
            context.restoreGState()
            drawSelection(at: point, in: context, bandRect: rect)
        }
        super.draw(at: point, in: context)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        drawEntities(at: point)
        if let image, let rect = imageRect { image.image.draw(in: rect.offsetBy(dx: point.x, dy: point.y)) }
        if folded, let line = textLineFragments.first(where: { $0.characterRange.length > 0 }) ?? textLineFragments.first {
            let bounds = line.typographicBounds
            let ellipsis = NSAttributedString(string: " …", attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: UIFont.systemFontSize, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel,
            ])
            ellipsis.draw(at: CGPoint(x: point.x + bounds.maxX, y: point.y + bounds.minY))
        }
    }

    /// The selected part of each line, over the band; a selection running past a line's end
    /// fills to the band's edge.
    private func drawSelection(at point: CGPoint, in context: CGContext, bandRect: CGRect) {
        guard let selection = style?.selection else { return }
        context.saveGState()
        context.setFillColor(selection.color.cgColor)
        for line in textLineFragments where line.characterRange.length > 0 {
            let lineStart = start + line.characterRange.location
            let lineEnd = lineStart + line.characterRange.length
            let from = max(selection.range.lowerBound, lineStart), to = min(selection.range.upperBound, lineEnd)
            guard from < to || (from == to && selection.range.upperBound > lineEnd && from == lineEnd) else { continue }
            let bounds = line.typographicBounds
            // From the margin when the selection began on an earlier line, as the system draws it.
            let margin = bandRect.minX + (textLayoutManager?.textContainer?.lineFragmentPadding ?? 0)
            let x1 = selection.range.lowerBound < lineStart ? margin : bounds.minX + line.locationForCharacter(at: from - start).x
            let x2 = selection.range.upperBound >= lineEnd ? bandRect.maxX : bounds.minX + line.locationForCharacter(at: to - start).x
            context.fill(CGRect(x: point.x + x1, y: point.y + bounds.minY, width: max(0, x2 - x1), height: bounds.height))
        }
        context.restoreGState()
    }

    private func drawEntities(at point: CGPoint) {
        guard let string = (textElement as? NSTextParagraph)?.attributedString else { return }
        string.enumerateAttribute(.orgEntityDisplay, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            guard let display = value as? String,
                  let line = textLineFragments.first(where: { NSLocationInRange(range.location, $0.characterRange) }) else { return }
            var attributes = string.attributes(at: range.location, effectiveRange: nil)
            attributes[.foregroundColor] = attributes[.orgEntityColor] ?? UIColor.label
            attributes[.orgEntityDisplay] = nil
            attributes[.orgEntityColor] = nil
            let x = line.locationForCharacter(at: range.location).x
            let bounds = line.typographicBounds
            NSAttributedString(string: display, attributes: attributes).draw(at: CGPoint(x: point.x + bounds.minX + x, y: point.y + bounds.minY))
        }
    }
}
#endif
