import OrgApp
import OrgCore
import SwiftUI

/// The agenda window: `org-agenda-list` over the agenda files. Return or a double click jumps
/// to the entry in the main window; f/b move a span, `.` returns to today, g refreshes.
struct AgendaView: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    let commands: AppCommands
    @State private var agenda: AgendaModel
    @State private var selection: String?
    @State private var tick = 0
    @AppStorage("agendaSpan") private var span = 10
    @AppStorage("agendaStartOffset") private var startOffset = -3
    @AppStorage("agendaSubfolders") private var includeSubfolders = false
    @Environment(\.openWindow) private var openWindow

    init(workspace: WorkspaceModel, session: DocumentSession, commands: AppCommands) {
        self.workspace = workspace
        self.session = session
        self.commands = commands
        _agenda = State(initialValue: AgendaModel(workspace: workspace))
    }

    private struct RefreshKey: Hashable {
        var start: Int?
        var span: Int
        var startOffset: Int
        var includeSubfolders: Bool
        var files: Int
        var changed: Int?
        var edits: Int
        var path: String?
        var tick: Int
    }

    private var refreshKey: RefreshKey {
        RefreshKey(
            start: agenda.start, span: span, startOffset: startOffset, includeSubfolders: includeSubfolders,
            files: workspace.files.count, changed: workspace.changedFile?.version, edits: session.editVersion,
            path: session.path, tick: tick
        )
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(agenda.days, id: \.day) { day in
                Section {
                    ForEach(Array(day.items.enumerated()), id: \.offset) { index, item in
                        AgendaRow(item: item)
                            .tag(Self.id(day, index))
                            .selectionDisabled(item.path == nil)
                    }
                } header: {
                    Text(day.header)
                        .font(.headline)
                        .foregroundStyle(day.isToday ? Color.accentColor : .primary)
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { _ in
        } primaryAction: { ids in
            if let id = ids.first { jump(id) }
        }
        .onKeyPress(.return) {
            guard let selection else { return .ignored }
            jump(selection)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "fb.gr")) { press in
            switch press.characters {
            case "f": agenda.shift(forward: true)
            case "b": agenda.shift(forward: false)
            case ".": agenda.showToday()
            default: tick += 1
            }
            return .handled
        }
        .toolbar {
            ToolbarItemGroup {
                if agenda.isComputing { ProgressView().controlSize(.small) }
                Button("Earlier", systemImage: "chevron.left") { agenda.shift(forward: false) }
                    .help("Previous \(span) days (b)")
                Button("Today") { agenda.showToday() }
                    .help("Back to today (.)")
                Button("Later", systemImage: "chevron.right") { agenda.shift(forward: true) }
                    .help("Next \(span) days (f)")
            }
        }
        .overlay {
            if agenda.files.isEmpty {
                ContentUnavailableView("No agenda files", systemImage: "calendar", description: Text("The agenda reads the org files at the top of each folder you add."))
            }
        }
        .navigationTitle("Agenda")
        .task(id: refreshKey) {
            agenda.span = span
            agenda.startOffset = startOffset
            agenda.includeSubfolders = includeSubfolders
            let open = session.path.flatMap { path in session.document.map { (path, $0.text) } }
            await agenda.refresh(open: open)
        }
        .task {
            // The time grid's "now" line and the day itself move on.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                tick += 1
            }
        }
    }

    private static func id(_ day: AgendaDay, _ index: Int) -> String { "\(day.day):\(index)" }

    private func jump(_ id: String) {
        let parts = id.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, let day = agenda.days.first(where: { $0.day == parts[0] }), parts[1] < day.items.count else { return }
        let item = day.items[parts[1]]
        guard let path = item.path, let offset = item.markerOffset ?? item.headingOffset else { return }
        commands.jump(path: path, offset: offset)
        openWindow(id: "main")
    }
}

struct AgendaRow: View {
    let item: AgendaItem

    var body: some View {
        switch item.kind {
        case .timeGrid:
            HStack(spacing: 8) {
                Text(item.time.trimmingCharacters(in: CharacterSet(charactersIn: " ┄.")))
                    .monospacedDigit()
                    .frame(width: 140, alignment: .trailing)
                VStack { Divider() }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        case .currentTime:
            HStack(spacing: 8) {
                Text("now " + item.time.trimmingCharacters(in: CharacterSet(charactersIn: " ┄.")))
                    .monospacedDigit()
                    .frame(width: 140, alignment: .trailing)
                Rectangle().fill(Color.accentColor).frame(height: 1)
            }
            .font(.caption)
            .foregroundStyle(Color.accentColor)
        default:
            HStack(spacing: 8) {
                Text(item.category)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                Text(item.time.trimmingCharacters(in: CharacterSet(charactersIn: " ┄.")))
                    .monospacedDigit()
                    .frame(width: 80, alignment: .leading)
                if !item.extra.isEmpty {
                    Text(item.extra.trimmingCharacters(in: .whitespaces))
                        .monospacedDigit()
                        .foregroundStyle(leaderColor)
                }
                title
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !item.tags.isEmpty {
                    Text(":" + item.tags.joined(separator: ":") + ":")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var leaderColor: Color {
        switch item.kind {
        case .deadline: .red
        case .upcomingDeadline: .orange
        case .pastScheduled: .brown
        default: .secondary
        }
    }

    /// The TODO keyword colored as in the editor.
    private var title: Text {
        guard let todo = item.todo, item.text.hasPrefix(todo + " ") else { return Text(item.text.trimmingCharacters(in: .whitespaces)) }
        let text = item.text.trimmingCharacters(in: .whitespaces)
        let rest = String(text.dropFirst(todo.count))
        return Text(todo).foregroundColor(item.isDone ? .green : .red).bold() + Text(rest).foregroundColor(item.isDone ? .secondary : .primary)
    }
}
