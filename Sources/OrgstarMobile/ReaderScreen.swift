#if os(iOS)
import OrgApp
import OrgCore
import OrgIndex
import OrgPresentation
import SwiftUI

/// What to read: a file, and where in it.
enum ReaderRoute: Hashable {
    case file(String)
    case offset(String, Int)
    /// A search result, found again if the file changed since it was indexed.
    case heading(HeadingLocation)
}

/// A file to read: headings that fold and unfold with a tap, as TAB cycles them, text styled as
/// in the editor, and links to follow.
struct ReaderScreen: View {
    let route: ReaderRoute
    let workspace: WorkspaceModel
    let session: DocumentSession
    @State private var fold = FoldState()
    @State private var folded: [Range<Int>] = []
    @State private var loadedPath: String?
    @State private var showingOutline = false
    @State private var message: String?
    @Environment(\.openURL) private var openURL

    private var outline: [OutlineEntry] { session.outline }

    var body: some View {
        let _ = session.editVersion
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let tree = session.document?.tree {
                        let preambleEnd = outline.first?.start ?? (tree.text as NSString).length
                        if preambleEnd > 0 { textView(tree, 0..<preambleEnd) }
                        ForEach(Array(outline.enumerated()), id: \.element.start) { index, entry in
                            if isShown(index) {
                                heading(tree, entry).id(entry.start)
                                if !fold.folds.contains(entry.start), !fold.bodyFolds.contains(entry.start) {
                                    let body = bodyRange(index, tree)
                                    if !body.isEmpty { textView(tree, body).padding(.leading, indent(entry)) }
                                }
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.revealRequest?.id) {
                guard let offset = session.revealRequest?.offset else { return }
                reveal(offset, proxy)
            }
        }
        .navigationTitle(((session.path ?? "") as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Outline", systemImage: "list.bullet.indent") { showingOutline = true }.disabled(outline.isEmpty)
            }
        }
        .sheet(isPresented: $showingOutline) { outlineSheet }
        .safeAreaInset(edge: .bottom) {
            if let message {
                Text(message).font(.callout).padding(8).frame(maxWidth: .infinity).background(.bar)
                    .onTapGesture { self.message = nil }
            }
        }
        .environment(\.openURL, OpenURLAction { url in follow(url) })
        .onAppear(perform: open)
        .onChange(of: session.path) { loadFolds() }
        .onChange(of: session.editVersion) { loadFolds() }
    }

    // MARK: - Content

    private func indent(_ entry: OutlineEntry) -> CGFloat { CGFloat(entry.level - 1) * 14 }

    /// Hidden under a folded ancestor.
    private func isShown(_ index: Int) -> Bool {
        var parent = outline[index].parent
        while let p = parent {
            if fold.folds.contains(outline[p].start) { return false }
            parent = outline[p].parent
        }
        return true
    }

    /// From after the heading line to the first child, or the section's end.
    private func bodyRange(_ index: Int, _ tree: OrgTree) -> Range<Int> {
        let entry = outline[index]
        let ns = tree.text as NSString
        let lineEnd = NSMaxRange(ns.lineRange(for: NSRange(location: entry.start, length: 0)))
        let firstChild = outline[(index + 1)...].first { $0.parent == index }?.start ?? entry.end
        return min(lineEnd, firstChild)..<firstChild
    }

    private func heading(_ tree: OrgTree, _ entry: OutlineEntry) -> some View {
        let ns = tree.text as NSString
        var line = ns.lineRange(for: NSRange(location: entry.start, length: 0))
        let title = min(entry.start + entry.level + 1, NSMaxRange(line))
        line.length = NSMaxRange(line) - title
        let text = attributed(ReadingText.segments(tree, in: title..<(title + line.length)), heading: entry.level)
        let hasContent = entry.end > NSMaxRange(ns.lineRange(for: NSRange(location: entry.start, length: 0)))
        let foldedMark = fold.folds.contains(entry.start) && hasContent
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: foldedMark ? "chevron.right" : "chevron.down")
                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                .opacity(hasContent ? 1 : 0)
            Text(text.trimmingTrailingNewlines()).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, indent(entry))
        .padding(.top, entry.level == 1 ? 6 : 0)
        .contentShape(Rectangle())
        .onTapGesture { fold = Presentation.cycle(entry.start, in: tree, fold) }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(foldedMark ? "Unfolds the heading" : "Folds the heading")
    }

    private func textView(_ tree: OrgTree, _ range: Range<Int>) -> some View {
        Text(attributed(ReadingText.segments(tree, in: range, folded: folded), heading: nil).trimmingTrailingNewlines())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Segments as styled text; links get `orgstar-link:` URLs to follow.
    private func attributed(_ segments: [ReadingText.Segment], heading level: Int?) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            var part = AttributedString(segment.text)
            if let level {
                part.font = level == 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .body.weight(.semibold)
            }
            for role in segment.roles {
                switch role {
                case .todo: part.foregroundColor = .red; part.font = (part.font ?? .body).weight(.semibold)
                case .done: part.foregroundColor = .green
                case .priority: part.foregroundColor = .orange
                case .tags: part.foregroundColor = .secondary; part.font = .caption
                case .bold: part.inlinePresentationIntent = .stronglyEmphasized
                case .italic: part.inlinePresentationIntent = .emphasized
                case .underline: part.underlineStyle = .single
                case .strikeThrough: part.strikethroughStyle = .single
                case .verbatim, .code, .inlineSource: part.font = .body.monospaced()
                case .markup, .leadingStars: part.foregroundColor = .secondary
                case .timestamp: part.foregroundColor = .purple
                case .metadata, .keyword, .comment, .blockDelimiter:
                    part.foregroundColor = .secondary
                    part.font = .footnote.monospaced()
                case .block, .table, .syntax: part.font = .callout.monospaced()
                default: break
                }
            }
            if segment.link != nil {
                // Found again by position when followed.
                part.link = URL(string: "orgstar-link:\(segment.offset)")
                part.foregroundColor = .accentColor
            }
            result += part
        }
        return result
    }

    // MARK: - Actions

    private func open() {
        switch route {
        case .file(let path): if session.path != path { session.open(path) }
        case .offset(let path, let offset):
            if session.path != path { session.open(path) }
            session.reveal(offset)
        case .heading(let location): session.show(location)
        }
        loadFolds()
    }

    /// The file's startup visibility, kept while the same file is open.
    private func loadFolds() {
        guard let tree = session.document?.tree else { return }
        folded = Presentation.startupWrappers(tree).map(\.hidden)
        guard loadedPath != session.path else { return }
        loadedPath = session.path
        fold = Presentation.applyVisibilityProperties(Presentation.startupFoldState(tree) ?? FoldState(), in: tree)
    }

    /// Unfolds the way to the heading containing `offset` and scrolls to it.
    private func reveal(_ offset: Int, _ proxy: ScrollViewProxy) {
        guard let index = outline.lastIndex(where: { $0.start <= offset }) else { return }
        var parent = outline[index].parent
        while let p = parent {
            fold.folds.remove(outline[p].start)
            parent = outline[p].parent
        }
        let start = outline[index].start
        DispatchQueue.main.async { withAnimation { proxy.scrollTo(start, anchor: .top) } }
    }

    private func follow(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme == "orgstar-link", let offset = Int(url.absoluteString.dropFirst("orgstar-link:".count)),
              let tree = session.document?.tree, let link = Links.link(at: offset, text: tree.text, tree: tree)?.link else {
            return .systemAction
        }
        switch session.follow(link, workspace: workspace, isText: { _ in false }) {
        case .shown: message = nil
        case .openExternally(let target): openURL(target)
        case .message(let text): message = text
        }
        return .handled
    }

    private var outlineSheet: some View {
        NavigationStack {
            List(outline, id: \.start) { entry in
                Button {
                    showingOutline = false
                    session.reveal(entry.start)
                } label: {
                    Text(entry.title.isEmpty ? "(untitled)" : entry.title)
                        .padding(.leading, indent(entry))
                        .foregroundStyle(.primary)
                }
            }
            .navigationTitle("Outline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showingOutline = false } } }
        }
    }
}

private extension AttributedString {
    /// Without the final newline, which `Text` would show as an empty line.
    func trimmingTrailingNewlines() -> AttributedString {
        var copy = self
        while let last = copy.characters.last, last.isNewline { copy.characters.removeLast() }
        return copy
    }
}
#endif
