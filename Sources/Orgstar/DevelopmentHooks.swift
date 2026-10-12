import AppKit
import OrgEditorAppKit

/// Switches for checking the app from scripts, read from the environment:
/// - `ORGSTAR_DATA_DIR`: where the index and roots live (see `WorkspaceModel.defaultDirectory`).
/// - `ORGSTAR_OPEN`: a file to select at launch.
/// - `ORGSTAR_ROOT`: a folder to add at launch.
/// - `ORGSTAR_WINDOW`: a window to open at launch (`agenda`, `settings`); the snapshot renders it.
/// - `ORGSTAR_COMMAND`: commands to run at launch, separated by commas (`app.import-emacs`); a
///   sheet or prompt they open is what the snapshot renders.
/// - `ORGSTAR_ANSWERS`: answers to the prompts those commands ask, in order, separated by commas.
/// - `ORGSTAR_URL`: an `org-protocol://` link to handle at launch, as if opened from a browser.
/// - `ORGSTAR_PASTEBOARD`: the name of a pasteboard to paste images and files from, instead of
///   the clipboard.
/// - `ORGSTAR_APPEARANCE`: `dark` or `light`, instead of the system's.
/// - `ORGSTAR_SNAPSHOT`: after `ORGSTAR_SNAPSHOT_DELAY` seconds (default 3), render the main
///   window to this PNG path and quit. Rendering from inside the app needs no screen-recording
///   permission.
enum DevelopmentHooks {
    static var fileToOpen: String? { ProcessInfo.processInfo.environment["ORGSTAR_OPEN"] }
    static var rootToAdd: String? { ProcessInfo.processInfo.environment["ORGSTAR_ROOT"] }
    static var windowToOpen: String? { ProcessInfo.processInfo.environment["ORGSTAR_WINDOW"] }
    static var commandToRun: String? { ProcessInfo.processInfo.environment["ORGSTAR_COMMAND"] }
    static var urlToOpen: String? { ProcessInfo.processInfo.environment["ORGSTAR_URL"] }
    static var answers: [String] { ProcessInfo.processInfo.environment["ORGSTAR_ANSWERS"]?.split(separator: ",").map(String.init) ?? [] }

    @MainActor
    static func scheduleSnapshot() {
        let environment = ProcessInfo.processInfo.environment
        if let name = environment["ORGSTAR_PASTEBOARD"] { OrgEditor.pasteboard = NSPasteboard(name: NSPasteboard.Name(name)) }
        if let appearance = environment["ORGSTAR_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        guard let path = environment["ORGSTAR_SNAPSHOT"] else { return }
        let delay = Double(environment["ORGSTAR_SNAPSHOT_DELAY"] ?? "") ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let visible = NSApp.windows.filter(\.isVisible)
            let chosen = windowToOpen.flatMap { id in visible.first { $0.identifier?.rawValue.lowercased().contains(id) == true } } ?? visible.first
            let window = chosen?.attachedSheet ?? chosen
            if let view = window?.contentView?.superview,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            if let chosen, let sheet = chosen.attachedSheet { chosen.endSheet(sheet) }
            NSApp.terminate(nil)
        }
    }
}
