import AppKit

/// Switches for checking the app from scripts, read from the environment:
/// - `ORGSTAR_DATA_DIR`: where the index and roots live (see `WorkspaceModel.defaultDirectory`).
/// - `ORGSTAR_OPEN`: a file to select at launch.
/// - `ORGSTAR_ROOT`: a folder to add at launch.
/// - `ORGSTAR_WINDOW`: a window to open at launch (`agenda`, `settings`); the snapshot renders it.
/// - `ORGSTAR_SNAPSHOT`: after `ORGSTAR_SNAPSHOT_DELAY` seconds (default 3), render the main
///   window to this PNG path and quit. Rendering from inside the app needs no screen-recording
///   permission.
enum DevelopmentHooks {
    static var fileToOpen: String? { ProcessInfo.processInfo.environment["ORGSTAR_OPEN"] }
    static var rootToAdd: String? { ProcessInfo.processInfo.environment["ORGSTAR_ROOT"] }
    static var windowToOpen: String? { ProcessInfo.processInfo.environment["ORGSTAR_WINDOW"] }

    @MainActor
    static func scheduleSnapshot() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["ORGSTAR_SNAPSHOT"] else { return }
        let delay = Double(environment["ORGSTAR_SNAPSHOT_DELAY"] ?? "") ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let visible = NSApp.windows.filter(\.isVisible)
            let window = windowToOpen.flatMap { id in visible.first { $0.identifier?.rawValue.lowercased().contains(id) == true } } ?? visible.first
            if let view = window?.contentView?.superview,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }
}
