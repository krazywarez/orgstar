#if os(iOS)
import OrgApp
import OrgCore
import SwiftUI

/// Clock commands that ask questions, and their answers in `ClockPromptSheet`.
@MainActor
@Observable
final class ClockPrompter {
    struct Pending: Identifiable {
        let id = UUID()
        let prompt: Prompt
        let reply: (String?) -> Void
    }

    var pending: Pending?

    var ask: ClockModel.Ask {
        { [self] prompt in
            await withCheckedContinuation { continuation in
                pending = Pending(prompt: prompt) { continuation.resume(returning: $0) }
            }
        }
    }

    func answer(_ text: String?) {
        guard let request = pending else { return }
        pending = nil
        request.reply(text)
    }
}

/// The clock commands both the editor and the clock accessory run.
@MainActor
enum MobileClock {
    /// Runs a clock command; false for other ids. Messages go to `show`; entries to show open.
    static func run(_ id: String, model: MobileModel, workspace: WorkspaceModel, show: @escaping (String) -> Void) -> Bool {
        let clock = model.clock
        let session = model.session
        let ask = model.clockPrompts.ask
        let paths = workspace.files.filter { $0.kind == .org }.map(\.path)
        func open(_ location: (path: String, offset: Int)?) {
            if let location { model.openRequest = .offset(location.path, location.offset) }
        }
        func report(_ outcome: ClockModel.Outcome) {
            open(outcome.jump)
            if let message = outcome.messages.last(where: { !$0.isEmpty }) { show(message) }
        }
        func clockIn(_ target: ClockModel.Target) {
            Task { report(await clock.clockIn(session, target: target, paths: paths, ask: ask)) }
        }
        switch id {
        case "app.clock.in": clockIn(.caret)
        case "app.clock.in-recent": clockIn(.select)
        case "app.clock.in-last": clockIn(.last)
        case let id where id.hasPrefix("app.clock.history."):
            guard let index = Int(id.dropFirst("app.clock.history.".count)), index < clock.history.count else { return true }
            clockIn(.task(clock.history[index]))
        case "app.clock.out": show(clock.clockOut(session))
        case "app.clock.cancel": show(clock.clockOut(session, cancel: true))
        case "app.clock.goto":
            let found = clock.goto(session)
            open(found.location)
            if let message = found.message { show(message) }
        case "app.clock.goto-recent":
            Task {
                let found = await clock.gotoRecent(session, ask: ask)
                open(found.location)
                if let message = found.message { show(message) }
            }
        case "app.clock.default": show(clock.markDefault(session))
        case "app.clock.resolve":
            Task { report(await clock.resolveOpenClocks(session, paths: paths, ask: ask)) }
        default:
            return false
        }
        return true
    }
}

/// Recent entries to clock in to, and the commands that choose among them.
struct RecentClockMenu: View {
    let clock: ClockModel
    let perform: (String) -> Void

    var body: some View {
        Menu("Recent Entries", systemImage: "clock.arrow.circlepath") {
            ForEach(Array(clock.history.enumerated()), id: \.offset) { index, task in
                Button(task.title) { perform("app.clock.history.\(index)") }
            }
            Divider()
            Button("Clock In to Recent Entry…") { perform("app.clock.in-recent") }
            Button("Go to Recent Clocked Entry…") { perform("app.clock.goto-recent") }
        }
        .disabled(clock.history.isEmpty)
    }
}

/// A clock question: keys to choose from under their sections, or a number or date to type.
struct ClockPromptSheet: View {
    let prompt: Prompt
    let answer: (String?) -> Void
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                if let fast = prompt.fast {
                    ForEach(Array(sections(fast).enumerated()), id: \.offset) { _, section in
                        Section(section.title) {
                            ForEach(Array(section.options.enumerated()), id: \.offset) { _, option in
                                Button {
                                    answer(String(option.key))
                                } label: {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(String(option.key)).font(.body.monospaced()).foregroundStyle(.tint)
                                        Text(option.name).foregroundStyle(.primary)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Section {
                        TextField(prompt.message, text: $text)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(prompt.date == nil ? .numbersAndPunctuation : .default)
                            .onSubmit { answer(text) }
                    } footer: {
                        Text(prompt.date == nil ? "Empty takes the default." : "Org's date syntax: 14:00, -1h, today 9:30")
                    }
                }
            }
            .navigationTitle(prompt.message.trimmingCharacters(in: CharacterSet(charactersIn: ":?[] ")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { answer(nil) } }
                if prompt.fast == nil {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { answer(text) } }
                }
            }
        }
        .onAppear { text = prompt.initial }
        .interactiveDismissDisabled()
    }

