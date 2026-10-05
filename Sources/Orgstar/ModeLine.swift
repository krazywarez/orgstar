import OrgApp
import OrgCore
import OrgPresentation
import SwiftUI

/// The line under the editor: evil state, unsaved mark and the headings around the caret on
/// the left; the selection's counts, line and column, the file's words and anything unusual
/// about its encoding on the right.
struct ModeLine: View {
    let session: DocumentSession
    let commands: AppCommands
    @State private var words: Int?
    @State private var crlf = false

    var body: some View {
        let text = commands.editor?.document.text ?? ""
        let selection = commands.selection
        HStack(spacing: 10) {
            if let state = commands.editorState { StateTag(state: state) }
            if session.isDirty {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.secondary)
                    .help("Unsaved changes")
                    .accessibilityLabel("Unsaved changes")
            }
            breadcrumb(at: selection.location)
            Spacer(minLength: 12)
            if selection.length > 0, let region = region(text, selection) {
                Text("\(region.lines) \(region.lines == 1 ? "line" : "lines"), \(region.words) \(region.words == 1 ? "word" : "words"), \(region.characters) chars")
                    .help("Selection (count-words-region)")
            }
            let position = TextStats.position(in: text, at: selection.location + selection.length)
            Text("\(position.line):\(position.column)")
                .help("Line \(position.line), column \(position.column)")
            if let words {
                Text("\(words.formatted()) \(words == 1 ? "word" : "words")")
                    .help("Words in the file (count-words)")
            }
            ForEach(encodingNotes, id: \.self) { note in
                Text(note).foregroundStyle(.orange)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .monospacedDigit()
        .lineLimit(1)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .task(id: WordsKey(path: session.path, version: session.editVersion)) {
            guard let text = commands.editor?.document.text ?? session.document?.text else {
                words = nil
                return
            }
            (words, crlf) = await Task.detached(priority: .utility) { (TextStats.words(in: text), text.contains("\r\n")) }.value
        }
    }

    private struct WordsKey: Hashable {
        var path: String?
        var version: Int
    }

    /// The outline path of the heading containing `offset`, outermost first.
    @ViewBuilder
    private func breadcrumb(at offset: Int) -> some View {
        let path = outlinePath(at: offset)
        if !path.isEmpty {
            Text(path.joined(separator: " › "))
                .truncationMode(.head)
                .foregroundStyle(.primary)
                .help(path.joined(separator: " › "))
        }
    }

    private func outlinePath(at offset: Int) -> [String] {
        let outline = session.outline
        var path: [String] = []
        var current = outline.lastIndex { $0.start <= offset }
        while let i = current {
            path.insert(outline[i].title.isEmpty ? "(untitled)" : outline[i].title, at: 0)
            current = outline[i].parent
        }
        return path
    }

    private func region(_ text: String, _ range: NSRange) -> (lines: Int, words: Int, characters: Int)? {
        let ns = text as NSString
        guard NSMaxRange(range) <= ns.length else { return nil }
        return TextStats.region(ns.substring(with: range))
    }

    /// Only what differs from UTF-8 with LF endings.
    private var encodingNotes: [String] {
        guard let document = session.document else { return [] }
        var notes: [String] = []
        if session.isReadOnly { notes.append("Read-only") }
        if document.source.hasBOM { notes.append("BOM") }
        if crlf { notes.append("CRLF") }
        return notes
    }
}
