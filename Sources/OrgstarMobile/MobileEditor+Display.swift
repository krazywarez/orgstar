#if os(iOS)
import OrgApp
import OrgCore
import OrgDocument
import OrgHighlight
import OrgPresentation
import UIKit

extension MobileEditor {
    // MARK: - Shrunk table columns

    /// C-c TAB in a table: `org-table-toggle-column-width`; `shrink` for `org-table-shrink`,
    /// `expand` for `org-table-expand`.
    func tableColumnWidth(_ id: String) {
        switch shrunk.change(for: id, at: textView.selectedRange.location, in: textView.textStorage.string) {
        case .notInTable: onMessage?("Not in a table")
        case .set(let columns, let table): setShrunk(columns, in: table)
        case .ask(let table, let current, let max):
            onPrompt?(Prompt(key: "columns", message: "Column ranges (e.g. 2-4 6-):")) { [weak self] answer in
                guard let self, let answer else { return }
                self.setShrunk(ShrunkColumns.toggled(current, TableShrink.columns(answer, max: max)), in: table)
            }
        }
    }

    /// Narrows `columns` of `table` and widens its others.
    private func setShrunk(_ columns: [Int], in table: Range<Int>) {
        shrunk.set(columns, in: table, text: textView.textStorage.string)
        restyle(table)
        invalidateLayout(lines: [table])
    }

    /// Hides each shrunk segment's text and draws its display where the text was, as pretty
    /// entities draw theirs.
    func applyShrunk(_ range: Range<Int>, in storage: NSTextStorage) {
        guard !shrunk.isEmpty else { return }
        let cell = theme.column
        for segment in shrunk.segments where segment.range.overlaps(range) && segment.range.upperBound <= storage.length {
            let r = segment.range
            let shown = segment.display.count
            let kept = min(shown, r.count)
            if r.count > kept { storage.addAttributes(theme.hidden, range: NSRange(location: r.lowerBound, length: r.count - kept)) }
            guard kept > 0 else { continue }
            let visible = NSRange(location: r.upperBound - kept, length: kept)
            let color = storage.attribute(.foregroundColor, at: visible.location, effectiveRange: nil) as? UIColor ?? theme.foreground
            storage.addAttribute(.foregroundColor, value: UIColor.clear, range: visible)
            storage.addAttributes([.orgEntityDisplay: segment.display, .orgEntityColor: color], range: NSRange(location: visible.location, length: 1))
            if shown > kept { storage.addAttribute(.kern, value: CGFloat(shown - kept) * cell, range: NSRange(location: NSMaxRange(visible) - 1, length: 1)) }
        }
    }

    // MARK: - Inline images

    func toggleImages() {
        showsImages.toggle()
        restyleAll()
        if showsImages {
            let ns = textView.textStorage.string as NSString
            var count = 0
            var offset = 0
            while offset < ns.length {
                let line = ns.lineRange(for: NSRange(location: offset, length: 0))
                if let image = InlineImages.image(atLine: line.location, in: ns, remote: options.remoteInlineImages != "skip", attachment: attachment),
                   loadImage(image.path) != nil { count += 1 }
                offset = NSMaxRange(line)
            }
            onMessage?("\(count) images displayed inline")
        } else {
            onMessage?("Inline image display turned off")
        }
    }

    /// `attachment:` links' files, for inline images.
    private var attachment: ((String, Int) -> String?)? {
        guard let attachmentPath else { return nil }
        let tree = document.tree
        return { attachmentPath($0, $1, tree) }
    }

    /// An image link's image here: remote ones as `org-display-remote-inline-images` says,
    /// restyled when they come.
    func loadImage(_ path: String) -> UIImage? {
        Self.loadImage(path, relativeTo: baseDirectory, remote: RemoteImages.Mode(rawValue: options.remoteInlineImages) ?? .skip) { [weak self] in
            guard let self, self.showsImages else { return }
            self.restyleAll()
        }
    }

