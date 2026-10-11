#if os(iOS)
import OrgApp
import OrgCore
import SwiftUI

/// `org-columns` on iOS: the entries and their columns, with summaries, as on the Mac. Tap a
/// cell to select it; the bar edits it (`e`), moves to the previous or next allowed value
/// (`p`, `n`), or goes to the entry.
struct ColumnViewScreen: View {
    @State var view: ColumnView.View
    let session: DocumentSession
    let path: String
    let jump: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: (row: Int, column: Int)?
    @State private var message: String?
    @State private var prompt: EditorScreen.PromptRequest?

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        ForEach(view.specs.indices, id: \.self) { i in
                            Text(view.specs[i].title).bold().foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    ForEach(view.rows.indices, id: \.self) { r in
                        GridRow {
                            ForEach(view.specs.indices, id: \.self) { c in cellView(r, c) }
                        }
                    }
                }
                .font(.system(.callout, design: .monospaced))
                .padding(12)
            }
            .defaultScrollAnchor(.topLeading)
            .navigationTitle("Column View")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Edit", systemImage: "pencil") { edit() }.disabled(selected == nil)
                    Button("Previous Value", systemImage: "chevron.up") { cycle(previous: true) }.disabled(selected == nil)
                    Button("Next Value", systemImage: "chevron.down") { cycle(previous: false) }.disabled(selected == nil)
                    Spacer()
                    Button("Go to Entry", systemImage: "arrow.right.doc.on.clipboard") {
                        guard let selected else { return }
                        jump(view.rows[selected.row].start)
                        dismiss()
                    }
                    .disabled(selected == nil)
                }
            }
            .safeAreaInset(edge: .top) {
                if let message {
                    Text(message).font(.footnote).padding(.horizontal, 12).padding(.vertical, 6)
                        .glassEffect(.regular, in: Capsule())
                        .onTapGesture { self.message = nil }
                }
            }
            .sheet(item: $prompt) { request in
                PromptSheet(prompt: request.prompt) { answer in
                    prompt = nil
                    request.reply(answer)
                }
            }
        }
    }

    private func cellView(_ r: Int, _ c: Int) -> some View {
        let row = view.rows[r]
        let isSelected = selected.map { $0 == (r, c) } ?? false
        let text = view.specs[c].property == "ITEM" ? String(repeating: "*", count: row.level) + " " + row.values[c] : row.values[c]
        return Text(text.isEmpty ? " " : text)
            .lineLimit(1)
            .frame(maxWidth: view.specs[c].width.map { CGFloat($0) * 8.5 }, alignment: .leading)
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .background(isSelected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture { selected = (r, c) }
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(named: "Edit") {
                selected = (r, c)
                edit()
            }
    }

    /// `org-columns-edit-value`: asks for the value, offering the allowed ones.
    private func edit() {
        guard let (r, c) = selected else { return }
        let spec = view.specs[c]
        let row = view.rows[r]
        if ["CLOCKSUM", "CLOCKSUM_T", "ALLTAGS", "BLOCKED", "CLOSED", "FILE", "TIMESTAMP", "TIMESTAMP_IA"].contains(spec.property) {
            message = "This special column cannot be edited"
            return
        }
        let allowed = session.document.flatMap { PropertyValues.allowed(spec.property, at: row.start, text: $0.text, tree: $0.tree)?.values } ?? []
        let initial = row.raw.indices.contains(c) ? row.raw[c] : row.values[c]
        // With allowed values the field starts empty, so that they all show.
        let message = allowed.isEmpty || initial.isEmpty ? spec.title : "\(spec.title) (now \(initial))"
        prompt = EditorScreen.PromptRequest(prompt: Prompt(key: "value", message: message, initial: allowed.isEmpty ? initial : "", choices: allowed)) { answer in
            guard let answer else { return }
            perform(SetColumnValue(property: spec.property, value: answer), at: row.start)
        }
    }

    private func cycle(previous: Bool) {
        guard let (r, c) = selected else { return }
        let spec = view.specs[c]
        perform(NextColumnValue(property: spec.property, summary: spec.summary, previous: previous), at: view.rows[r].start)
    }

    private func perform(_ command: any OrgCommand, at start: Int, answers: [String: String] = [:]) {
        switch session.perform(command, path: path, at: start, expect: nil, answers: answers) {
        case .commit:
            message = nil
            guard let document = session.document, let new = try? ColumnView.refresh(view, text: document.text, tree: document.tree) else { return }
            view = new
            if let selected, selected.row >= new.rows.count { self.selected = nil }
        case .failed(let text):
            message = text
        case .prompt(let request):
            // A state note, or what else the change asks.
            prompt = EditorScreen.PromptRequest(prompt: request) { answer in
                guard let answer else { return }
                perform(command, at: start, answers: answers.merging([request.key: answer]) { $1 })
            }
        case .external(let request):
            message = MobileEditor.unavailable(request, title: command.title)
        }
    }
}
#endif
