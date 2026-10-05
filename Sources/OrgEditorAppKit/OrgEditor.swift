#if os(macOS)
import AppKit
import OrgCore
import OrgDocument
import OrgPresentation

/// Hidden ranges, read by TextKit's enumeration callbacks, which may run off the main thread.
final class HiddenRanges: @unchecked Sendable {
    private let lock = NSLock()
    private var ranges: [Range<Int>] = []

    func set(_ new: [Range<Int>]) {
        lock.withLock { ranges = new }
    }

    var all: [Range<Int>] {
        lock.withLock { ranges }
    }

    func covers(_ start: Int, _ end: Int) -> Bool {
        lock.withLock { ranges.contains { $0.lowerBound <= start && end <= $0.upperBound } }
    }

    func containing(_ offset: Int) -> Range<Int>? {
        lock.withLock { ranges.first { $0.lowerBound <= offset && offset < $0.upperBound } }
    }
}

/// Folded heading starts, read by the layout-fragment callback.
final class FoldedHeadings: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: Set<Int> = []

    func set(_ new: Set<Int>) {
        lock.withLock { starts = new }
    }

    func contains(_ offset: Int) -> Bool {
        lock.withLock { starts.contains(offset) }
    }
}

/// A TextKit 2 text view over a `DocumentState`. The text storage mirrors the document; every
/// character edit goes through `DocumentState.apply`, and only the affected region is restyled.
@MainActor
public final class OrgEditor: NSObject {
    public let textView: NSTextView
    public private(set) var document: DocumentState
    public private(set) var view = ViewState()
    /// Called with the time from a character edit to restyled text.
    public var onEditTiming: ((Duration) -> Void)?

    let hidden = HiddenRanges()
    let folded = FoldedHeadings()
    let theme = Theme()
    private var isLoading = false
    private var previousSelection = 0
    /// Text before this offset is styled; after it, only base attributes until the background
    /// passes reach it. Always at a line start.
    private(set) var styledUpTo = 0
    private var stylingScheduled = false

    /// Styled before the first render: more than a screenful.
    static let firstStyleChunk = 30_000
    /// Styled per run-loop turn afterwards.
    static let styleChunk = 200_000

    public init(document: DocumentState, frame: NSRect = NSRect(x: 0, y: 0, width: 600, height: 800)) {
        self.document = document
        textView = NSTextView(usingTextLayoutManager: true)
        super.init()
        textView.frame = frame
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = theme.font
        textView.typingAttributes = theme.base
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.textStorage?.delegate = self
        textLayoutManager.delegate = self
        textContentStorage.delegate = self

        load(document.text)
    }