    /// An image link's image, by its path or one relative to `baseDirectory`; an http(s)
    /// link's when `remote` allows it and it has come, `loaded` running when it does.
    static func loadImage(_ path: String, relativeTo baseDirectory: URL?, remote: RemoteImages.Mode = .skip, loaded: @escaping @MainActor () -> Void = {}) -> UIImage? {
        if path.contains("://") {
            guard let url = URL(string: path) else { return nil }
            return RemoteImages.shared.data(for: url, mode: remote, loaded: loaded).flatMap(UIImage.init(data:))
        }
        let expanded = (path as NSString).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded)
        } else if let baseDirectory {
            url = baseDirectory.appendingPathComponent(expanded)
        } else {
            return nil
        }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(modified)" as NSString
        if let cached = Self.imageCache.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        Self.imageCache.setObject(image, forKey: key)
        return image
    }

    /// Image lines in `range` show the image over the link, which is hidden unless the caret is
    /// on the line; then the image goes under it.
    func applyImages(_ range: Range<Int>, in storage: NSTextStorage, revealed: NSRange) {
        guard showsImages else { return }
        let text = storage.string as NSString
        let inset = textView.textContainerInset
        let maxWidth = max(80, textView.bounds.width - inset.left - inset.right - 40)
        var location = range.lowerBound
        while location < range.upperBound, location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(line)
            guard let image = InlineImages.image(atLine: line.location, in: text, remote: options.remoteInlineImages != "skip", attachment: attachment),
                  let picture = loadImage(image.path) else { continue }
            let width = min(image.width.map(CGFloat.init) ?? picture.size.width, maxWidth)
            let height = picture.size.width > 0 ? width * picture.size.height / picture.size.width : 0
            let content = NSRange(location: line.location, length: line.length - (text.substring(with: line).hasSuffix("\n") ? 1 : 0))
            // Invisible, keeping the line's height.
            let shown = line.location == revealed.location && content.length > 0
            if !shown, content.length > 0 {
                storage.addAttributes([.foregroundColor: UIColor.clear, .underlineStyle: 0], range: content)
            }
            storage.addAttribute(.orgImage, value: InlineImageBox(image: picture, size: CGSize(width: width, height: height), below: shown), range: NSRange(location: line.location, length: max(1, content.length)))
            let style = (storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            // The image sits where the line is, or under it while the link shows; the spacing
            // makes room for the rest of it.
            style.paragraphSpacing = shown ? height + 4 : max(0, height + 4 - theme.font.lineHeight)
            storage.addAttribute(.paragraphStyle, value: style, range: line)
        }
    }

    // MARK: - Truncation

    /// `toggle-truncate-lines`: long lines run off the right edge, scrolling sideways, instead
    /// of wrapping.
    var truncatesLines: Bool {
        get { (textView as? KeyedTextView)?.truncates ?? false }
        set {
            guard newValue != truncatesLines else { return }
            keepingTopLine {
                for case let view as KeyedTextView in textViews { view.truncates = newValue }
                for manager in layoutManagers { manager.invalidateLayout(for: manager.documentRange) }
            }
        }
    }

    // MARK: - Folding

    func setFolds(_ state: FoldState) {
        fold = state
        updateHidden()
    }

    func updateHidden() {
        let tree = document.tree
        let wrappers = fold.wrapperFolds.compactMap { Wrappers.starting(at: $0, in: tree)?.hidden }
        let before = hidden.folded
        let oldHidden = hidden.all
        hidden.set(
            Presentation.hiddenRanges(tree, folds: fold.folds, bodyFolds: fold.bodyFolds, wrapperRanges: wrappers),
            folded: fold.folds.union(fold.bodyFolds).union(fold.wrapperFolds)
        )
        // Lines that gain or lose their `…` are made again: TextKit keeps a shown line's fragment.
        let storage = textView.textStorage
        let changed = before.symmetricDifference(hidden.folded).filter { $0 < storage.length }
        if !changed.isEmpty {
            let text = storage.string as NSString
            storage.beginEditing()
            for start in changed { storage.edited(.editedAttributes, range: text.lineRange(for: NSRange(location: start, length: 0)), changeInLength: 0) }
            storage.endEditing()
        }
        invalidateLayout(lines: Array(Set(oldHidden).symmetricDifference(hidden.all)))
        textView.setNeedsDisplay()
    }

    /// TAB at the caret: a heading cycles, a drawer or block opens or closes.
    @discardableResult
    func cycleAtCaret() -> Bool {
        guard let next = Presentation.cycle(at: textView.selectedRange.location, in: document.tree, fold) else { return false }
        setFolds(next)
        return true
    }

    /// Shift-TAB: overview, contents, show all.
    func cycleGlobal() {
        let (visibility, state) = Presentation.cycleGlobal(from: globalVisibility, in: document.tree, wrapperFolds: fold.wrapperFolds)
        globalVisibility = visibility
        setFolds(state)
    }

    /// Opens the folds hiding `offset`.
    func unfold(around offset: Int) {
        var state = fold
        for entry in Presentation.outline(document.tree) where entry.start < offset && offset < entry.end {
            state.folds.remove(entry.start)
            state.bodyFolds.remove(entry.start)
        }
        for start in state.wrapperFolds where Wrappers.starting(at: start, in: document.tree)?.hidden.contains(offset) == true {
            state.wrapperFolds.remove(start)
        }
        if state != fold { setFolds(state) }
    }

    /// Shows the heading at `offset`, unfolded, at the top.
    func reveal(_ offset: Int) {
        let length = textView.textStorage.length
        let target = min(max(0, offset), length)
        unfold(around: target)
        textView.selectedRange = NSRange(location: target, length: 0)
        textView.scrollRangeToVisible(NSRange(location: target, length: 0))
    }

    /// The caret in hidden text: an arrow key moving forward into a fold jumps past it and
    /// moving back jumps to the end of the heading line, as on the Mac; a tap past a fold
    /// opens it.
    func selectionChanged() {
        let interval = Perf.begin("editor.selection")
        defer { interval.end() }
        redrawSelectedBlocks()
        let caret = textView.selectedRange.location
        defer {
            previousCaret = textView.selectedRange.location
            movedByArrow = false
        }
        if let range = hidden.containing(caret) {
            if movedByArrow, textView.selectedRange.length == 0 {
                textView.selectedRange = NSRange(location: caret >= previousCaret ? range.upperBound : range.lowerBound - 1, length: 0)
            } else {
                unfold(around: caret)
            }
        }
        revealCaretLine()
    }
}
#endif
