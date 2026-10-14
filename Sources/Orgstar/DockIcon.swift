import AppKit
import OrgPresentation

/// The icon chosen in Settings ▸ Appearance, shown in the Dock while orgstar runs, in the
/// variant for the current appearance.
@MainActor
enum DockIcon {
    private static var observation: NSKeyValueObservation?

    static func apply() {
        let id = UserDefaults.standard.string(forKey: "appIcon") ?? "default"
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard let file = AppIcons.dockFile(id, dark: dark),
              let url = Bundle.main.url(forResource: file, withExtension: "png", subdirectory: "IconPreviews") else {
            NSApp.applicationIconImage = nil
            return
        }
        NSApp.applicationIconImage = NSImage(contentsOf: url)
    }

    /// Applies now, and again whenever the appearance changes.
    static func start() {
        apply()
        observation = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in apply() }
        }
    }
}
