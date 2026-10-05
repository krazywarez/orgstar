import AppKit
import OrgPresentation
import SwiftUI

extension EnvironmentValues {
    /// The theme's colors, for the views around the editor.
    @Entry var orgTheme: ThemeSpec = .default
}

extension ThemeSpec {
    /// A color that follows the appearance, or nil when the theme leaves `key` to the system.
    func color(_ key: String) -> Color? {
        guard let light = self.light[key] ?? self.dark[key], let dark = self.dark[key] ?? self.light[key] else { return nil }
        return Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        })
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
