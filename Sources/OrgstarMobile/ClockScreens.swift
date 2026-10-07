#if os(iOS)
import OrgApp
import OrgCore
import SwiftUI

/// The running clock over the tab bar: the entry and time so far, and clocking out.
struct ClockAccessory: View {
    let running: ClockModel.Running
    let perform: (String) -> Void

    var body: some View {
        Menu {
            Button("Clock Out", systemImage: "stop.circle") { perform("app.clock.out") }
            Button("Cancel Clock", systemImage: "xmark.circle") { perform("app.clock.cancel") }
            Button("Go to Clocked Entry", systemImage: "arrow.right.circle") { perform("app.clock.goto") }
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
    func clockAccessory(_ running: ClockModel.Running?, perform: @escaping (String) -> Void) -> some View {
        if #available(iOS 26.1, *) {
            tabViewBottomAccessory(isEnabled: running != nil) {
                if let running { ClockAccessory(running: running, perform: perform) }
            }
        } else {
            safeAreaInset(edge: .bottom) {
                if let running { ClockAccessory(running: running, perform: perform).padding(.vertical, 8).background(.bar) }
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
