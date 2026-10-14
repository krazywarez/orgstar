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

    /// The default theme with each appearance's colors from the palette `light-theme` and
    /// `dark-theme` name; Default where one is unset or unknown, with a problem for unknown.
    public static func base(light: String?, dark: String?) -> (ThemeSpec, [String]) {
        var spec = ThemeSpec.default
        var problems: [String] = []
        for (id, appearance) in [(light, Palette.Appearance.light), (dark, .dark)] {
            guard let id, !id.isEmpty, id != defaultPaletteID(appearance) else { continue }
            guard let palette = palette(id, appearance) else {
                problems.append("config.toml: unknown \(appearance.rawValue)-theme \(id)")
                continue
            }
            if appearance == .light { spec.light = palette.colors } else { spec.dark = palette.colors }
        }
        return (spec, problems)
    }

    // Upstream palettes; see THIRD_PARTY.org. Colors darkened from upstream to read at 3:1 on
    // the background: Solarized Light yellow, green and cyan; Catppuccin Latte orange, yellow
    // and green; Tomorrow orange and yellow.
    static let lightPalettes: [Palette] = [
        Palette(id: "default-light", name: "Default", appearance: .light, colors: ThemeSpec.default.light),
        ported("solarized-light", "Solarized Light", .light, Roles(
            bg: "#fdf6e3", alt: "#eee8d5", fg: "#586e75", dim: "#93a1a1", red: "#dc322f", orange: "#cb4b16", yellow: "#a57c00",
            green: "#738a05", cyan: "#258f86", blue: "#268bd2", purple: "#6c71c4", accent: "#268bd2")),
        ported("gruvbox-light", "Gruvbox Light", .light, Roles(
            bg: "#fbf1c7", alt: "#ebdbb2", fg: "#3c3836", dim: "#928374", red: "#9d0006", orange: "#af3a03", yellow: "#b57614",
            green: "#79740e", cyan: "#427b58", blue: "#076678", purple: "#8f3f71", accent: "#076678")),
        ported("modus-operandi", "Modus Operandi", .light, Roles(
            bg: "#ffffff", alt: "#f2f2f2", fg: "#000000", dim: "#595959", red: "#a60000", orange: "#972500", yellow: "#6f5500",
            green: "#006800", cyan: "#005e8b", blue: "#0031a9", purple: "#721045", accent: "#0031a9")),
        ported("catppuccin-latte", "Catppuccin Latte", .light, Roles(
            bg: "#eff1f5", alt: "#e6e9ef", fg: "#4c4f69", dim: "#8c8fa1", red: "#d20f39", orange: "#d0590a", yellow: "#b06f13",
            green: "#388c24", cyan: "#179299", blue: "#1e66f5", purple: "#8839ef", accent: "#8839ef")),
        ported("tomorrow", "Tomorrow", .light, Roles(
            bg: "#ffffff", alt: "#efefef", fg: "#4d4d4c", dim: "#8e908c", red: "#c82829", orange: "#c76b17", yellow: "#a87e00",
            green: "#718c00", cyan: "#3e999f", blue: "#4271ae", purple: "#8959a8", accent: "#4271ae")),
        // orgstar's own: warm paper and ink, for long reading.
        ported("paper", "Paper", .light, Roles(
            bg: "#f8f3e6", alt: "#efe8d6", fg: "#3b3428", dim: "#7d7262", red: "#a8322d", orange: "#a85a1f", yellow: "#8a6d1a",
            green: "#4d6b2f", cyan: "#2f6b6b", blue: "#2f5486", purple: "#6b4a85", accent: "#a85a1f")),
    ]

    static let darkPalettes: [Palette] = [
        Palette(id: "default-dark", name: "Default", appearance: .dark, colors: ThemeSpec.default.dark),
        ported("solarized-dark", "Solarized Dark", .dark, Roles(
            bg: "#002b36", alt: "#073642", fg: "#93a1a1", dim: "#586e75", red: "#dc322f", orange: "#cb4b16", yellow: "#b58900",
            green: "#859900", cyan: "#2aa198", blue: "#268bd2", purple: "#6c71c4", accent: "#268bd2")),
        ported("gruvbox-dark", "Gruvbox Dark", .dark, Roles(
            bg: "#282828", alt: "#3c3836", fg: "#ebdbb2", dim: "#928374", red: "#fb4934", orange: "#fe8019", yellow: "#fabd2f",
            green: "#b8bb26", cyan: "#8ec07c", blue: "#83a598", purple: "#d3869b", accent: "#83a598")),
        ported("modus-vivendi", "Modus Vivendi", .dark, Roles(
            bg: "#000000", alt: "#1e1e1e", fg: "#ffffff", dim: "#989898", red: "#ff5f59", orange: "#fec43f", yellow: "#d0bc00",
            green: "#44bc44", cyan: "#00d3d0", blue: "#2fafff", purple: "#b6a0ff", accent: "#2fafff")),
        ported("catppuccin-mocha", "Catppuccin Mocha", .dark, Roles(
            bg: "#1e1e2e", alt: "#181825", fg: "#cdd6f4", dim: "#7f849c", red: "#f38ba8", orange: "#fab387", yellow: "#f9e2af",
            green: "#a6e3a1", cyan: "#94e2d5", blue: "#89b4fa", purple: "#cba6f7", accent: "#cba6f7")),
        ported("nord", "Nord", .dark, Roles(
            bg: "#2e3440", alt: "#3b4252", fg: "#d8dee9", dim: "#616e88", red: "#bf616a", orange: "#d08770", yellow: "#ebcb8b",
            green: "#a3be8c", cyan: "#8fbcbb", blue: "#88c0d0", purple: "#b48ead", accent: "#88c0d0")),
        ported("dracula", "Dracula", .dark, Roles(
            bg: "#282a36", alt: "#44475a", fg: "#f8f8f2", dim: "#6272a4", red: "#ff5555", orange: "#ffb86c", yellow: "#f1fa8c",
            green: "#50fa7b", cyan: "#8be9fd", blue: "#8be9fd", purple: "#bd93f9", accent: "#bd93f9")),
        ported("tokyo-night", "Tokyo Night", .dark, Roles(
            bg: "#1a1b26", alt: "#16161e", fg: "#c0caf5", dim: "#565f89", red: "#f7768e", orange: "#ff9e64", yellow: "#e0af68",
            green: "#9ece6a", cyan: "#7dcfff", blue: "#7aa2f7", purple: "#bb9af7", accent: "#7aa2f7")),
        ported("doom-one", "doom-one", .dark, Roles(
            bg: "#282c34", alt: "#21242b", fg: "#bbc2cf", dim: "#5b6268", red: "#ff6c6b", orange: "#da8548", yellow: "#ecbe7b",
            green: "#98be65", cyan: "#46d9ff", blue: "#51afef", purple: "#c678dd", accent: "#51afef")),
    ]
}

