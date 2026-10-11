#if os(iOS)
import OrgApp
import OrgCore
import OrgDocument
import OrgIndex
import OrgPresentation
import SwiftUI
import UIKit

/// What to read: a file, and where in it.
enum ReaderRoute: Hashable {
    case file(String)
    case offset(String, Int)
    /// A search result, found again if the file changed since it was indexed.
    case heading(HeadingLocation)
}

/// Editing a file, from the reader.
struct EditorRoute: Hashable {
    let path: String
    let offset: Int?
}

/// A file to read: headings that fold and unfold with a tap, as TAB cycles them, text styled as
/// in the editor, and links to follow.
struct ReaderScreen: View {
    let route: ReaderRoute
    let workspace: WorkspaceModel
    let session: DocumentSession
    @State private var fold = FoldState()
    @State private var folded: [Range<Int>] = []
    /// Drawers and blocks the file opens with folded, which fold and unfold from their first line.
    @State private var foldable: [Range<Int>] = []
    @State private var loadedPath: String?
    /// The file's display: indentation, leading stars, inline images, truncation.
    @State private var startup: StartupDisplay?
    @State private var showingOutline = false
    @State private var message: String?
    /// The pane the reader shows its file in, closed with the reader.
    @State private var holder = PaneHolder()
    @Environment(\.openURL) private var openURL
    @Environment(MobileModel.self) private var model

    private var pane: EditorPane? { holder.pane }
    private var outline: [OutlineEntry] { pane?.outline ?? [] }
    /// The file the reader's pane shows.
    private var shownPath: String? { pane?.path }
    private var document: DocumentState? { shownPath.flatMap(session.document(of:)) }

    /// The file this reader shows.
    private var path: String {
        switch route {
        case .file(let path), .offset(let path, _): path
        case .heading(let location): location.path
        }
    }

