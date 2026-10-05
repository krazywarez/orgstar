import OrgApp
import OrgCore
import OrgEditorAppKit
import SwiftUI

struct KeyHint: Hashable {
    let key: String
    let title: String
}

/// The minibuffer line: a pending prefix, or the last message for a few seconds. After a
/// short pause on a prefix, the keys that can follow it.
struct EchoArea: View {
    let commands: AppCommands
    @Environment(\.orgTheme) private var theme
    @State private var showingHints = false
    @State private var answer = ""
    @FocusState private var answerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showingHints, commands.pendingKeys != nil, !commands.keyHints.isEmpty {
                Divider()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 4) {
                    ForEach(commands.keyHints, id: \.self) { hint in
                        HStack(spacing: 8) {
                            Text(hint.key).font(.system(.body, design: .monospaced)).foregroundStyle(.tint)
                            Text(hint.title).foregroundStyle(hint.title == "+prefix" ? .secondary : .primary).lineLimit(1)
                        }
                    }
                }
                .padding(10)
            }
            if let request = commands.prompt {
                if !request.prompt.choices.isEmpty {
                    Divider()
                    let matches = filteredChoices(request.prompt.choices)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(matches.prefix(12), id: \.self) { choice in
                                Button(choice) { commands.answer(choice) }
                                    .buttonStyle(.plain)
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(choice == matches.first ? .primary : .secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                    .frame(maxHeight: 200)
                }
                Divider()
                HStack(spacing: 6) {
                    Text(request.prompt.message).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                    TextField("", text: $answer)
                        .textFieldStyle(.plain)
                        .font(.system(.callout, design: .monospaced))
                        .focused($answerFocused)
                        .onSubmit {
                            if request.prompt.choices.isEmpty {
                                commands.answer(answer)
                            } else if let first = filteredChoices(request.prompt.choices).first {
                                commands.answer(first)
                            }
                        }
                        .onExitCommand { commands.answer(nil) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .onAppear {
                    answer = request.prompt.initial
                    answerFocused = true
                }
                .id(request.id)
            } else if let text = commands.pendingKeys.map({ $0 + "-" }) ?? commands.message {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(theme.color("modeline-foreground") ?? .primary)
        .background { if let bg = theme.color("modeline-background") { bg } else { Rectangle().fill(.bar) } }
        .task(id: commands.pendingKeys) {
            showingHints = false
            guard commands.pendingKeys != nil else { return }
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { showingHints = true }
        }
    }
}

/// The evil state, as Doom's modeline shows it.
struct StateTag: View {
    let state: String
    @Environment(\.orgTheme) private var theme

    var body: some View {
        Text(label)
            .font(.system(.caption, design: .monospaced).bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color, in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel("\(label.capitalized) state")
    }

    private var label: String {
        switch state {
        case "visual-line": "V-LINE"
        default: state.uppercased()
        }
    }

    private var color: Color {
        switch state {
        case "insert": theme.color("state-insert") ?? .green
        case "visual", "visual-line": theme.color("state-visual") ?? .orange
        default: theme.color("state-normal") ?? .blue
        }
    }
}

extension EchoArea {
    /// Choices matching what's typed, best first.
    func filteredChoices(_ choices: [String]) -> [String] {
        guard !answer.isEmpty else { return choices }
        return choices.compactMap { choice in FuzzyMatch.score(answer, choice).map { (choice, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

/// M-x and ⇧⌘P: every command by title, with its keys.
struct PaletteView: View {
    let commands: AppCommands
    let run: (String) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var matches: [EditorCommand] {
        let scored: [(command: EditorCommand, score: Int)] = EditorCommands.all.filter(\.inPalette).compactMap { command in
            guard let score = FuzzyMatch.score(query, command.title) else { return nil }
            return (command, score)
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.command.title < $1.command.title }.map(\.command)
    }

    var body: some View {
        let matches = matches
        VStack(spacing: 0) {
            TextField("Run command", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .onSubmit { if let first = matches.first { run(first.id) } }
            Divider()
            List(matches, id: \.id) { command in
                Button {
                    run(command.id)
                } label: {
                    HStack {
                        Text(command.title)
                        Spacer()
                        if let keys = commands.keyLabel(for: command.id) {
                            Text(keys).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 520, height: 360)
        .onExitCommand { dismiss() }
    }
}
