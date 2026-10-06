import OrgApp
import OrgCore
import SwiftUI

/// The inspector beside the editor: column view and clocked time for the open file, kept
/// current as it changes.
struct InspectorPane: View {
    let session: DocumentSession
    let commands: AppCommands
    @AppStorage("inspectorTab") private var tab = Tab.columns
    @AppStorage("inspectorColumnsScope") private var subtree = false
    @AppStorage("inspectorClockSpan") private var span = Span.week
    @State private var columns: ColumnView.View?
    @State private var clocked: [(start: Int, heading: String, minutes: Int)] = []

    enum Tab: String, CaseIterable { case columns = "Columns", clock = "Clock" }
    enum Span: String, CaseIterable { case today = "Today", week = "This Week", all = "All" }

    private struct Key: Equatable {
        var path: String?
        var version: Int
        var caret: Int?
        var subtree: Bool
        var span: Span
    }

    /// The heading at the caret, for a subtree's columns and the current row.
    private var heading: Int? { session.outline.last { $0.start <= commands.selection.location }?.start }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch tab {
            case .columns: columnsView
            case .clock: clockView
            }
        }
        .task(id: Key(path: session.path, version: session.editVersion, caret: subtree ? heading : nil, subtree: subtree, span: span)) { refresh() }
    }

    @ViewBuilder
    private var columnsView: some View {
        Picker("Scope", selection: $subtree) {
            Text("File").tag(false)
            Text("Subtree").tag(true)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        if let columns, !columns.rows.isEmpty {
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    GridRow {
                        ForEach(columns.specs.indices, id: \.self) { i in
                            Text(columns.specs[i].title).bold().foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    ForEach(columns.rows.indices, id: \.self) { r in
                        let row = columns.rows[r]
                        GridRow {
                            ForEach(columns.specs.indices, id: \.self) { i in
                                Text(columns.specs[i].property == "ITEM" ? String(repeating: "*", count: row.level) + " " + row.values[i] : row.values[i])
                                    .lineLimit(1)
                                    .fontWeight(row.start == heading ? .semibold : .regular)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { session.reveal(row.start) }
                    }
                }
                .font(.system(.callout, design: .monospaced))
                .padding(8)
            }
            .defaultScrollAnchor(.topLeading)
        } else {
            ContentUnavailableView("No entries", systemImage: "tablecells")
        }
    }

    @ViewBuilder
    private var clockView: some View {
        Picker("Span", selection: $span) {
            ForEach(Span.allCases, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        if clocked.isEmpty {
            ContentUnavailableView("No clocked time", systemImage: "clock")
        } else {
            List {
                ForEach(clocked, id: \.start) { entry in
                    HStack {
                        Text(entry.heading.isEmpty ? "(untitled)" : entry.heading).lineLimit(1)
                        Spacer()
                        Text(ClockReport.hours(entry.minutes)).monospacedDigit()
                    }
                    .fontWeight(entry.start == heading ? .semibold : .regular)
                    .contentShape(Rectangle())
                    .onTapGesture { session.reveal(entry.start) }
                }
                HStack {
                    Text("Total").bold()
                    Spacer()
                    Text(ClockReport.hours(clocked.reduce(0) { $0 + $1.minutes })).bold().monospacedDigit()
                }
            }
        }
    }

    private func refresh() {
        guard session.isOrg, let document = session.document else {
            columns = nil
            clocked = []
            return
        }
        let text = document.text
        columns = ColumnView.capture(text: text, tree: document.tree, at: heading ?? 0, global: !subtree || heading == nil).view
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        // Weeks start on Monday, as org's do.
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let today = Date()
        let from: Date? = switch span {
        case .today: today
        case .week: calendar.dateInterval(of: .weekOfYear, for: today)?.start
        case .all: nil
        }
        clocked = ClockReport.byHeading(ClockReport.entries(text), from: from.map(formatter.string), to: span == .all ? nil : formatter.string(from: today))
    }
}
