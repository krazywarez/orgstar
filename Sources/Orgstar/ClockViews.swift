import AppKit
import CoreGraphics
import OrgApp
import OrgCore
import OrgEditorAppKit
import SwiftUI

/// Elapsed time of the running clock, `H:MM`.
func clockElapsed(_ running: ClockModel.Running, now: Date) -> String {
    let minutes = max(0, Int(now.timeIntervalSince(running.startedAt) / 60))
    return String(format: "%d:%02d", minutes / 60, minutes % 60)
}

/// What the menu bar item shows.
struct ClockMenuState: Equatable {
    let running: ClockModel.Running?
    let history: [ClockTask]
}

/// `org-user-idle-seconds` on macOS: time since the last keyboard or mouse input anywhere.
enum ClockIdle {
    static func seconds() -> Double {
        // `kCGAnyInputEventType`.
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}

/// The clock history in a menu: clocking in to an entry runs `app.clock.history.N`.
struct RecentClocks: View {
    let clock: ClockModel
    let run: (String) -> Void

    var body: some View {
        if !clock.history.isEmpty {
            Section("Recent Entries") {
                ForEach(Array(clock.history.enumerated()), id: \.offset) { index, task in
                    Button(task.title) { run("app.clock.history.\(index)") }
                        .help("Clock in to \(task.title) in \((task.path as NSString).lastPathComponent)")
                }
            }
        }
    }
}

/// Org ▸ Clock: the clock commands, with their keys, and the recent entries.
struct ClockMenu: View {
    let commands: AppCommands
    let clock: ClockModel

    var body: some View {
        Menu("Clock") {
            ForEach(EditorCommands.all.filter { $0.id.hasPrefix("app.clock.") }, id: \.id) { command in
                Button {
                    commands.run(command.id)
                } label: {
                    Text(command.title)
                    if let keys = commands.keyLabel(for: command.id) { Text(keys) }
                }
            }
            RecentClocks(clock: clock) { commands.run($0) }
        }
    }
}

/// The menu bar item while a clock runs: elapsed time, and clock out, cancel and go to.
@MainActor
final class ClockStatusItem: NSObject {
    private var item: NSStatusItem?
    private var timer: Timer?
    private var running: ClockModel.Running?
    private let run: (String) -> Void

    init(run: @escaping (String) -> Void) {
        self.run = run
    }

    func update(_ running: ClockModel.Running?, recent: [String] = []) {
        self.running = running
        guard let running else {
            timer?.invalidate()
            timer = nil
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        if item == nil {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        let menu = NSMenu()
        menu.addItem(withTitle: running.heading, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        for (title, id) in [
            ("Clock Out", "app.clock.out"), ("Cancel Clock", "app.clock.cancel"), ("Go to Clocked Entry", "app.clock.goto"),
            ("Clock In to Recent Entry…", "app.clock.in-recent"), ("Clock Report", "app.clock.report"),
        ] {
            add(title, id, to: menu)
        }
        if !recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "Recent Entries"))
            for (index, title) in recent.enumerated() { add(title, "app.clock.history.\(index)", to: menu) }
        }
        item?.menu = menu
        refresh()
    }

    private func add(_ title: String, _ id: String, to menu: NSMenu) {
        let entry = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
        entry.target = self
        entry.representedObject = id
        menu.addItem(entry)
    }

    private func refresh() {
        guard let running else { return }
        item?.button?.title = "⏱ " + clockElapsed(running, now: Date())
    }

    @objc private func choose(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            NSApp.activate()
            run(id)
        }
    }
}

/// Clocked time per day and heading (`ClockReport.timeReport`) for chosen files and dates.
struct ClockReportView: View {
    let workspace: WorkspaceModel
    /// Open buffers are read as they are, unsaved edits included, as the agenda reads them.
    let session: DocumentSession
    @State private var start = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var end = Date()
    @State private var limit = false
    @State private var selected: Set<String> = []
    @State private var report = ""

    private var candidates: [FileEntry] { workspace.files.filter { $0.kind == .org } }

    var body: some View {
        HSplitView {
            List(candidates, selection: $selected) { file in
                Text(file.relativePath).tag(file.path)
            }
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("From", isOn: $limit)
                    DatePicker("", selection: $start, displayedComponents: .date).labelsHidden().disabled(!limit)
                    Text("to")
                    DatePicker("", selection: $end, displayedComponents: .date).labelsHidden().disabled(!limit)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                    }
                    Button("Save…", action: saveReport)
                }
                ScrollView([.horizontal, .vertical]) {
                    Text(report.isEmpty ? "Choose files with clocked time." : report)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(4)
                }
                .defaultScrollAnchor(.topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(12)
        }
        .navigationTitle("Clock Report")
        .onAppear {
            if selected.isEmpty {
                selected = Set(candidates.filter { text(of: $0.path)?.contains("CLOCK: [") ?? false }.map(\.path))
            }
            compute()
        }
        .onChange(of: selected) { compute() }
        .onChange(of: session.editVersion) { compute() }
        .onChange(of: session.dirtyPaths) { compute() }
        .onChange(of: start) { compute() }
        .onChange(of: end) { compute() }
        .onChange(of: limit) { compute() }
    }

    private func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// The file's text: its open buffer, else the file on disk.
    private func text(of path: String) -> String? {
        session.openTexts[path] ?? (try? String(contentsOfFile: path, encoding: .utf8))
    }

    private func compute() {
        var entries: [ClockReport.Entry] = []
        for path in selected.sorted() {
            guard let text = text(of: path) else { continue }
            entries += ClockReport.entries(text, settings: workspace.settings.org)
        }
        report = selected.isEmpty ? "" : ClockReport.timeReport(entries, start: limit ? day(start) : nil, end: limit ? day(end) : nil)
    }

    private func saveReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "time-report.org"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? report.write(to: url, atomically: true, encoding: .utf8)
    }
}
