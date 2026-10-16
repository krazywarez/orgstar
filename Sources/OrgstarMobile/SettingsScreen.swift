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
    @State private var reminderLists: [CalendarChoice] = []
    @State private var badges: Bool?
    @State private var appIcon = AppIcons.id(alternateName: UIApplication.shared.alternateIconName)
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

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
                }
                NavigationLink("Import from Emacs") { EmacsImportScreen(model: model) }
                if model.configFolder != nil {
                    Button("Stop Using This Folder", role: .destructive) { model.setConfigFolder(nil) }
                }
                ForEach(model.configProblems, id: \.self) { Text($0).foregroundStyle(.red) }
            } header: {
                Text("Configuration")
            } footer: {
                Text("A folder with config.toml and capture.toml, such as a synced copy of ~/.config/orgstar from your Mac. Changes to them apply as they sync.")
            }
            Section {
                let _ = model.settingsVersion
                Toggle("Show days without entries", isOn: Binding {
                    OrgPreferences.agendaShowAllDates()
                } set: { model.set("agendaShowAllDates", to: .bool($0)) })
                Toggle("Habits only today", isOn: Binding {
                    OrgPreferences.habitsOnlyForToday()
                } set: { model.set("habitsOnlyForToday", to: .bool($0)) })
                Toggle("Leave out archive files", isOn: Binding {
                    OrgPreferences.agendaExcludeArchives()
                } set: { model.set("agendaExcludeArchives", to: .bool($0)) })
                Picker("Blocked entries", selection: Binding {
                    UserDefaults.standard.string(forKey: "agendaDimBlockedTasks") ?? "t"
                } set: { model.set("agendaDimBlockedTasks", to: .string($0)) }) {
                    Text("Dimmed").tag("t")
                    Text("Hidden").tag("invisible")
                    Text("Shown as usual").tag("nil")
                }
            } header: {
                Text("Agenda")
            } footer: {
                Text("Archive files are the ones your agenda files archive to, named by #+ARCHIVE:, an :ARCHIVE: property or org-archive-location.")
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
            Section {
                if badges == true {
                    LabeledContent("Overdue Count on Icon", value: "On")
                } else if badges == false {
                    Button("Show Overdue Count on Icon…") {
                        Task {
                            if await model.badgesEnabled(asking: true) {
                                badges = true
                                await model.updateWidgets()
                            } else if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                openURL(url)
                            }
                        }
                    }
                }
            } header: {
                Text("Badge")
            } footer: {
                if badges == false { Text("Turn on Badges in orgstar's notification settings.") }
            }
            Section("Appearance") {
                let _ = model.settingsVersion
                NavigationLink {
                    ThemePickerScreen(model: model, appearance: .light)
                } label: {
                    LabeledContent("Light Theme", value: ThemePickerScreen.current(.light).displayName)
                }
                NavigationLink {
                    ThemePickerScreen(model: model, appearance: .dark)
                } label: {
                    LabeledContent("Dark Theme", value: ThemePickerScreen.current(.dark).displayName)
                }
                NavigationLink {
                    AppIconScreen(current: $appIcon)
                } label: {
                    LabeledContent("App Icon", value: AppIcons.name(appIcon))
                }
            }
            calendarSection
            reminderSection
            Section("In use") {
                let _ = model.settingsVersion
                LabeledContent("TODO keywords", value: todoKeywords)
                LabeledContent("Agenda", value: agenda)
                LabeledContent("Reminders", value: OrgPreferences.reminders() ? "\(OrgPreferences.reminderLead()) min before" : "Off")
                LabeledContent("Capture templates", value: CaptureTemplates.load().templates.map(\.key).joined(separator: " "))
                LabeledContent("Theme", value: themeInUse)
                LabeledContent("Font", value: font)
            }
        }
        .navigationTitle("Settings")
        // Read again on return from the Settings app.
        .task(id: scenePhase) { badges = await model.badgesEnabled(asking: false) }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.setConfigFolder(url) }
        }
    }

    /// The two palettes' names, and the theme file's when there is one.
    private var themeInUse: String {
        let names = "\(ThemePickerScreen.current(.light).displayName) / \(ThemePickerScreen.current(.dark).displayName)"
        guard let file = UserDefaults.standard.string(forKey: "themeFile"), !file.isEmpty else { return names }
        return "\(names), \(file)"
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
            Text(on ? "Events from the checked calendars show in the agenda. Tap one to edit it." : "Show events from Calendar in the agenda.")
        }
        .task(id: on) { loadCalendars() }
    }

    /// `agenda-reminders` and `agenda-reminder-lists`, written to config.toml.
    private var reminderSection: some View {
        let _ = model.settingsVersion
        let on = OrgPreferences.agendaReminders()
        let chosen = OrgPreferences.agendaReminderLists()
        return Section {
            Toggle("Show Reminders", isOn: Binding {
                on
            } set: { value in
                model.set("agendaReminders", to: .bool(value))
                if value { Task { await requestReminders() } }
            })
            if on {
                if !ReminderLists.isAuthorized {
                    Button("Allow Access to Reminders…") { Task { await requestReminders() } }
                }
                ForEach(reminderLists, id: \.id) { list in
                    let shown = CalendarEvents.chooses(id: list.id, title: list.title, chosen: chosen)
                    Button {
                        toggle(list.title, shown: shown, chosen: chosen, among: reminderLists, key: "agendaReminderLists")
                    } label: {
                        HStack {
                            Circle().fill(list.color?.swiftUI ?? .secondary).frame(width: 10, height: 10)
                            Text(list.title).foregroundStyle(.primary)
                            Spacer()
                            if shown { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                    }
                    .tint(.primary)
                }
            }
        } header: {
            Text("Reminders")
        } footer: {
            Text(on ? "Incomplete reminders with a due date from the checked lists show in the agenda, read-only; overdue ones under today."
                 : "Show reminders from Reminders in the agenda, read-only.")
        }
        .task(id: on) { loadReminderLists() }
    }

    private func requestReminders() async {
        _ = await model.reminderLists.requestAccess()
        loadReminderLists()
        model.reloadConfig()
    }

    private func loadReminderLists() {
        reminderLists = model.reminderLists.lists()
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { CalendarChoice(id: $0.id, title: $0.title, color: $0.color) }
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

    /// Shows or hides a calendar's events or a list's reminders; with every one checked the
    /// setting is empty. The last checked one stays checked, as an empty list means every one.
    private func toggle(_ title: String, shown: Bool, chosen: [String], among choices: [CalendarChoice]? = nil, key: String = "calendarEventCalendars") {
        let choices = choices ?? calendars
        var titles = choices.filter { CalendarEvents.chooses(id: $0.id, title: $0.title, chosen: chosen) }.map(\.title)
        titles.removeAll { $0 == title }
        if !shown { titles.append(title) }
        guard !titles.isEmpty else { return }
        let value = Set(titles) == Set(choices.map(\.title)) ? "" : titles.joined(separator: ", ")
        model.set(key, to: .string(value))
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
