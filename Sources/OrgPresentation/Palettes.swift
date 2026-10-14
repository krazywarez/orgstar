/// A built-in theme for one appearance, chosen with `light-theme` or `dark-theme`.
public struct Palette: Sendable, Equatable {
    public enum Appearance: String, Sendable { case light, dark }

    public let id: String
    public let name: String
    public let appearance: Appearance
    public let colors: [String: RGBA]

    public init(id: String, name: String, appearance: Appearance, colors: [String: RGBA]) {
        self.id = id
        self.name = name
        self.appearance = appearance
        self.colors = colors
    }
}

extension ThemeSpec {
    /// The built-in palettes of `appearance`, Default first.
    public static func palettes(_ appearance: Palette.Appearance) -> [Palette] {
        appearance == .light ? lightPalettes : darkPalettes
    }

    public static func palette(_ id: String, _ appearance: Palette.Appearance) -> Palette? {
        palettes(appearance).first { $0.id == id }
    }

    public static func defaultPaletteID(_ appearance: Palette.Appearance) -> String {
        "default-" + appearance.rawValue
    }

    static let lightPalettes: [Palette] = [
        Palette(id: "default-light", name: "Default", appearance: .light, colors: ThemeSpec.default.light),
    ]

    static let darkPalettes: [Palette] = [
        Palette(id: "default-dark", name: "Default", appearance: .dark, colors: ThemeSpec.default.dark),
    ]
}
