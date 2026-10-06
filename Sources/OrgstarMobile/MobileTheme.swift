#if os(iOS)
import OrgPresentation
import UIKit

/// Attributes for each style role, from a `ThemeSpec`, as the Mac editor's theme sets them.
@MainActor
struct MobileTheme {
    let spec: ThemeSpec
    let font: UIFont

    init(_ spec: ThemeSpec = .default) {
        self.spec = spec
        // Dynamic Type, monospaced as on the Mac.
        font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular))
    }

    /// A color that follows the appearance, or nil when the theme has none for `key`.
    func color(_ key: String) -> UIColor? {
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

    var base: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = CGFloat(max(0, spec.lineSpacing))
        return [.font: font, .foregroundColor: color("foreground") ?? .label, .paragraphStyle: style]
    }

    func apply(_ role: StyleRole, to storage: NSTextStorage, range: NSRange) {
        func fg(_ key: String) {
            if let color = color(key) { storage.addAttribute(.foregroundColor, value: color, range: range) }
        }
        func traits(_ add: UIFontDescriptor.SymbolicTraits) {
            let current = storage.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont ?? font
            if let descriptor = current.fontDescriptor.withSymbolicTraits(current.fontDescriptor.symbolicTraits.union(add)) {
                storage.addAttribute(.font, value: UIFont(descriptor: descriptor, size: current.pointSize), range: range)
            }
        }
        switch role {
        case .heading(let level):
            let size = font.pointSize + CGFloat(max(0, spec.headingSizeStep) * max(0, 4 - level))
            storage.addAttribute(.font, value: font.withSize(size), range: range)
            traits(.traitBold)
            fg("heading-\(min(max(level, 1), 8))")
        case .leadingStars: fg("markup")
        case .todo, .done:
            traits(.traitBold)
            let keyword = (storage.string as NSString).substring(with: range)
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
        case .syntax: break
        }
    }
}
#endif