extension ThemeSpec {
    /// A palette's named colors, from which every slot is set.
    public struct Roles: Sendable {
        public var bg, alt, fg, dim, red, orange, yellow, green, cyan, blue, purple, accent: String

        /// Slot → role. `selection` and `inline-background` are translucent roles.
        static let slots: [String: KeyPath<Roles, String> & Sendable] = [
            "background": \.bg, "foreground": \.fg, "cursor": \.accent, "accent": \.accent,
            "heading-1": \.blue, "heading-2": \.purple, "heading-3": \.green, "heading-4": \.orange,
            "heading-5": \.blue, "heading-6": \.purple, "heading-7": \.green, "heading-8": \.orange,
            "todo": \.red, "todo-next": \.blue, "todo-waiting": \.yellow, "done": \.green, "todo-cancelled": \.dim,
            "priority": \.orange, "priority-a": \.red, "priority-b": \.orange, "priority-c": \.dim,
            "tags": \.dim, "link": \.blue, "timestamp": \.purple, "code": \.orange, "verbatim": \.cyan,
            "markup": \.dim, "comment": \.dim, "keyword": \.dim, "metadata": \.dim, "special": \.cyan,
            "block-background": \.alt, "block-delimiter": \.dim, "table": \.fg,
            "line-number": \.dim, "line-number-current": \.fg,
            "syntax-keyword": \.purple, "syntax-string": \.green, "syntax-comment": \.dim, "syntax-function": \.blue,
            "syntax-type": \.yellow, "syntax-number": \.orange, "syntax-property": \.cyan, "syntax-label": \.purple,
            "sidebar-background": \.alt, "sidebar-foreground": \.fg, "sidebar-header": \.dim,
            "modeline-background": \.alt, "modeline-foreground": \.fg, "modeline-highlight": \.accent,
            "state-normal": \.blue, "state-insert": \.green, "state-visual": \.orange,
            "agenda-background": \.bg, "agenda-date": \.fg, "agenda-today": \.accent, "agenda-time": \.dim, "agenda-category": \.dim,
            "agenda-overdue": \.red, "agenda-due-soon": \.orange, "agenda-event": \.purple,
            "habit-clear": \.blue, "habit-ready": \.green, "habit-alert": \.yellow, "habit-overdue": \.red,
        ]

        /// Alphas are whole bytes (`#…33`, `#…59`), so a palette written out as a theme file
        /// reads back equal.
        public func colors(dark: Bool) -> [String: RGBA] {
            var out = Self.slots.compactMapValues { RGBA(hex: self[keyPath: $0]) }
            if var selection = RGBA(hex: accent) {
                selection.alpha = (dark ? 0x59 : 0x33) / 255
                out["selection"] = selection
            }
            if var inline = RGBA(hex: dim) {
                inline.alpha = 0x33 / 255
                out["inline-background"] = inline
            }
            return out
        }
    }

    private static func ported(_ id: String, _ name: String, _ appearance: Palette.Appearance, _ roles: Roles) -> Palette {
        Palette(id: id, name: name, appearance: appearance, colors: roles.colors(dark: appearance == .dark))
    }
}
