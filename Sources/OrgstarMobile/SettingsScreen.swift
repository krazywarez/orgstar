#if os(iOS)
import OrgApp
import OrgCore
import OrgPresentation
import SwiftUI
import UIKit

/// Where settings come from: a folder with the Mac's `config.toml` and `capture.toml`, kept in
/// sync by iCloud Drive or another app.
struct SettingsScreen: View {
    let model: MobileModel
    @State private var choosing = false
    @State private var calendars: [CalendarChoice] = []

    private struct CalendarChoice {
        let id: String
        let title: String
        let color: RGBA?
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder", value: model.configFolder?.lastPathComponent ?? "None")
                Button(model.configFolder == nil ? "Choose Folder…" : "Choose Another Folder…") { choosing = true }
                if model.configFolder != nil {
                    NavigationLink("Edit config.toml") { ConfigFileEditor(model: model) }
                    Button("Stop Using This Folder", role: .destructive) { model.setConfigFolder(nil) }
                }
                ForEach(model.configProblems, id: \.self) { Text($0).foregroundStyle(.red) }
            } header: {
                Text("Configuration")
            } footer: {
                Text("A folder with config.toml and capture.toml, such as a synced copy of ~/.config/orgstar from your Mac. Changes to them apply as they sync.")
            }
            Section("Agenda") {
                let _ = model.settingsVersion
                Toggle("Show days without entries", isOn: Binding {
                    OrgPreferences.agendaShowAllDates()
                } set: { model.set("agendaShowAllDates", to: .bool($0)) })
                Picker("Blocked entries", selection: Binding {
                    UserDefaults.standard.string(forKey: "agendaDimBlockedTasks") ?? "t"
                } set: { model.set("agendaDimBlockedTasks", to: .string($0)) }) {
                    Text("Dimmed").tag("t")
                    Text("Hidden").tag("invisible")
                    Text("Shown as usual").tag("nil")
                }
            }
            Section {
                let _ = model.settingsVersion
                Toggle("Not done before TODO children", isOn: Binding {
                    UserDefaults.standard.bool(forKey: "enforceTodoDependencies")
                } set: { model.set("enforceTodoDependencies", to: .bool($0)) })
                Toggle("Not done with unchecked boxes", isOn: Binding {
                    UserDefaults.standard.bool(forKey: "enforceTodoCheckboxDependencies")
                } set: { model.set("enforceTodoCheckboxDependencies", to: .bool($0)) })
            } header: {
                Text("TODO Dependencies")
            } footer: {
                Text("org-enforce-todo-dependencies and org-enforce-todo-checkbox-dependencies.")
            }
            calendarSection
            Section("In use") {
                let _ = model.settingsVersion
                LabeledContent("TODO keywords", value: todoKeywords)
                LabeledContent("Agenda", value: agenda)
                LabeledContent("Reminders", value: OrgPreferences.reminders() ? "\(OrgPreferences.reminderLead()) min before" : "Off")
                LabeledContent("Capture templates", value: CaptureTemplates.load().templates.map(\.key).joined(separator: " "))
                LabeledContent("Theme", value: UserDefaults.standard.string(forKey: "themeFile").flatMap { $0.isEmpty ? nil : $0 } ?? "Default")
                LabeledContent("Font", value: font)
            }
        }
        .navigationTitle("Settings")
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.setConfigFolder(url) }
        }
    }

    /// `calendar-events` and `calendar-event-calendars`, written to config.toml.
    private var calendarSection: some View {
        let _ = model.settingsVersion
        let on = OrgPreferences.calendarEvents()
        let chosen = OrgPreferences.calendarEventCalendars()
        return Section {
            Toggle("Show Calendar Events", isOn: Binding {
                on
            } set: { value in
                model.set("calendarEvents", to: .bool(value))
                if value { Task { await requestCalendars() } }
            })
            if on {
                if !CalendarEvents.isAuthorized {
                    Button("Allow Access to Calendars…") { Task { await requestCalendars() } }
                }
                ForEach(calendars, id: \.id) { calendar in
                    let shown = CalendarEvents.chooses(id: calendar.id, title: calendar.title, chosen: chosen)
                    Button {
                        toggle(calendar.title, shown: shown, chosen: chosen)
                    } label: {
                        HStack {
                            Circle().fill(calendar.color?.swiftUI ?? .secondary).frame(width: 10, height: 10)
                            Text(calendar.title).foregroundStyle(.primary)
                            Spacer()
                            if shown { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                    }
                    .tint(.primary)
                }
            }
        } header: {
            Text("Calendar")
        } footer: {
            Text(on ? "Events from the checked calendars show in the agenda, read-only." : "Show events from Calendar in the agenda, read-only.")
        }
        .task(id: on) { loadCalendars() }
    }

    private func requestCalendars() async {
        _ = await model.calendarEvents.requestAccess()
        loadCalendars()
        model.reloadConfig()
    }

    private func loadCalendars() {
        calendars = model.calendarEvents.calendars()
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { CalendarChoice(id: $0.id, title: $0.title, color: $0.color) }
    }

    /// Shows or hides a calendar's events; with every calendar checked the setting is empty.
    /// The last checked calendar stays checked, as an empty list means every calendar.
    private func toggle(_ title: String, shown: Bool, chosen: [String]) {
        var titles = calendars.filter { CalendarEvents.chooses(id: $0.id, title: $0.title, chosen: chosen) }.map(\.title)
        titles.removeAll { $0 == title }
        if !shown { titles.append(title) }
        guard !titles.isEmpty else { return }
        let value = Set(titles) == Set(calendars.map(\.title)) ? "" : titles.joined(separator: ", ")
        model.set("calendarEventCalendars", to: .string(value))
    }

    /// The span and start day, worded as the Mac's Settings word the start.
    private var agenda: String {
        func days(_ count: Int) -> String { count == 1 ? "1 day" : "\(count) days" }
        let offset = OrgPreferences.agendaStartOffset()
        let start = offset == 0 ? "today" : offset < 0 ? "\(days(-offset)) before today" : "\(days(offset)) after today"
        return "\(days(OrgPreferences.agendaSpan())), starting \(start)"
    }

    /// The theme's family, or the system's monospaced font when it's unset or not on the device.
    private var font: String {
        let spec = model.theme
        let family = spec.font.isEmpty || UIFont.fontNames(forFamilyName: spec.font).isEmpty ? "System monospaced" : spec.font
        let missing = !spec.font.isEmpty && family != spec.font ? " (\(spec.font) isn't installed)" : ""
        return "\(family), \(spec.fontSize) pt\(missing)"
    }

    private var todoKeywords: String {
        OrgPreferences.orgSettings().todoSequences.map { ($0.active.map(\.name) + ["|"] + $0.done.map(\.name)).joined(separator: " ") }
            .joined(separator: "; ")
    }
}
/// The configuration folder's `config.toml` as plain text, saved when you tap Save or leave.
struct ConfigFileEditor: View {
    let model: MobileModel
    @State private var text = ""
    @State private var saved: String?

    var body: some View {
        PlainTextView(text: $text)
            .navigationTitle("config.toml")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Save") { save() }.disabled(text == saved)
            }
            .safeAreaInset(edge: .bottom) {
                let _ = model.settingsVersion
                if !model.configProblems.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.configProblems, id: \.self) { Text($0) }
                    }
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
                }
            }
            .onAppear {
                guard saved == nil else { return }
                text = model.configText() ?? UserConfig.defaultTemplate
                saved = text
            }
            .onDisappear { save() }
    }

    private func save() {
        guard text != saved else { return }
        model.saveConfig(text)
        saved = text
    }
}

/// A monospaced text view without smart quotes, dashes or autocorrection, which would break TOML.
private struct PlainTextView: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        view.adjustsFontForContentSizeCategory = true
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.keyboardDismissMode = .interactive
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textViewDidChange(_ view: UITextView) { text.wrappedValue = view.text }
    }
}
#endif
