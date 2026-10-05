import AppKit

/// Switches for checking the app from scripts, read from the environment:
/// - `ORGSTAR_DATA_DIR`: where the index and roots live (see `WorkspaceModel.defaultDirectory`).
/// - `ORGSTAR_OPEN`: a file to select at launch.
/// - `ORGSTAR_SNAPSHOT`: after `ORGSTAR_SNAPSHOT_DELAY` seconds (default 3), render the main
///   window to this PNG path and quit. Rendering from inside the app needs no screen-recording
///   permission.
enum DevelopmentHooks {
    static var fileToOpen: String? { ProcessInfo.processInfo.environment["ORGSTAR_OPEN"] }

    @MainActor
    static func scheduleSnapshot() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["ORGSTAR_SNAPSHOT"] else { return }
        let delay = Double(environment["ORGSTAR_SNAPSHOT_DELAY"] ?? "") ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let view = NSApp.windows.first(where: \.isVisible)?.contentView?.superview,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }
}