    /// Replaces the storage's text. Setting the attributed string directly is about 100x
    /// faster than `NSTextView.string` for large files.
    private func load(_ text: String) {
        isLoading = true
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: theme.base))
        isLoading = false
        styledUpTo = 0
        styleNextChunk(Self.firstStyleChunk)
        scheduleStyling()
    }

    // MARK: - Initial styling

    /// Styles whole lines from the watermark onward, about `size` units.
    private func styleNextChunk(_ size: Int) {
        let text = textView.textStorage!.string as NSString
        guard styledUpTo < text.length else { return }
        let target = min(text.length, styledUpTo + size)
        let end = target == text.length ? target : NSMaxRange(text.lineRange(for: NSRange(location: target, length: 0)))
        restyleOutsideEditing(styledUpTo..<end)
        styledUpTo = end
    }

    private func scheduleStyling() {
        guard !stylingScheduled, styledUpTo < utf16Length else { return }
        stylingScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stylingScheduled = false
            self.styleNextChunk(Self.styleChunk)
            self.scheduleStyling()
        }
    }

    /// Styles everything still waiting for a background pass.
    public func finishStyling() {
        while styledUpTo < utf16Length { styleNextChunk(Self.styleChunk) }
    }

    public var textLayoutManager: NSTextLayoutManager { textView.textLayoutManager! }
    var textContentStorage: NSTextContentStorage { textLayoutManager.textContentManager as! NSTextContentStorage }
    var utf16Length: Int { (textView.string as NSString).length }

    /// A scroll view holding the text view, ready for a window.
    public func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView(frame: textView.frame)
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return scroll
    }

    // MARK: - Saving

    /// Saves through `saver`. When a merge changes the buffer, the text view is reloaded and
    /// folds are mapped through the change.
    @discardableResult
    public func save(using saver: Saver, to url: URL) throws -> SaveOutcome {
        let before = document.text
        let outcome = try saver.save(&document, to: url)
        if document.text != before {
            let edits = lineEdits(from: before, to: document.text)
            load(document.text)
            setFolds(view.mapped(through: edits).folds)
        }
        return outcome
    }

    // MARK: - Folding

    public func setFolds(_ folds: Set<Int>) {
        view.folds = folds
        view = view.pruned(to: document.tree)
        folded.set(view.folds)
        hidden.set(Presentation.hiddenRanges(document.tree, folds: view.folds))
        textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
        textView.needsDisplay = true
        let caret = textView.selectedRange().location
        if let range = hidden.containing(caret) { setCaret(range.lowerBound - 1) }
    }

    /// Folds or unfolds the heading whose line holds the caret. Returns false off a heading.
    @discardableResult
    public func toggleFoldAtCaret() -> Bool {
        guard let heading = Presentation.heading(containing: textView.selectedRange().location, in: document.tree) else { return false }
        var folds = view.folds
        if folds.contains(heading) { folds.remove(heading) } else { folds.insert(heading) }
        setFolds(folds)
        return true
    }

    /// Folds every heading, or unfolds everything if anything is folded.
    public func toggleAllFolds() {
        setFolds(view.folds.isEmpty ? Set(Presentation.headings(document.tree)) : [])
    }

    private func setCaret(_ offset: Int) {
        let clamped = max(0, min(offset, utf16Length))
        previousSelection = clamped
        textView.setSelectedRange(NSRange(location: clamped, length: 0))
    }

    // MARK: - Styling

    private func restyleOutsideEditing(_ range: Range<Int>) {
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        restyle(range, in: storage)
        storage.endEditing()
    }

    /// Sets attributes for whole lines in `range`. Safe inside `didProcessEditing`, where
    /// attribute changes are allowed and characters must not change.
    private func restyle(_ range: Range<Int>, in storage: NSTextStorage) {
        guard !range.isEmpty else { return }
        let whole = NSRange(range)
        storage.setAttributes(theme.base, range: whole)
        for run in Presentation.indents(document.tree, in: range) {
            guard let clipped = clip(run.range, to: range) else { continue }
            storage.addAttribute(.paragraphStyle, value: theme.paragraphStyle(firstLine: run.firstLine, wrapped: run.wrapped), range: clipped)
        }
        for run in Presentation.styles(document.tree, in: range) {
            guard let clipped = clip(run.range, to: range) else { continue }
            theme.apply(run.role, to: storage, range: clipped)
        }
    }

    private func clip(_ run: Range<Int>, to range: Range<Int>) -> NSRange? {
        let clipped = run.clamped(to: range)
        return clipped.isEmpty ? nil : NSRange(clipped)
    }

    /// The region an edit affects in one version of the tree: inside the innermost section
    /// holding the edited lines (plus the line after), every element that overlaps them or the
    /// line on either side. A changed heading line, or an added or removed heading, widens it
    /// to that section's whole own body. Run on the old and the new tree, the union covers
    /// elements that grew and elements that shrank.
    static func affectedRange(_ tree: OrgTree, _ text: NSString, _ start: Int, _ end: Int, touchedHeadings: Bool) -> Range<Int> {
        let lines = text.lineRange(for: NSRange(location: start, length: min(end + 1, text.length) - start))
        let lineRange = lines.location..<(lines.location + lines.length)
        let around = max(0, lineRange.lowerBound - 1)..<min(text.length, lineRange.upperBound + 1)
        var container = tree.root
        while let child = container.child(containing: lineRange.lowerBound),
              child.kind == .section || child.kind == .zerothSection,
              lineRange.upperBound <= child.range.upperBound {
            container = child
        }
        var lower = lineRange.lowerBound
        var upper = lineRange.upperBound
        // Tables and lists carry no styling of their own, so inside them only the rows or
        // items around the edit change, however large they are.
        func overlapping(_ nodes: [SyntaxNode]) -> [SyntaxNode] {
            nodes.filter { $0.range.overlaps(around) }.flatMap { node -> [SyntaxNode] in
                guard [.table, .plainList, .item].contains(node.kind) else { return [node] }
                let inner = overlapping(node.children(overlapping: around))
                return inner.isEmpty ? [node] : inner
            }
        }
        for child in overlapping(container.children(overlapping: around)) {
            lower = min(lower, child.range.lowerBound)
            upper = max(upper, child.range.upperBound)
        }
        let heading = container.firstChild(.heading)
        if touchedHeadings || heading.map({ $0.range.overlaps(lineRange) }) == true {
            lower = min(lower, container.range.lowerBound)
            upper = max(upper, container.firstChild(.section)?.range.lowerBound ?? container.range.upperBound)
        }
        return lower..<min(upper, text.length)
    }

    // MARK: - Editing

    fileprivate func storageEdited(range: NSRange, delta: Int) {
        guard !isLoading, let storage = textView.textStorage else { return }
        let clock = ContinuousClock()
        let start = clock.now
        let replacement = (storage.string as NSString).substring(with: range)
        let edit = TextEdit(range: range.location..<(range.location + range.length - delta), replacement: replacement)
        let oldText = document.text as NSString
        let newText = storage.string as NSString
        let newEnd = edit.range.lowerBound + replacement.utf16.count
        let touchedHeadings = Self.headingLineNear(edit.range.lowerBound, edit.range.upperBound, in: oldText)
            || Self.headingLineNear(edit.range.lowerBound, newEnd, in: newText)
        let oldAffected = Self.affectedRange(document.tree, oldText, edit.range.lowerBound, edit.range.upperBound, touchedHeadings: touchedHeadings)
        do {
            try document.apply([edit], baseRevision: document.revision)
        } catch {
            assertionFailure("text view and document disagree: \(error)")
            return
        }
        // Keep the watermark on unstyled text: shift it past the edit, or pull it back to the
        // edited line when the edit reaches into unstyled text.
        if styledUpTo >= edit.range.upperBound {
            styledUpTo += edit.replacement.utf16.count - edit.range.count
        } else if styledUpTo > edit.range.lowerBound {
            styledUpTo = (storage.string as NSString).lineRange(for: NSRange(location: edit.range.lowerBound, length: 0)).location
        }
        let oldHidden = hidden.all
        view = view.mapped(through: [edit]).pruned(to: document.tree)
        folded.set(view.folds)
        hidden.set(Presentation.hiddenRanges(document.tree, folds: view.folds))
        let newAffected = Self.affectedRange(document.tree, newText, edit.range.lowerBound, newEnd, touchedHeadings: touchedHeadings)
        let delta = edit.replacement.utf16.count - edit.range.count
        let oldMapped = oldAffected.lowerBound..<(oldAffected.upperBound >= edit.range.upperBound ? oldAffected.upperBound + delta : newEnd)
        restyle(min(oldMapped.lowerBound, newAffected.lowerBound)..<min(max(oldMapped.upperBound, newAffected.upperBound), newText.length), in: storage)
        if hidden.all != oldHidden.map({ mapRange($0, through: edit) }) {
            textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
        }
        onEditTiming?(clock.now - start)
    }

    /// Whether a heading line touches `start..<end` or starts right after it, where joining
    /// lines could take it away.
    static func headingLineNear(_ start: Int, _ end: Int, in text: NSString) -> Bool {
        let length = min(end + 1, text.length) - start
        guard length >= 0 else { return false }
        let lines = text.substring(with: text.lineRange(for: NSRange(location: start, length: length)))
        return lines.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let stars = line.prefix { $0 == "*" }
            let after = line.dropFirst(stars.count)
            return !stars.isEmpty && (after.isEmpty || after.first == " " || after.first == "\t" || after.first == "\r")
        }
    }

    private func mapRange(_ range: Range<Int>, through edit: TextEdit) -> Range<Int> {
        let mapped = ViewState(selection: [range]).mapped(through: [edit]).selection[0]
        return mapped
    }

    /// Keeps the caret out of folded text: moving forward into a fold jumps past it, moving
    /// back jumps to the end of the heading line.
    fileprivate func selectionChanged() {
        let selection = textView.selectedRange()
        defer { previousSelection = selection.location }
        guard selection.length == 0, let range = hidden.containing(selection.location) else { return }
        setCaret(selection.location >= previousSelection ? range.upperBound : range.lowerBound - 1)
    }
}

