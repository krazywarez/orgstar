#if os(macOS)
import AppKit
import OrgPresentation

/// Attributes for each style role, from a `ThemeSpec`.
@MainActor
struct Theme {
    let spec: ThemeSpec
    /// The fixed-pitch font: columns, tables, code and the rest of `Presentation.isFixedPitch`.
    let font: NSFont
    /// The font for prose; `font` unless the theme names a body font.
    let body: NSFont

    init(_ spec: ThemeSpec = .default) {
        self.spec = spec
        let size = CGFloat(max(6, spec.fontSize))
        font = spec.font.isEmpty ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            : NSFontManager.shared.font(withFamily: spec.font, traits: [], weight: 5, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        body = switch spec.bodyFont {
        case "": font
        case "system": NSFont.systemFont(ofSize: size)
        case let family: NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) ?? font
        }
        Self.blockBackground = color("block-background") ?? .clear
    }

    /// Prose and fixed-pitch text use different fonts.
    var mixedPitch: Bool { body != font }

    /// The fixed-pitch font at the size and weight the text in `range` has.
    func fixedPitch(_ storage: NSTextStorage, _ range: NSRange) -> NSFont {
        let current = currentFont(storage, range)
        let sized = font.withSize(current.pointSize)
        return current.fontDescriptor.symbolicTraits.contains(.bold) ? NSFontManager.shared.convert(sized, toHaveTrait: .boldFontMask) : sized
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
        [.font: body, .foregroundColor: foreground, .paragraphStyle: paragraphStyle(firstLine: 0, wrapped: 0)]
    }

    /// Width of one column of the monospaced font.
    var column: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    /// The band behind blocks, read by layout fragments off the main actor.
    nonisolated(unsafe) static var blockBackground = NSColor.clear
    /// The selection's color, which shaded block lines draw over their band.
    nonisolated(unsafe) static var selection = NSColor.selectedTextBackgroundColor
    /// Layout managers whose view has focus in the key window, for the selection's color.
    nonisolated(unsafe) static var focusedLayouts: Set<ObjectIdentifier> = []

    /// Markup hidden from view: no width, no color.
    var hidden: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: 0.01, weight: .regular), .foregroundColor: NSColor.clear]
    }

    func paragraphStyle(firstLine: Int, wrapped: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = CGFloat(firstLine) * column
        style.headIndent = CGFloat(wrapped) * column
        style.lineSpacing = CGFloat(max(0, spec.lineSpacing))
        // `tab-width` 8, counted from the line's own start, past org-indent's indentation.
        style.defaultTabInterval = 8 * column
        style.tabStops = (1...32).map { NSTextTab(textAlignment: .left, location: style.firstLineHeadIndent + CGFloat($0 * 8) * column) }
        return style
    }

    func apply(_ role: StyleRole, to storage: NSTextStorage, range: NSRange) {
        func fg(_ key: String) {
            if let color = color(key) { storage.addAttribute(.foregroundColor, value: color, range: range) }
        }
        if mixedPitch, Presentation.isFixedPitch(role) {
            storage.addAttribute(.font, value: fixedPitch(storage, range), range: range)
        }
        switch role {
        case .heading(let level):
            let size = body.pointSize + CGFloat(max(0, spec.headingSizeStep) * max(0, 4 - level))
            let heading = NSFontManager.shared.convert(body.withSize(size), toHaveTrait: .boldFontMask)
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
                fg(ThemeSpec.TodoClass.of(keyword, isDone: role == .done).key)
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
            if let key = category.themeKey { fg(key) }
        }
    }

    private func currentFont(_ storage: NSTextStorage, _ range: NSRange) -> NSFont {
        storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? body
    }

    private func bold(_ storage: NSTextStorage, _ range: NSRange) -> NSFont {
        NSFontManager.shared.convert(currentFont(storage, range), toHaveTrait: .boldFontMask)
    }
}
#endif