    /// The pane shows this reader's file; the session opens files by their resolved paths.
    private var showsOwnFile: Bool {
        guard let current = shownPath else { return false }
        return current == path || current == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    var body: some View {
        let _ = pane?.editVersion
        // Read again when settings or the Dynamic Type size change.
        let _ = model.settingsVersion
        let theme = MobileTheme(model.theme)
        let truncated = startup?.truncated ?? false
        ScrollViewReader { proxy in
            ScrollView(truncated ? [.vertical, .horizontal] : .vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let tree = document?.tree, showsOwnFile {
                        let length = (tree.text as NSString).length
                        let preambleEnd = min(outline.first?.start ?? length, length)
                        if preambleEnd > 0 { textView(tree, 0..<preambleEnd, theme) }
                        ForEach(Array(outline.enumerated()), id: \.element.start) { index, entry in
                            // While another file opens, rows can update with the last file's
                            // entries for a moment; those don't fit this text.
                            if index < outline.count, outline[index] == entry, entry.end <= length, isShown(index) {
                                heading(tree, entry, theme).id(entry.start)
                                if !fold.folds.contains(entry.start), !fold.bodyFolds.contains(entry.start) {
                                    let body = bodyRange(index, tree)
                                    if !body.isEmpty { textView(tree, body, theme).padding(.leading, bodyIndent(entry, theme)) }
                                }
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: truncated ? nil : .infinity, alignment: .leading)
            }
            // Narrower than the view while truncated, the text still starts at the top left.
            .defaultScrollAnchor(truncated ? .topLeading : nil)
            .background(theme.swiftColor("background") ?? Color(uiColor: .systemBackground))
            .onChange(of: pane?.revealRequest?.id) {
                guard let offset = pane?.revealRequest?.offset else { return }
                reveal(offset, proxy)
            }
        }
        .navigationTitle(((shownPath ?? "") as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Outline", systemImage: "list.bullet.indent") { showingOutline = true }.disabled(outline.isEmpty)
                if let path = shownPath {
                    if let text = document?.text { ExportMenu(path: path, text: text) { message = $0 } }
                    NavigationLink(value: EditorRoute(path: path, offset: nil)) { Label("Edit", systemImage: "square.and.pencil") }
                }
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
        .onChange(of: pane?.path) { loadFolds() }
        .onChange(of: pane?.editVersion) { loadFolds() }
        .onChange(of: model.settingsVersion) { loadFolds() }
    }

    // MARK: - Content

    private func indent(_ entry: OutlineEntry) -> CGFloat { CGFloat(entry.level - 1) * 14 }

    private var indented: Bool { startup?.indented ?? true }

    /// The text as the editor's display settings show it.
    private var display: ReadingText.Display {
        ReadingText.Display(showMarkup: model.showMarkup, options: session.options, highlighter: MobileEditor.highlighter)
    }

    /// org-indent: a heading's text and its body start past its stars, at level + 1 columns,
    /// the fold mark standing where the last star and its space would. Without it nothing is
    /// indented and the stars show.
    private func headingIndent(_ entry: OutlineEntry, _ theme: MobileTheme) -> CGFloat {
        indented ? CGFloat(entry.level - 1) * theme.column : 0
    }

    private func bodyIndent(_ entry: OutlineEntry, _ theme: MobileTheme) -> CGFloat {
        indented ? CGFloat(entry.level + 1) * theme.column : 0
    }

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

    private func heading(_ tree: OrgTree, _ entry: OutlineEntry, _ theme: MobileTheme) -> some View {
        let ns = tree.text as NSString
        let line = ns.lineRange(for: NSRange(location: entry.start, length: 0))
        let start = indented ? min(entry.start + entry.level + 1, NSMaxRange(line)) : entry.start
        let text = attributed(ReadingText.segments(tree, in: start..<NSMaxRange(line), display: display), heading: entry.level, theme)
        let hasContent = entry.end > NSMaxRange(line)
        let foldedMark = fold.folds.contains(entry.start) && hasContent
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Image(systemName: foldedMark ? "chevron.right" : "chevron.down")
                .font(.caption.weight(.semibold)).foregroundStyle(theme.swiftColor("markup") ?? Color(uiColor: .tertiaryLabel))
                .opacity(hasContent ? 1 : 0)
                .frame(width: 2 * theme.column, alignment: .leading)
            lineText(text.trimmingTrailingNewlines(), theme)
        }
        .padding(.leading, headingIndent(entry, theme))
        .padding(.top, entry.level == 1 ? 6 : 0)
        .contentShape(Rectangle())
        .onTapGesture { fold = Presentation.cycle(entry.start, in: tree, fold) }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(foldedMark ? "Unfolds the heading" : "Folds the heading")
    }

    private func textView(_ tree: OrgTree, _ range: Range<Int>, _ theme: MobileTheme) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(parts(tree, range), id: \.range.lowerBound) { part in
                if let image = part.image {
                    Image(uiImage: image.picture).resizable().scaledToFit()
                        .frame(maxWidth: image.width.map { CGFloat($0) } ?? image.picture.size.width, alignment: .leading)
                        .accessibilityLabel((image.path as NSString).lastPathComponent)
                } else {
                    lineText(attributed(ReadingText.segments(tree, in: part.range, folded: folded, open: foldable.filter { !folded.contains($0) }, display: display), heading: nil, theme).trimmingTrailingNewlines(), theme)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// Wrapped to the view's width, or on one line each, scrolling sideways, while truncated.
    private func lineText(_ text: AttributedString, _ theme: MobileTheme) -> some View {
        Text(text)
            .lineSpacing(CGFloat(max(0, theme.spec.lineSpacing)))
            .fixedSize(horizontal: startup?.truncated ?? false, vertical: false)
            .frame(maxWidth: startup?.truncated == true ? nil : .infinity, alignment: .leading)
    }

    private struct Part {
        let range: Range<Int>
        var image: (picture: UIImage, path: String, width: Int?)?
    }

    /// Text, and with inline images on, lines that are only an image link shown as the image.
    private func parts(_ tree: OrgTree, _ range: Range<Int>) -> [Part] {
        guard startup?.inlineImages == true, let path = shownPath else { return [Part(range: range)] }
        // Read so that the view draws again when a remote image arrives.
        _ = RemoteImages.shared.version
        let remote = RemoteImages.Mode(rawValue: session.options.remoteInlineImages) ?? .skip
        let base = URL(fileURLWithPath: path).deletingLastPathComponent()
        let ns = tree.text as NSString
        var parts: [Part] = []
        var textStart = range.lowerBound
        var location = range.lowerBound
        while location < range.upperBound {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(line)
            guard folded.allSatisfy({ !$0.contains(line.location) }), let image = InlineImages.image(atLine: line.location, in: ns, remote: remote != .skip),
                  let picture = MobileEditor.loadImage(image.path, relativeTo: base, remote: remote) else { continue }
            if textStart < line.location { parts.append(Part(range: textStart..<line.location)) }
            parts.append(Part(range: line.location..<min(NSMaxRange(line), range.upperBound), image: (picture, image.path, image.width)))
            textStart = min(NSMaxRange(line), range.upperBound)
        }
        if textStart < range.upperBound { parts.append(Part(range: textStart..<range.upperBound)) }
        return parts
    }

    /// Segments as styled text in the theme's font and colors, as the editor styles them;
    /// links get `orgstar-link:` URLs to follow.
    private func attributed(_ segments: [ReadingText.Segment], heading level: Int?, _ theme: MobileTheme) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            var part = AttributedString(segment.text)
            var font = level.map(theme.headingFont) ?? theme.font
            var color = level.flatMap { theme.color("heading-\(min(max($0, 1), 8))") } ?? theme.foreground
            func fg(_ key: String) { if let c = theme.color(key) { color = c } }
            // Outer roles first, so inner ones win.
            for role in segment.roles.sorted(by: { Self.depth($0) < Self.depth($1) }) {
                switch role {
                case .todo, .done:
                    font = MobileTheme.adding(.traitBold, to: font)
                    if let c = theme.keywordColor(segment.text, done: role == .done) { color = c }
                case .priority: fg("priority")
                case .tags: fg("tags")
                case .bold: font = MobileTheme.adding(.traitBold, to: font)
                case .italic: font = MobileTheme.adding(.traitItalic, to: font)
                case .underline: part.underlineStyle = .single
                case .strikeThrough: part.strikethroughStyle = .single
                case .verbatim, .code, .inlineSource:
                    if let background = theme.color("inline-background") { part.backgroundColor = Color(uiColor: background) }
                    fg(role == .verbatim ? "verbatim" : "code")
                case .markup, .linkMarkup: fg("markup")
                case .leadingStars:
                    // As the editor hides them; shown in the heading's color unless hidden.
                    if !Presentation.skipsLeadingStars(role, indented: indented, hideStars: startup?.hideStars ?? false) { color = .clear }
                case .syntax(let category): if let key = category.themeKey { fg(key) }
                case .timestamp: fg("timestamp")
                case .comment: fg("comment")
                case .keyword: fg("keyword")
                case .metadata: fg("metadata")
                case .blockDelimiter: fg("block-delimiter")
                case .footnote, .cookie, .target, .macro, .latex: fg("special")
                case .table, .rule: fg("table")
                case .link:
                    part.underlineStyle = .single
                    fg("link")
                case .heading, .block: break
                }
            }
            if segment.link != nil {
                // Found again by position when followed.
                part.link = URL(string: "orgstar-link:\(segment.offset)")
            }
            if let start = segment.toggles { part.link = URL(string: "orgstar-fold:\(start)") }
            if let superscript = segment.superscript {
                // Raised or lowered as the editor draws `org-pretty-entities` scripts.
                part.baselineOffset = (superscript ? 0.3 : -0.3) * font.pointSize
                font = font.withSize(font.pointSize * 0.7)
            }
            part.font = Font(font as CTFont)
            part.foregroundColor = Color(uiColor: color)
            result += part
        }
        return result
    }

    /// How deep a role's text usually nests: elements, then objects, then their parts.
    private static func depth(_ role: StyleRole) -> Int {
        switch role {
        case .heading: 0
        case .metadata, .keyword, .comment, .block, .table, .rule: 1
        case .blockDelimiter, .link, .bold, .italic, .underline, .strikeThrough, .timestamp, .footnote, .target, .macro, .latex: 2
        default: 3
        }
    }

    // MARK: - Actions

    private func open() {
        let pane = holder.pane ?? {
            let made = session.makePane()
            holder.pane = made
            holder.release = { [weak session] in session?.closePane(made) }
            return made
        }()
        // What the reader opens and follows goes to its pane.
        session.focused = pane
        if loadedPath == nil {
            switch route {
            case .file(let path): session.open(path, in: pane)
            case .offset(let path, let offset):
                session.open(path, in: pane)
                session.reveal(offset, in: pane)
            case .heading(let location): session.show(location)
            }
        }
        loadFolds()
    }

    /// The file's startup display, as the editor opens it; its heading folds are kept while
    /// the same file is open.
    private func loadFolds() {
        guard let tree = document?.tree, showsOwnFile else { return }
        let display = Presentation.startupDisplay(tree, options: session.options)
        startup = display
        folded = display.wrappers.map(\.hidden)
        foldable = folded
        guard loadedPath != shownPath else { return }
        loadedPath = shownPath
        fold = display.folds
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
        if url.scheme == "orgstar-fold", let start = Int(url.absoluteString.dropFirst("orgstar-fold:".count)) {
            if folded.contains(where: { $0.lowerBound == start }) {
                folded.removeAll { $0.lowerBound == start }
            } else if let range = foldable.first(where: { $0.lowerBound == start }) {
                folded.append(range)
            }
            return .handled
        }
        guard url.scheme == "orgstar-link", let offset = Int(url.absoluteString.dropFirst("orgstar-link:".count)),
              let tree = document?.tree, let link = Links.link(at: offset, text: tree.text, tree: tree)?.link else {
            return .systemAction
        }
        if let pane { session.focused = pane }
        switch session.follow(link, workspace: workspace, isText: { _ in false }) {
        case .shown:
            message = nil
            // A link to another file shows it on its own screen; this pane keeps its file.
            if let pane, let target = pane.path, target != path, !showsOwnFile {
                let caret = session.caret(of: target) ?? 0
                session.open(path, in: pane)
                model.openRequest = .offset(target, caret)
            }
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
                    if let pane { session.reveal(entry.start, in: pane) }
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
