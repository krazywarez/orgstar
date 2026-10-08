import OrgCore
import OrgPresentation
import SwiftUI

/// Fast TODO and tag selection in the echo area: each option with its key. TODO keywords take
/// one key; tags toggle until Return, Tab types a tag, Escape or C-g quits.
struct FastSelectionView: View {
    let selection: FastSelection
    let message: String
    let answer: (String?) -> Void
    @Environment(\.orgTheme) private var theme
    @State private var inputs: [FastSelection.Input] = []
    @State private var typing = false
    @State private var typed = ""
    @FocusState private var focused: Bool
    @FocusState private var typingFocused: Bool

    var body: some View {
        let current = selection.multiple ? selection.tags(after: inputs) ?? [] : []
        VStack(alignment: .leading, spacing: 6) {
            if selection.multiple {
                if !selection.inherited.isEmpty { line("Inherited:", selection.inherited) }
                line("Current:", current)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 14) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        switch cell {
                        case .text(let text):
                            Text(text).foregroundStyle(.secondary)
                        case .label(let text):
                            Text(text).bold()
                        case .option(let key, let name):
                            HStack(spacing: 4) {
                                Text("[\(String(key))]").foregroundStyle(.tint)
                                Text(name)
                                    .fontWeight(current.contains(name) ? .bold : .regular)
                                    .foregroundStyle(current.contains(name) ? theme.color("todo") ?? .primary : .primary)
                            }
                        }
                    }
                }
            }
            if typing {
                HStack(spacing: 6) {
                    Text("Tag:").foregroundStyle(.secondary)
                    TextField("", text: $typed)
                        .textFieldStyle(.plain)
                        .focused($typingFocused)
                        .onSubmit {
                            inputs.append(.typed(typed))
                            typed = ""
                            typing = false
                            focused = true
                        }
                        .onExitCommand {
                            typing = false
                            focused = true
                        }
                }
            }
            Text(message).foregroundStyle(.secondary)
        }
        .font(.system(.callout, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down, action: press)
        .onAppear { focused = true }
        .onChange(of: typing) { _, now in if now { typingFocused = true } }
    }

    private func line(_ label: String, _ tags: [String]) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Text(tags.isEmpty ? "" : ":" + tags.joined(separator: ":") + ":")
        }
    }

    private func press(_ key: KeyPress) -> KeyPress.Result {
        guard !typing else { return .ignored }
        if key.key == .escape || (key.modifiers.contains(.control) && key.characters == "g") {
            answer(nil)
            return .handled
        }
        if selection.multiple {
            if key.key == .return {
                answer(FastSelection.encode(inputs))
            } else if key.key == .tab {
                typing = true
            } else if let c = key.characters.first, key.characters.count == 1 {
                if c == "q", !selection.options.contains(where: { $0.key == "q" }) {
                    answer(nil)
                } else {
                    inputs.append(.key(c))
                }
            } else {
                return .ignored
            }
            return .handled
        }
        guard let c = key.characters.first, key.characters.count == 1 else { return .ignored }
        answer(String(c))
        return .handled
    }

    private enum Cell {
        case text(String)
        case label(String)
        case option(Character, String)
    }

    /// Options in rows, braces and brackets around groups, as org lays them out.
    private var rows: [[Cell]] {
        var rows: [[Cell]] = [[]]
        func newRow() { if !(rows.last?.isEmpty ?? true) { rows.append([]) } }
        for item in selection.items {
            switch item {
            case .startGroup: newRow(); rows[rows.count - 1].append(.text("{"))
            case .endGroup: rows[rows.count - 1].append(.text("}")); newRow()
            case .startTagGroup: newRow(); rows[rows.count - 1].append(.text("["))
            case .endTagGroup: rows[rows.count - 1].append(.text("]")); newRow()
            case .groupTags: rows[rows.count - 1].append(.text(":"))
            case .newline: newRow()
            case .label(let text): newRow(); rows[rows.count - 1].append(.label(text)); newRow()
            case .option(let key, let name): rows[rows.count - 1].append(.option(key, name))
            }
        }
        return rows.filter { !$0.isEmpty }
    }
}
