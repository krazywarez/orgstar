import Foundation

/// The app icons `scripts/make-icon.swift` draws, by id, in its order.
public enum AppIcons {
    public static let ids = [
        "default", "midnight", "paper", "org", "sunset", "forest", "mono", "rainbow", "outline", "terminal",
        "unicorn", "unicorn-night", "unicorn-pastel",
    ]

    private static func words(_ id: String) -> [String] { id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() } }

    /// The icon's name in the user's language.
    public static func name(_ id: String) -> String {
        switch id {
        case "default": String(localized: "Default")
        case "midnight": String(localized: "Midnight")
        case "paper": String(localized: "Paper")
        case "sunset": String(localized: "Sunset")
        case "forest": String(localized: "Forest")
        case "rainbow": String(localized: "Rainbow")
        case "outline": String(localized: "Outline")
        // Ids from when these were unicorns, kept so an icon chosen then stays chosen.
        case "unicorn": String(localized: "Org Star")
        case "unicorn-night": String(localized: "Night Star")
        case "unicorn-pastel": String(localized: "Pastel Star")
        default: words(id).joined(separator: " ")
        }
    }

    /// The iOS alternate icon's name; nil for the primary icon.
    public static func alternateName(_ id: String) -> String? {
        id == "default" ? nil : "AppIcon-" + words(id).joined()
    }

    public static func id(alternateName: String?) -> String {
        ids.first { self.alternateName($0) == alternateName && alternateName != nil } ?? "default"
    }
}

extension AppIcons {
    /// The Mac's Dock icon file for `id` in an appearance, in `Contents/Resources/IconPreviews`;
    /// nil for the default, which is the bundle's own icon.
    public static func dockFile(_ id: String, dark: Bool) -> String? {
        guard id != "default", ids.contains(id) else { return nil }
        return "\(id)-\(dark ? "dark" : "light")"
    }
}
