import Foundation

/// The commands the Mac App Store build leaves out of the palette and menus: exports that run
/// Emacs, and attaching by link, which the sandbox doesn't allow.
public enum AppStoreCommands {
    public static let hidden: Set<String> = [
        "app.export.pdf", "app.export.text",
        "app.attach.link", "app.attach.symlink",
    ]

    /// What a key bound to a hidden command runs instead; nil when nothing takes its place.
    public static func replacement(for id: String) -> String? {
        id == "app.export.pdf" ? "app.export.print-pdf" : nil
    }
}
