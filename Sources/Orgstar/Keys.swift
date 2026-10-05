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
                Divider()
                HStack(spacing: 6) {
                    Text(request.prompt.message).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                    TextField("", text: $answer)
                        .textFieldStyle(.plain)
                        .font(.system(.callout, design: .monospaced))
                        .focused($answerFocused)
                        .onSubmit { commands.answer(answer) }
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
                Divider()
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.bar)
        .task(id: commands.pendingKeys) {
            showingHints = false
            guard commands.pendingKeys != nil else { return }
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { showingHints = true }
        }
    }
}

/// M-x and ⇧⌘P: every command by title, with its keys.
struct PaletteView: View {
    let keymap: Keymap
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
                        if let keys = keymap.keys(for: command.id) {
                            Text(KeySequence.format(keys)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
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