extension OrgEditor: NSTextViewDelegate {
    public func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)): return toggleFoldAtCaret()
        case #selector(NSResponder.insertBacktab(_:)):
            toggleAllFolds()
            return true
        default: return false
        }
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        selectionChanged()
    }
}

extension OrgEditor: NSTextStorageDelegate {
    public nonisolated func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated { storageEdited(range: editedRange, delta: delta) }
    }
}

extension OrgEditor: NSTextContentStorageDelegate {
    /// Folded text isn't enumerated, so it isn't laid out or drawn.
    public nonisolated func textContentManager(
        _ textContentManager: NSTextContentManager, shouldEnumerate textElement: NSTextElement, options: NSTextContentManager.EnumerationOptions = []
    ) -> Bool {
        guard let range = textElement.elementRange else { return true }
        let documentStart = textContentManager.documentRange.location
        let start = textContentManager.offset(from: documentStart, to: range.location)
        let end = textContentManager.offset(from: documentStart, to: range.endLocation)
        return !hidden.covers(start, end)
    }
}

extension OrgEditor: NSTextLayoutManagerDelegate {
    public nonisolated func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let range = textElement.elementRange
        if let range, let manager = textLayoutManager.textContentManager {
            let offset = manager.offset(from: manager.documentRange.location, to: range.location)
            if folded.contains(offset) { return FoldedHeadingFragment(textElement: textElement, range: range) }
        }
        return NSTextLayoutFragment(textElement: textElement, range: range)
    }
}

/// A heading line drawn with an ellipsis after it, like org's folded headings.
final class FoldedHeadingFragment: NSTextLayoutFragment, @unchecked Sendable {
    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let line = textLineFragments.first else { return }
        let bounds = line.typographicBounds
        let ellipsis = NSAttributedString(string: " …", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        ellipsis.draw(at: CGPoint(x: point.x + bounds.maxX, y: point.y + bounds.minY))
        NSGraphicsContext.restoreGraphicsState()
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.insetBy(dx: -40, dy: 0).offsetBy(dx: 40, dy: 0)
    }
}
#endif
