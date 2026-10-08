#if os(iOS)
import OrgApp
import OrgCore
import SwiftUI

/// Where settings come from: a folder with the Mac's `config.toml` and `capture.toml`, kept in
/// sync by iCloud Drive or another app.
struct SettingsScreen: View {
    let model: MobileModel
    @State private var choosing = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder", value: model.configFolder?.lastPathComponent ?? "None")
                Button(model.configFolder == nil ? "Choose Folder…" : "Choose Another Folder…") { choosing = true }
                if model.configFolder != nil {
                    Button("Stop Using This Folder", role: .destructive) { model.setConfigFolder(nil) }
                }
                ForEach(model.configProblems, id: \.self) { Text($0).foregroundStyle(.red) }
            } header: {
                Text("Configuration")
            } footer: {
                Text("A folder with config.toml and capture.toml, such as a synced copy of ~/.config/orgstar from your Mac. Changes to them apply as they sync.")
            }
            Section("In use") {
                let _ = model.settingsVersion
                LabeledContent("TODO keywords", value: todoKeywords)
                LabeledContent("Agenda", value: agenda)
                LabeledContent("Reminders", value: OrgPreferences.reminders() ? "\(OrgPreferences.reminderLead()) min before" : "Off")
                LabeledContent("Capture templates", value: CaptureTemplates.load().templates.map(\.key).joined(separator: " "))
            }
        }
        .navigationTitle("Settings")
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.setConfigFolder(url) }
        }
    }

    /// The span and start day, worded as the Mac's Settings word the start.
    private var agenda: String {
        func days(_ count: Int) -> String { count == 1 ? "1 day" : "\(count) days" }
        let offset = OrgPreferences.agendaStartOffset()
        let start = offset == 0 ? "today" : offset < 0 ? "\(days(-offset)) before today" : "\(days(offset)) after today"
        return "\(days(OrgPreferences.agendaSpan())), starting \(start)"
    }

    private var todoKeywords: String {
        OrgPreferences.orgSettings().todoSequences.map { ($0.active.map(\.name) + ["|"] + $0.done.map(\.name)).joined(separator: " ") }
            .joined(separator: "; ")
    }
}
#endif
