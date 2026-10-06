#if os(iOS)
import OrgApp
import OrgCore
import SwiftUI

/// The day/week agenda and the TODO list over the workspace's agenda files.
struct AgendaScreen: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    @Bindable var agenda: AgendaModel
    let scheduler: ReminderScheduler
    @State private var message: String?
    @State private var tick = 0

    private enum View: String, CaseIterable { case agenda = "Agenda", todo = "TODO" }

    private var view: Binding<View> {
        Binding {
            if case .todo = agenda.mode { .todo } else { .agenda }
        } set: { value in
            agenda.mode = value == .todo ? .todo(keywords: nil) : .agenda(span: nil, startOffset: nil)
        }
    }

    private struct Key: Equatable {
        var files: Int
        var changed: Int?
        var edits: Int
        var tick: Int
        var view: String
        var start: Int?
        var span: Int
        var startOffset: Int
        var subfolders: Bool
    }

    var body: some SwiftUI.View {
        List {
            if case .agenda = agenda.mode {
                ForEach(agenda.days, id: \.day) { day in
                    Section {
                        let items = day.items.filter(\.isEntry)
                        ForEach(items.indices, id: \.self) { i in row(items[i]) }
                    } header: {
                        Text(day.header.split(separator: " ", omittingEmptySubsequences: true).prefix(4).joined(separator: " "))
                            .foregroundStyle(day.isToday ? Color.accentColor : .secondary)
                    }
                }
            } else {
                ForEach(agenda.list.indices, id: \.self) { i in row(agenda.list[i]) }
            }
            if let reminderStatus {
                Section { } footer: { Text(reminderStatus) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(agenda.isComputing && agenda.days.isEmpty ? "Agenda…" : "Agenda")
        .overlay {
            if workspace.rootPaths.isEmpty {
                ContentUnavailableView("No folders", systemImage: "folder", description: Text("Add a folder of org files under Folders."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let message {
                Text(message).font(.callout).padding(8).frame(maxWidth: .infinity).background(.bar)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: view) {
                    ForEach(View.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if case .agenda = agenda.mode {
                ToolbarItem(placement: .topBarLeading) {
                    Menu("Days", systemImage: "calendar") {
                        Button("Today", systemImage: "calendar.circle") { agenda.showToday() }
                        Button("Earlier", systemImage: "chevron.left") { agenda.shift(forward: false) }
                        Button("Later", systemImage: "chevron.right") { agenda.shift(forward: true) }
                    }
                }
            }
        }
        .refreshable {
            await workspace.refresh()
            await agenda.refresh(open: session.openTexts)
        }
        .task(id: Key(files: workspace.files.count, changed: workspace.changedFile?.version, edits: session.editVersion, tick: tick,
                      view: view.wrappedValue.rawValue, start: agenda.start, span: agenda.span, startOffset: agenda.startOffset,
                      subfolders: agenda.includeSubfolders)) {
            await agenda.refresh(open: session.openTexts)
        }
    }

    /// How far ahead notifications are set, as the design asks the agenda to show: iOS keeps
    /// at most 64, and sets no more while the app isn't opened.
    private var reminderStatus: String? {
        guard OrgPreferences.reminders() else { return nil }
        if !scheduler.isAuthorized { return "Notifications are off for Orgstar in Settings." }
        guard let through = scheduler.scheduledThrough else { return nil }
        return "Reminders are set through " + through.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
            + ". Open Orgstar to set later ones."
    }

    private func row(_ item: AgendaItem) -> some SwiftUI.View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let time = item.time.firstMatch(of: /[0-9]{1,2}:[0-9]{2}(-[0-9]{1,2}:[0-9]{2})?/) {
                    Text(time.output.0).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(item.text).strikethrough(item.isDone)
            }
            HStack(spacing: 6) {
                Text(item.category)
                let extra = item.extra.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !extra.isEmpty { Text(extra) }
                if !item.tags.isEmpty { Text(item.tags.map { ":" + $0 }.joined() + ":") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .swipeActions(edge: .trailing) {
            if item.todo != nil, !item.isDone, doneKeyword(for: item) != nil {
                Button("Done", systemImage: "checkmark") { markDone(item) }.tint(.green)
            }
        }
    }

    /// The first done keyword of the item's TODO sequence.
    private func doneKeyword(for item: AgendaItem) -> String? {
        guard let todo = item.todo, let path = item.path else { return nil }
        let text = session.openTexts[path] ?? (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let settings = OrgParser.parse(text).settings
        return settings.todoSequences.first { ($0.active + $0.done).contains { $0.name == todo } }?.done.first?.name
    }

    private func markDone(_ item: AgendaItem) {
        guard let path = item.path, let start = item.headingOffset, let keyword = doneKeyword(for: item) else { return }
        switch session.perform(SetTodo(keyword: keyword), path: path, at: start, expect: item.headingLine.map { (start, $0) }) {
        case .failed(let text): message = text
        case .prompt: message = "This state change asks for a note; make it on the Mac"
        default: message = nil
        }
        tick += 1
    }
}

extension AgendaItem {
    /// An entry, not a time-grid line.
    var isEntry: Bool { kind != .timeGrid && kind != .currentTime }
}
#endif
