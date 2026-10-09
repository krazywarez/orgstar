import AppKit
import OrgPresentation
import SwiftUI

extension EnvironmentValues {
    /// The theme's colors, for the views around the editor.
    @Entry var orgTheme: ThemeSpec = .default
}

extension ThemeSpec {
    /// A color that follows the appearance, or nil when the theme leaves `key` to the system.
    /// A key set for one appearance only leaves the other to the system.
    func color(_ key: String) -> Color? {
        guard light[key] != nil || dark[key] != nil else { return nil }
        let (light, dark) = (light[key], dark[key])
        let fallback = Self.systemColor(key)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            guard let c = isDark ? dark : light else { return fallback }
            return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        })
    }

    /// A color that follows the appearance from a helper taking `dark:` (`todoColor`,
    /// `statusColor`, …), or `fallback` where it gives none.
    func dynamic(_ fallback: NSColor = .labelColor, _ pick: @escaping @Sendable (_ dark: Bool) -> RGBA?) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            guard let c = pick(isDark) else { return fallback }
            return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        })
    }

    /// What the system shows for a key the theme leaves unset in one appearance.
    static func systemColor(_ key: String) -> NSColor {
        switch key {
        case "sidebar-background", "modeline-background": .windowBackgroundColor
        case "agenda-background", "background": .textBackgroundColor
        case "sidebar-header", "modeline-foreground", "agenda-time", "agenda-category", "tags": .secondaryLabelColor
        default: .labelColor
        }
    }

    /// A TODO keyword's color: its own from `[theme.todo]`, else the theme's TODO or DONE.
    func keywordColor(_ keyword: String, done: Bool) -> Color {
        if let c = todo[keyword] { return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha) }
        return color(done ? "done" : "todo") ?? (done ? .green : .red)
    }
}

extension View {
    /// A list's background from the theme, or the system's when the theme has none.
    @ViewBuilder
    func themedListBackground(_ color: Color?) -> some View {
        if let color {
            scrollContentBackground(.hidden).background(color)
        } else {
            self
        }
    }
}
