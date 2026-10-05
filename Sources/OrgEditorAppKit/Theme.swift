#if os(macOS)
import AppKit
import OrgPresentation

/// Attributes for each style role, from a `ThemeSpec`.
@MainActor
struct Theme {
    let spec: ThemeSpec
    let font: NSFont

    init(_ spec: ThemeSpec = .default) {
        self.spec = spec
        let size = CGFloat(max(6, spec.fontSize))
        font = spec.font.isEmpty ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            : NSFontManager.shared.font(withFamily: spec.font, traits: [], weight: 5, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        Self.blockBackground = color("block-background") ?? .clear
    }

    /// A color that follows the appearance, or nil when the theme has none for `key`.
    func color(_ key: String) -> NSColor? {
        // Editor colors are set for both appearances by the default theme; a key the theme
        // has for one only takes the default for the other.
        let light = spec.light[key] ?? ThemeSpec.default.light[key] ?? spec.dark[key]
        let dark = spec.dark[key] ?? ThemeSpec.default.dark[key] ?? spec.light[key]
        guard let light, let dark else { return nil }
        return Self.dynamic(light, dark)
    }

    /// One color object per pair, so equal styling compares equal.
    private static var colors: [[RGBA]: NSColor] = [:]

    static func dynamic(_ light: RGBA, _ dark: RGBA) -> NSColor {
        if let cached = colors[[light, dark]] { return cached }
        let color = NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        }
        colors[[light, dark]] = color
        return color
    }

    var foreground: NSColor { color("foreground") ?? .textColor }

    var base: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: foreground, .paragraphStyle: paragraphStyle(firstLine: 0, wrapped: 0)]
    }

    /// Width of one column of the monospaced font.
    var column: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    /// The band behind blocks, read by layout fragments off the main actor.
    nonisolated(unsafe) static var blockBackground = NSColor.clear

    /// Markup hidden from view: no width, no color.
    var hidden: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: 0.01, weight: .regular), .foregroundColor: NSColor.clear]
    }

    func paragraphStyle(firstLine: Int, wrapped: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = CGFloat(firstLine) * column
        style.headIndent = CGFloat(wrapped) * column
        style.lineSpacing = CGFloat(max(0, spec.lineSpacing))
        return style
    }

    func apply(_ role: StyleRole, to storage: NSTextStorage, range: NSRange) {
        func fg(_ key: String) {
            if let color = color(key) { storage.addAttribute(.foregroundColor, value: color, range: range) }
        }
        switch role {
        case .heading(let level):
            let size = font.pointSize + CGFloat(max(0, spec.headingSizeStep) * max(0, 4 - level))
            let heading = NSFontManager.shared.convert(font.withSize(size), toHaveTrait: .boldFontMask)
            storage.addAttribute(.font, value: heading, range: range)
            fg("heading-\(min(max(level, 1), 8))")
        case .leadingStars:
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        case .todo, .done:
            let keyword = (storage.string as NSString).substring(with: range)
            storage.addAttribute(.font, value: bold(storage, range), range: range)
            if let custom = spec.todo[keyword] {
                storage.addAttribute(.foregroundColor, value: Self.dynamic(custom, custom), range: range)
            } else {
                fg(role == .todo ? "todo" : "done")
            }
        case .priority: fg("priority")
        case .tags: fg("tags")
        case .comment: fg("comment")
        case .keyword: fg("keyword")
        case .metadata: fg("metadata")
        case .bold:
            storage.addAttribute(.font, value: bold(storage, range), range: range)
        case .italic:
            storage.addAttribute(.font, value: NSFontManager.shared.convert(currentFont(storage, range), toHaveTrait: .italicFontMask), range: range)
        case .underline:
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .strikeThrough:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .verbatim, .code, .inlineSource:
            if let background = color("inline-background") { storage.addAttribute(.backgroundColor, value: background, range: range) }
            fg(role == .verbatim ? "verbatim" : "code")
        case .markup, .linkMarkup: fg("markup")
        case .blockDelimiter: fg("block-delimiter")
        case .link:
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            fg("link")
        case .timestamp: fg("timestamp")
        case .footnote, .cookie, .target, .macro, .latex: fg("special")
        case .table, .rule: fg("table")
        case .block:
            break
        case .syntax(let category):
            if let key = Self.slot(category) { fg(key) }
        }
    }

    static func slot(_ category: SyntaxCategory) -> String? {
        switch category {
        case .keyword: "syntax-keyword"
        case .string: "syntax-string"
        case .comment: "syntax-comment"
        case .function: "syntax-function"
        case .type: "syntax-type"
        case .number, .constant, .escape: "syntax-number"
        case .property, .attribute, .tag: "syntax-property"
        case .label: "syntax-label"
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
