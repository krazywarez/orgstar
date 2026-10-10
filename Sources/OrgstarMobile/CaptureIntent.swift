#if os(iOS)
import AppIntents
import OrgApp
import OrgCore

/// Shortcuts' "Capture to Orgstar": files text with a capture template without the capture
/// sheet. Prompts in the template take their defaults, and `%c` is empty: reading the
/// pasteboard would ask for permission on every run.
struct CaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture to orgstar"
    static let description = IntentDescription("Files text with one of your capture templates.")

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Template Key", description: "A template's key in capture.toml; the first template when empty.")
    var template: String?

    struct Failure: Error, CustomLocalizedStringResourceConvertible {
        let message: String
        var localizedStringResource: LocalizedStringResource { "\(message)" }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let model = MobileModel.shared
        guard let workspace = model.workspace else { throw Failure(message: model.failure ?? "orgstar isn't ready") }
        let placed = model.session.capture(
            text, templateKey: template, templates: CaptureTemplates.load().templates, workspace: workspace, clock: model.clock,
            clipboard: "", userName: ""
        )
        switch placed {
        case .failure(let error):
            throw Failure(message: error.message)
        case .success(let chosen):
            for path in model.session.dirtyPaths { _ = model.session.save(path) }
            let message = "Captured with \(chosen.name)"
            return .result(value: message, dialog: "\(message)")
        }
    }
}

struct OrgstarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CaptureIntent(), phrases: ["Capture to \(.applicationName)"], shortTitle: "Capture", systemImageName: "tray.and.arrow.down")
    }
}
#endif
