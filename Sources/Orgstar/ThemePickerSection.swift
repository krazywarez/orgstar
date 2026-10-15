import AppKit
import OrgApp
import OrgPresentation
import SwiftUI

/// Settings ▸ Appearance ▸ Theme: the built-in palette for each appearance.
struct ThemePickerSection: View {
    @AppStorage("themeLight") private var themeLight = "default-light"
    @AppStorage("themeDark") private var themeDark = "default-dark"
    @AppStorage("themeFile") private var themeFile = ""
    @State private var message: String?

    var body: some View {
        Section {
            picker("Light", .light, $themeLight)
            picker("Dark", .dark, $themeDark)
            LabeledContent("Starting point") {
                Button("Copy to Config Folder") { copy() }
            }
        } header: {
            Text("Theme")
        } footer: {
            Text(message ?? footer)
                .settingsFooter()
        }
    }

    private var footer: String {
        themeFile.isEmpty ? String(localized: "Colors set in config.toml or in the theme file apply on top of these.")
            : String(localized: "The theme file \(themeFile) sets colors over these, and config.toml's colors apply on top of both.")
    }

    private func picker(_ title: LocalizedStringKey, _ appearance: Palette.Appearance, _ selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(ThemeSpec.palettes(appearance), id: \.id) { palette in
                Label { Text(palette.displayName) } icon: { Image(nsImage: Self.swatch(palette)) }.tag(palette.id)
            }
            if ThemeSpec.palette(selection.wrappedValue, appearance) == nil {
                Text(selection.wrappedValue).tag(selection.wrappedValue)
            }
        }
    }

    /// Background, text, heading, TODO and accent, side by side.
    static func swatch(_ palette: Palette) -> NSImage {
        let keys = ["background", "foreground", "heading-1", "todo", "accent"]
        return NSImage(size: NSSize(width: 40, height: 12), flipped: false) { rect in
            for (i, key) in keys.enumerated() {
                let c = palette.colors[key] ?? palette.colors["cursor"] ?? RGBA(red: 0.5, green: 0.5, blue: 0.5)
                NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1).setFill()
                NSRect(x: CGFloat(i) * 8, y: 0, width: 8, height: rect.height).fill()
            }
            NSColor.separatorColor.setStroke()
            NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
    }

    private func copy() {
        let light = ThemeSpec.palette(themeLight, .light) ?? ThemeSpec.palettes(.light)[0]
        let dark = ThemeSpec.palette(themeDark, .dark) ?? ThemeSpec.palettes(.dark)[0]
        do {
            guard try UserConfig.copyTheme(light: light, dark: dark, to: UserConfig.directory) else {
                message = String(localized: "my-theme.toml is already in the config folder; it was left as it is.")
                return
            }
            let previous = themeFile
            themeFile = UserConfig.copiedThemeFile
            message = previous.isEmpty || previous == UserConfig.copiedThemeFile
                ? String(localized: "Copied to my-theme.toml, now the theme file.")
                : String(localized: "Copied to my-theme.toml, now the theme file in place of \(previous).")
        } catch {
            message = error.localizedDescription
        }
    }
}
