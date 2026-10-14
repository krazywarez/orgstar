#if os(iOS)
import OrgPresentation
import SwiftUI
import UIKit

/// Attributes for each style role, from a `ThemeSpec`, as the Mac editor's theme sets them.
@MainActor
struct MobileTheme {
    let spec: ThemeSpec
    /// The fixed-pitch font: columns, tables, code and the rest of `Presentation.isFixedPitch`.
    let font: UIFont
    /// The font for prose; `font` unless the theme names a body font.
    let body: UIFont

    init(_ spec: ThemeSpec = .default) {
        self.spec = spec
        let size = CGFloat(max(6, spec.fontSize))
        // The theme's family when the device has it, else the monospaced system font; at the
        // theme's size for the default Dynamic Type size, scaled for others.
        let chosen = spec.font.isEmpty || UIFont.fontNames(forFamilyName: spec.font).isEmpty ? nil
            : UIFont(descriptor: UIFontDescriptor(fontAttributes: [.family: spec.font]), size: size)
        let metrics = UIFontMetrics(forTextStyle: .body)
        font = metrics.scaledFont(for: chosen ?? .monospacedSystemFont(ofSize: size, weight: .regular))
        body = switch spec.bodyFont {
        case "": font
        case "system": metrics.scaledFont(for: .systemFont(ofSize: size))
        case let family where !UIFont.fontNames(forFamilyName: family).isEmpty:
            metrics.scaledFont(for: UIFont(descriptor: UIFontDescriptor(fontAttributes: [.family: family]), size: size))
        default: font
        }
    }

    /// Prose and fixed-pitch text use different fonts.
    var mixedPitch: Bool { body != font }

    /// The fixed-pitch font at the size and weight of `current`.
    func fixedPitch(_ current: UIFont) -> UIFont {
        let sized = font.withSize(current.pointSize)
        return current.fontDescriptor.symbolicTraits.contains(.traitBold) ? Self.adding(.traitBold, to: sized) : sized
    }

    /// A color that follows the appearance, or nil when the theme has none for `key`.
    func color(_ key: String) -> UIColor? {
        // As on the Mac: a key the theme has for one appearance only takes the default for the other.
        let light = spec.light[key] ?? ThemeSpec.default.light[key] ?? spec.dark[key]
        let dark = spec.dark[key] ?? ThemeSpec.default.dark[key] ?? spec.light[key]
        guard let light, let dark else { return nil }
        return Self.dynamic(light, dark)
    }

    static func dynamic(_ light: RGBA, _ dark: RGBA) -> UIColor {
        UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        }
    }

    var foreground: UIColor { color("foreground") ?? .label }

    /// A TODO keyword's color: its own from `[theme.todo]`, else its class's (`todo-next`,
    /// `todo-waiting`, `todo-cancelled`, `todo`, `done`).
    func keywordColor(_ keyword: String, done: Bool) -> UIColor? {
        if let custom = spec.todo[keyword] { return Self.dynamic(custom, custom) }
        return color(ThemeSpec.TodoClass.of(keyword, isDone: done).key)
    }

    /// A heading's font: larger by the heading step for levels 1 to 3, bold.
    func headingFont(_ level: Int) -> UIFont {
        let size = body.pointSize + CGFloat(max(0, spec.headingSizeStep) * max(0, 4 - level))
        return Self.adding(.traitBold, to: body.withSize(size))
    }

    static func adding(_ traits: UIFontDescriptor.SymbolicTraits, to font: UIFont) -> UIFont {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits)) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    var base: [NSAttributedString.Key: Any] {
        [.font: body, .foregroundColor: foreground, .paragraphStyle: paragraphStyle(firstLine: 0, wrapped: 0)]
    }

    /// Markup hidden from view: no width, no color.
    var hidden: [NSAttributedString.Key: Any] {
        [.font: UIFont.monospacedSystemFont(ofSize: 0.01, weight: .regular), .foregroundColor: UIColor.clear]
    }

    /// Width of one column of the font.
    var column: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: font]).width
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
        func traits(_ add: UIFontDescriptor.SymbolicTraits) {
            let current = storage.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont ?? body
            storage.addAttribute(.font, value: Self.adding(add, to: current), range: range)
        }
        if mixedPitch, Presentation.isFixedPitch(role) {
            let current = storage.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont ?? body
            storage.addAttribute(.font, value: fixedPitch(current), range: range)
        }
        switch role {
        case .heading(let level):
            storage.addAttribute(.font, value: headingFont(level), range: range)
            fg("heading-\(min(max(level, 1), 8))")
        case .leadingStars:
            storage.addAttribute(.foregroundColor, value: UIColor.clear, range: range)
        case .todo, .done:
            traits(.traitBold)
            let keyword = (storage.string as NSString).substring(with: range)
            if let color = keywordColor(keyword, done: role == .done) { storage.addAttribute(.foregroundColor, value: color, range: range) }
        case .priority: fg("priority")
        case .tags: fg("tags")
        case .comment: fg("comment")
        case .keyword: fg("keyword")
        case .metadata: fg("metadata")
        case .bold: traits(.traitBold)
        case .italic: traits(.traitItalic)
        case .underline: storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .strikeThrough: storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
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
        case .block: break
        case .syntax(let category):
            if let key = category.themeKey { fg(key) }
        }
    }

    // MARK: - SwiftUI

    /// A theme color for SwiftUI views.
    func swiftColor(_ key: String) -> Color? { color(key).map { Color(uiColor: $0) } }
}
extension ThemeSpec {
    /// `accent` for `.tint`, the system's blue in an appearance the theme leaves it unset; nil
    /// when neither appearance sets it.
    var accentColor: Color? {
        let (light, dark) = (light["accent"], dark["accent"])
        guard light != nil || dark != nil else { return nil }
        return Color(uiColor: UIColor { traits in
            guard let c = traits.userInterfaceStyle == .dark ? dark : light else { return .systemBlue }
            return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        })
    }
}
#endif
