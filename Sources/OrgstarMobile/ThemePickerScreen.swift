#if os(iOS)
import OrgCore
import OrgPresentation
import SwiftUI

/// The built-in palettes of one appearance, each as a few lines of Org in its colors.
struct ThemePickerScreen: View {
    let model: MobileModel
    let appearance: Palette.Appearance

    var body: some View {
        let _ = model.settingsVersion
        let current = Self.current(appearance).id
        List(ThemeSpec.palettes(appearance), id: \.id) { palette in
            Button {
                model.set(appearance == .light ? "themeLight" : "themeDark", to: .string(palette.id))
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(palette.displayName).foregroundStyle(.primary)
                        Self.sample(palette)
                    }
                    Spacer()
                    if palette.id == current { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
            }
            .buttonStyle(.plain)
        }
        .navigationTitle(appearance == .light ? "Light Theme" : "Dark Theme")
    }

    /// The palette `light-theme` or `dark-theme` names, Default when unknown.
    static func current(_ appearance: Palette.Appearance) -> Palette {
        let id = UserDefaults.standard.string(forKey: appearance == .light ? "themeLight" : "themeDark") ?? ""
        return ThemeSpec.palette(id, appearance) ?? ThemeSpec.palettes(appearance)[0]
    }

    private static func sample(_ palette: Palette) -> some View {
        func color(_ key: String) -> Color {
            guard let c = palette.colors[key] else { return .primary }
            return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
        }
        let font = Font.system(.footnote, design: .monospaced)
        return VStack(alignment: .leading, spacing: 2) {
            (Text(verbatim: "* ").foregroundColor(color("heading-1")) + Text(verbatim: "TODO ").foregroundColor(color("todo")).bold()
                + Text(verbatim: "Plan the trip ").foregroundColor(color("heading-1")).bold() + Text(verbatim: ":travel:").foregroundColor(color("tags")))
            (Text(verbatim: "  SCHEDULED: ").foregroundColor(color("metadata")) + Text(verbatim: "<2026-10-20 Tue>").foregroundColor(color("timestamp")))
            (Text(verbatim: "  Book via ").foregroundColor(color("foreground")) + Text(verbatim: "the site").foregroundColor(color("link")).underline()
                + Text(verbatim: ", ").foregroundColor(color("foreground")) + Text(verbatim: "~code~").foregroundColor(color("code")))
            (Text(verbatim: "** ").foregroundColor(color("heading-2")) + Text(verbatim: "DONE ").foregroundColor(color("done")).bold()
                + Text(verbatim: "Passport").foregroundColor(color("heading-2")).bold())
        }
        .font(font)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color("background"), in: RoundedRectangle(cornerRadius: 8))
    }
}
#endif