    private struct Group {
        var title: String
        var options: [(key: Character, name: String)]
    }

    /// Options under the labels before them.
    private func sections(_ fast: FastSelection) -> [Group] {
        var groups: [Group] = []
        for item in fast.items {
            switch item {
            case .label(let title): groups.append(Group(title: title, options: []))
            case .option(let key, let name):
                if groups.isEmpty { groups.append(Group(title: "", options: [])) }
                groups[groups.count - 1].options.append((key, name))
            default: break
            }
        }
        return groups
    }
}

/// The running clock over the tab bar: the entry and time so far, and clocking out.
struct ClockAccessory: View {
    let running: ClockModel.Running
    let clock: ClockModel
    let perform: (String) -> Void

    var body: some View {
        Menu {
            Button("Clock Out", systemImage: "stop.circle") { perform("app.clock.out") }
            Button("Cancel Clock", systemImage: "xmark.circle") { perform("app.clock.cancel") }
            Button("Go to Clocked Entry", systemImage: "arrow.right.circle") { perform("app.clock.goto") }
            RecentClockMenu(clock: clock, perform: perform)
            Button("Clock Report", systemImage: "list.bullet.rectangle") { perform("app.clock.report") }
        } label: {
            HStack {
                Image(systemName: "stopwatch")
                Text(running.heading).lineLimit(1)
                Spacer()
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(Self.elapsed(running, now: context.date)).monospacedDigit()
                }
            }
            .padding(.horizontal)
        }
        .accessibilityLabel("Clocked in on \(running.heading)")
    }

    /// Elapsed time of the running clock, `H:MM`.
    static func elapsed(_ running: ClockModel.Running, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(running.startedAt) / 60))
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

extension View {
    /// The running clock over the tab bar, while there is one.
    @ViewBuilder
    func clockAccessory(_ clock: ClockModel, perform: @escaping (String) -> Void) -> some View {
        if #available(iOS 26.1, *) {
            tabViewBottomAccessory(isEnabled: clock.running != nil) {
                if let running = clock.running { ClockAccessory(running: running, clock: clock, perform: perform) }
            }
        } else {
            safeAreaInset(edge: .bottom) {
                if let running = clock.running { ClockAccessory(running: running, clock: clock, perform: perform).padding(.vertical, 8).background(.bar) }
            }
        }
    }
}

/// Time per day and heading, as `tr/generate-report` writes it, for chosen files and dates.
struct ClockReportScreen: View {
    let workspace: WorkspaceModel
    @State private var start = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var end = Date()
    @State private var limit = false
    @State private var selected: Set<String> = []
    @State private var report = ""
    @Environment(\.dismiss) private var dismiss

    private var candidates: [FileEntry] { workspace.files.filter { $0.kind == .org } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Files") {
                    ForEach(candidates) { file in
                        Toggle(file.relativePath, isOn: Binding {
                            selected.contains(file.path)
                        } set: { on in
                            if on { selected.insert(file.path) } else { selected.remove(file.path) }
                        })
                    }
                }
                Section {
                    Toggle("Limit dates", isOn: $limit)
                    if limit {
                        DatePicker("From", selection: $start, displayedComponents: .date)
                        DatePicker("To", selection: $end, displayedComponents: .date)
                    }
                }
                Section("Report") {
                    ScrollView(.horizontal) {
                        Text(report.isEmpty ? "Choose files with clocked time." : report)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .fixedSize()
                    }
                }
            }
            .navigationTitle("Clock Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: report, preview: SharePreview("Time report")).disabled(report.isEmpty)
                }
            }
        }
        .onAppear {
            if selected.isEmpty {
                selected = Set(candidates.filter { (try? String(contentsOfFile: $0.path, encoding: .utf8))?.contains("CLOCK: [") ?? false }.map(\.path))
            }
            compute()
        }
        .onChange(of: selected) { compute() }
        .onChange(of: start) { compute() }
        .onChange(of: end) { compute() }
        .onChange(of: limit) { compute() }
    }

    private func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func compute() {
        var entries: [ClockReport.Entry] = []
        for path in selected.sorted() {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            entries += ClockReport.entries(text, settings: workspace.settings.org)
        }
        report = selected.isEmpty ? "" : ClockReport.timeReport(entries, start: limit ? day(start) : nil, end: limit ? day(end) : nil)
    }
}
#endif
