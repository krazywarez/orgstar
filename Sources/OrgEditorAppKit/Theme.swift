#if os(macOS)
import AppKit
import OrgPresentation

/// Attributes for each style role. A fixed theme for now; the app's theme settings replace it.
@MainActor
struct Theme {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    var base: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.textColor]
    }

    /// Width of one column of the monospaced font.
    var column: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    func paragraphStyle(firstLine: Int, wrapped: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = CGFloat(firstLine) * column
        style.headIndent = CGFloat(wrapped) * column
        return style
    }

    func apply(_ role: StyleRole, to storage: NSTextStorage, range: NSRange) {
        switch role {
        case .heading(let level):
            let size = font.pointSize + CGFloat(max(0, 4 - level))
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size, weight: .semibold), range: range)
        case .leadingStars:
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        case .todo:
            storage.addAttributes([.foregroundColor: NSColor.systemRed, .font: bold(storage, range)], range: range)
        case .done:
            storage.addAttributes([.foregroundColor: NSColor.systemGreen, .font: bold(storage, range)], range: range)
        case .priority:
            storage.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: range)
        case .tags, .comment, .keyword, .metadata:
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        case .bold:
            storage.addAttribute(.font, value: bold(storage, range), range: range)
        case .italic:
            storage.addAttribute(.font, value: NSFontManager.shared.convert(currentFont(storage, range), toHaveTrait: .italicFontMask), range: range)
        case .underline:
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .strikeThrough:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .verbatim, .code, .inlineSource:
            storage.addAttribute(.backgroundColor, value: NSColor.quaternarySystemFill, range: range)
        case .markup, .linkMarkup, .blockDelimiter:
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        case .link:
            storage.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
        case .timestamp:
            storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: range)
        case .footnote, .cookie, .target, .macro, .latex:
            storage.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: range)
        case .block:
            storage.addAttribute(.backgroundColor, value: NSColor.quaternarySystemFill, range: range)
        case .table, .rule:
            break
        case .syntax(let category):
            if let color = Self.color(category) { storage.addAttribute(.foregroundColor, value: color, range: range) }
        }
    }

    /// Code colors, close to Xcode's default theme.
    static func color(_ category: SyntaxCategory) -> NSColor? {
        switch category {
        case .keyword: .systemPink
        case .string: .systemRed
        case .comment: .secondaryLabelColor
        case .function: .systemBlue
        case .type: .systemTeal
        case .number, .constant, .escape: .systemOrange
        case .property, .attribute, .tag: .systemIndigo
        case .label: .systemPurple
        case .variable, .operator, .punctuation: nil
        }
    }

    private func currentFont(_ storage: NSTextStorage, _ range: NSRange) -> NSFont {
        storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? font
    }

    private func bold(_ storage: NSTextStorage, _ range: NSRange) -> NSFont {
        NSFontManager.shared.convert(currentFont(storage, range), toHaveTrait: .boldFontMask)
    }
}
#endif
