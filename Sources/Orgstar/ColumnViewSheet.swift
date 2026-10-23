import OrgApp
import OrgCore
import SwiftUI

/// `org-columns`: one row per entry, one column per column-format field, with summaries.
/// Click a cell to select it; Return or a double-click edits it (`e`), `n` and `p` move to the
/// next or previous allowed value, and Go to Entry shows its heading.
struct ColumnViewSheet: View {
    @State var view: ColumnView.View
    /// Runs a command at a heading's start; the step tells what came of it.
    let run: (any OrgCommand, Int, [String: String]) -> CommandStep
    /// The document's text and tree now, to capture the view again and offer allowed values.
    let document: () -> (text: String, tree: OrgTree)?
    let jump: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: (row: Int, column: Int)?
    @State private var editing: (row: Int, column: Int)?
    @State private var draft = ""
    @State private var message: String?
    /// A question the edit asks (a state note), with the command to run again.
    @State private var pending: (prompt: Prompt, command: any OrgCommand, start: Int, answers: [String: String])?
    @State private var reply = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Column View").font(.headline)
                Spacer()
                Button("Go to Entry") {
                    guard let selected else { return }
                    jump(view.rows[selected.row].start)
                    dismiss()
                }
                .disabled(selected == nil)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                ColumnViewGrid(view: view, verticalSpacing: 4) { r, c in cellView(r, c) }
                .font(.system(.body, design: .monospaced))
                .padding(10)
            }
            .defaultScrollAnchor(.topLeading)
            if let pending {
                HStack {
                    Text(pending.prompt.message)
                    TextField("", text: $reply).onSubmit(answerPending)
                    Button("OK", action: answerPending)
                }
                .padding(8)
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary).padding(8)
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { press in key(press) }
    }

    private func cellView(_ r: Int, _ c: Int) -> some View {
        let row = view.rows[r]
        let isSelected = selected.map { $0 == (r, c) } ?? false
        return Group {
            if let editing, editing == (r, c) {
                editor(r, c)
            } else {
                Text(cell(row, c))
                    .lineLimit(1)
                    .frame(maxWidth: view.specs[c].width.map { CGFloat($0) * 8.5 }, alignment: .leading)
                    .padding(.horizontal, 2)
                    .background(isSelected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 3))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { startEditing(r, c) }
                    .onTapGesture {
                        selected = (r, c)
                        focused = true
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: "Edit") { startEditing(r, c) }
                    .accessibilityAction(named: "Go to Entry") {
                        jump(row.start)
                        dismiss()
                    }
            }
        }
    }

    /// A field for the value, with the allowed values in a menu.
    private func editor(_ r: Int, _ c: Int) -> some View {
        let spec = view.specs[c]
        let allowed = document().flatMap { PropertyValues.allowed(spec.property, at: view.rows[r].start, text: $0.text, tree: $0.tree)?.values } ?? []
        return HStack(spacing: 4) {
            TextField(spec.title, text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120)
                .onSubmit { commit(r, c, draft) }
                .onExitCommand { editing = nil }
            if !allowed.isEmpty {
                Menu {
                    ForEach(allowed, id: \.self) { value in Button(value.isEmpty ? "(none)" : value) { commit(r, c, value) } }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    /// ITEM with the heading's stars, as org shows it.
    private func cell(_ row: ColumnView.Row, _ i: Int) -> String {
        guard view.specs[i].property == "ITEM" else { return row.values[i] }
        return String(repeating: "*", count: row.level) + " " + row.values[i]
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard editing == nil, pending == nil else { return .ignored }
        guard let current = selected else {
            if [.downArrow, .upArrow, .leftArrow, .rightArrow].contains(press.key), !view.rows.isEmpty {
                selected = (0, 0)
                return .handled
            }
            return .ignored
        }
        switch press.key {
        case .downArrow: selected = (min(current.row + 1, view.rows.count - 1), current.column)
        case .upArrow: selected = (max(current.row - 1, 0), current.column)
        case .rightArrow: selected = (current.row, min(current.column + 1, view.specs.count - 1))
        case .leftArrow: selected = (current.row, max(current.column - 1, 0))
        case .return: startEditing(current.row, current.column)
        default:
            switch press.characters {
            case "e": startEditing(current.row, current.column)
            case "n", "p":
                let spec = view.specs[current.column]
                perform(NextColumnValue(property: spec.property, summary: spec.summary, previous: press.characters == "p"), row: current.row)
            default: return .ignored
            }
        }
        return .handled
    }

    private func startEditing(_ r: Int, _ c: Int) {
        selected = (r, c)
        let spec = view.specs[c]
        if ["CLOCKSUM", "CLOCKSUM_T", "ALLTAGS", "BLOCKED", "CLOSED", "FILE", "TIMESTAMP", "TIMESTAMP_IA"].contains(spec.property) {
            message = "This special column cannot be edited"
            return
        }
        let row = view.rows[r]
        draft = row.raw.indices.contains(c) ? row.raw[c] : row.values[c]
        editing = (r, c)
    }

    private func commit(_ r: Int, _ c: Int, _ value: String) {
        editing = nil
        perform(SetColumnValue(property: view.specs[c].property, value: value), row: r)
    }

    private func perform(_ command: any OrgCommand, row: Int, answers: [String: String] = [:]) {
        handle(run(command, view.rows[row].start, answers), command: command, start: view.rows[row].start, answers: answers)
    }

    private func handle(_ step: CommandStep, command: any OrgCommand, start: Int, answers: [String: String]) {
        switch step {
        case .commit:
            message = nil
            refresh()
        case .failed(let text):
            message = text
        case .prompt(let prompt):
            reply = prompt.initial ?? ""
            pending = (prompt, command, start, answers)
        default:
            message = "\(command.title) can't run here"
        }
        focused = true
    }

    private func answerPending() {
        guard let pending else { return }
        self.pending = nil
        let answers = pending.answers.merging([pending.prompt.key: reply]) { $1 }
        handle(run(pending.command, pending.start, answers), command: pending.command, start: pending.start, answers: answers)
    }

    /// The view again, over the same entries, keeping the selected cell.
    private func refresh() {
        guard let document = document(), let new = try? ColumnView.refresh(view, text: document.text, tree: document.tree) else { return }
        view = new
        if let selected, selected.row >= new.rows.count { self.selected = nil }
    }
}
