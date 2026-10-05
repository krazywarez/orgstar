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
    /// Blocks drawn on a shaded band.
    let shaded = HiddenRanges()
    let theme = Theme()
    private var isLoading = false
    private var previousSelection = 0
    /// Text before this offset is styled; after it, only base attributes until the background
    /// passes reach it. Always at a line start.
    private(set) var styledUpTo = 0
    private var stylingScheduled = false
    /// One paragraph style object per indent pair, shared by every line that uses it.
    private var paragraphStyles: [IndentKey: NSParagraphStyle] = [:]

    private struct IndentKey: Hashable {
        let firstLine: Int
        let wrapped: Int
    }

    /// Styled before the first render: more than a screenful.
    static let firstStyleChunk = 30_000
    /// Styled per run-loop turn afterwards.
    static let styleChunk = 200_000

    /// Highlights code in src blocks; nil leaves code plain.
    public let highlighter: (any CodeHighlighter)?

    /// What the file is: org, or plain text, highlighted as code when the language is known.
    public enum Mode: Equatable, Sendable {
        case org
        case plain(language: String?)
    }

    public let mode: Mode
    public var isOrg: Bool { mode == .org }
    /// Highlights of the whole file in plain mode, and the revision they were made for.
    private var codeRuns: (revision: Int, runs: [(range: Range<Int>, category: SyntaxCategory)])?

    public init(
        document: DocumentState, frame: NSRect = NSRect(x: 0, y: 0, width: 600, height: 800), editable: Bool = true,
        highlighter: (any CodeHighlighter)? = nil, mode: Mode = .org
    ) {
        self.document = document
        self.highlighter = highlighter
        self.mode = mode
        let orgTextView = OrgTextView(usingTextLayoutManager: true)
        textView = orgTextView
        dispatcher = KeyDispatcher(keymap: KeymapPreset.emacs.keymap)
        super.init()
        orgTextView.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        orgTextView.onMouseDown = { [weak self] in
            self?.markActive = false
            self?.modalMouseDown()
        }
        textView.usesFindBar = true
        textView.frame = frame
        textView.isRichText = false
        textView.isEditable = editable
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

        if isOrg { shaded.set(Presentation.shadedBlocks(document.tree)) }
        load(document.text)
        if isOrg, let startup = Presentation.startupFoldState(document.tree) { setFolds(startup) }
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

    /// Styles the whole file again, a screenful now and the rest in the background.
    private func restyleEverything() {
        styledUpTo = 0
        revealedLine = caretLine
        styleNextChunk(Self.firstStyleChunk)
        scheduleStyling()
    }

    private var caretLine: NSRange {
        let text = textView.string as NSString
        return text.lineRange(for: NSRange(location: min(textView.selectedRange().location, text.length), length: 0))
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

    /// Saves through `saver`. A merge that changes the buffer reloads the text view.
    @discardableResult
    public func save(using saver: Saver, to url: URL) throws -> SaveOutcome {
        try update { try saver.save(&$0, to: url) }
    }

    /// Called after every change to the document, typed or not.
    public var onChange: (() -> Void)?

    // MARK: - Commands

    /// Called with messages commands report, such as why one couldn't run here.
    public var onMessage: ((String) -> Void)?
    /// Called with the pending prefix and what can follow it, and with nil when it ends.
    /// The evil state when editing modally (`normal`, `insert`, `visual`, `visual-line`), nil otherwise.
    public var onModeChange: ((String?) -> Void)?
    /// The selection moved.
    public var onSelectionChange: ((NSRange) -> Void)?
    var reportedMode: String?
    public var onKeysPending: ((_ keys: String?, _ next: [(key: String, title: String)]) -> Void)?
    /// Called with `app.*` commands, which the app carries out.
    public var onAppCommand: ((String) -> Void)?
    /// Called when a command asks a question; reply with the answer, or nil to cancel.
    public var onPrompt: ((Prompt, _ reply: @escaping (String?) -> Void) -> Void)?
    /// Runs work outside the text, such as a table recalculation in Emacs.
    public var onExternal: ((ExternalRequest) -> Void)?

    public var keymap: Keymap {
        get { dispatcher.keymap }
        set {
            dispatcher.keymap = newValue
            dispatcher.reset()
        }
    }

    public var optionAsMeta: OptionAsMeta = [.left]
    /// Org options commands follow.
    public var options: EditingOptions = .org {
        didSet {
            if options.hideEmphasisMarkers != oldValue.hideEmphasisMarkers, !showMarkup { restyleEverything() }
        }
    }
    /// Show link brackets and targets, and emphasis markers (when Emacs hides them, per
    /// `options`). Hidden markup shows on the caret's line, so it can be edited.
    public var showMarkup = true {
        didSet { if showMarkup != oldValue { restyleEverything() } }
    }
    /// The line last revealed while markup is hidden, to hide again when the caret leaves.
    private var revealedLine: NSRange?
    var dispatcher: KeyDispatcher
    /// Evil-style editing, for modal keymaps such as Doom's.
    public var modal = false {
        didSet {
            guard modal != oldValue else { return }
            vim = Vim()
            dispatcher.mode = modal ? vim.mode.keymapMode : nil
            dispatcher.reset()
            updateCursor()
        }
    }
    var vim = Vim()
    /// The text and caret when insert state began, to know what was typed for `.`.
    var insertSnapshot: (text: String, caret: Int)?
    /// The evil cursor in visual states, where the selection's start isn't it.
    var visualCaret: Int?
    /// A region is active: movement extends the selection, as after C-SPC in Emacs.
    private(set) var markActive = false

    private func context(now: Date = Date(), answers: [String: String] = [:]) -> EditContext {
        let selected = textView.selectedRange()
        return EditContext(
            revision: document.revision, text: document.text, tree: document.tree,
            selection: [selected.location..<NSMaxRange(selected)], now: now, calendar: .current, answers: answers,
            hidden: hidden.all, options: options
        )
    }

    /// Offers a key press to the keymap. False lets the text system have it.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let chord = KeyEvents.chord(for: event, optionAsMeta: optionAsMeta) else { return modal && vim.mode != .insert }
        if modal { return handleModal(chord) }
        switch dispatcher.feed(chord) {
        case .pending(let keys):
            let next = keymap.continuations(of: keys).map { item in
                (key: item.key.description, title: item.command.map { EditorCommands.command($0)?.title ?? $0 } ?? "+prefix")
            }
            onKeysPending?(KeySequence.format(keys), next)
            return true
        case .cancelled:
            onKeysPending?(nil, [])
            onMessage?("Quit")
            return true
        case .undefined(let keys):
            onKeysPending?(nil, [])
            onMessage?("\(KeySequence.format(keys)) is undefined")
            return true
        case .unbound:
            return false
        case .complete(let keys, let candidates):
            if keys.count > 1 { onKeysPending?(nil, []) }
            let context = context()
            let runnable = candidates.first { binding in
                (binding.when.map { KeyContext.holds($0, in: context) } ?? true) && applies(binding.command, in: context)
            }
            if let binding = runnable ?? (keys.count > 1 ? candidates.first : nil) {
                run(binding.command)
                return true
            }
            return false
        }
    }

    private func applies(_ id: String, in context: EditContext) -> Bool {
        if !isOrg, id.hasPrefix("org.") { return false }
        return switch EditorCommands.command(id)?.action {
        case .text(let command): command.applies(in: context)
        case .view: id != "org.cycle" || Presentation.heading(containing: context.caret, in: context.tree) != nil
        case .edit, .mark, .app, .find: true
        case nil: true
        }
    }

    /// Runs a command by id, as a key, a menu item or the palette would.
    public func run(_ id: String) {
        guard let command = EditorCommands.command(id) else {
            onMessage?("Unknown command \(id)")
            return
        }
        if !isOrg, id.hasPrefix("org.") {
            onMessage?("Not an org file")
            return
        }
        var keepMark = false
        switch command.action {
        case .text(let text):
            perform(text)
        case .view:
            if id == "org.cycle" { cycleAtCaret() } else { cycleGlobal() }
        case .edit(let selector, let extending):
            if markActive, let extending {
                keepMark = true
                textView.doCommand(by: NSSelectorFromString(extending))
            } else {
                textView.doCommand(by: NSSelectorFromString(selector))
            }
        case .find(let action):
            let item = NSMenuItem()
            item.tag = action.rawValue
            textView.performTextFinderAction(item)
        case .mark:
            if id == "edit.set-mark" {
                let caret = textView.selectedRange().location
                textView.setSelectedRange(NSRange(location: caret, length: 0))
                keepMark = true
                onMessage?("Mark set")
            } else {
                let selected = textView.selectedRange()
                if markActive || selected.length > 0 { textView.setSelectedRange(NSRange(location: NSMaxRange(selected), length: 0)) }
                onMessage?("Quit")
            }
        case .app:
            onAppCommand?(id)
        }
        markActive = keepMark
    }

    /// Runs `command` at the selection. Edits go through the text view, as typing does, so
    /// they form one undo step and reach the document through the same path.
    @discardableResult
    public func perform(_ command: any OrgCommand, now: Date = Date(), answers: [String: String] = [:]) -> CommandStep {
        let context = context(now: now, answers: answers)
        let step = command.run(in: context)
        switch step {
        case .commit(let result):
            guard textView.isEditable || result.edits.isEmpty else {
                onMessage?("This file is read-only.")
                return .failed("read-only")
            }
            applyEdits(result.edits)
            if let selection = result.selection?.first {
                setCaret(selection.lowerBound)
                if !selection.isEmpty { textView.setSelectedRange(NSRange(selection)) }
            }
            for case .message(let text) in result.effects { onMessage?(text) }
        case .failed(let message):
            onMessage?(message)
        case .external(let request):
            if let onExternal { onExternal(request) } else { onMessage?("This needs Emacs, which isn't available here.") }
        case .prompt(let prompt):
            onPrompt?(prompt) { [weak self] answer in
                guard let self else { return }
                guard let answer else {
                    self.onMessage?("Quit")
                    return
                }
                self.perform(command, now: now, answers: answers.merging([prompt.key: answer]) { $1 })
            }
        }
        return step
    }

    // MARK: - Disk

    /// The file on disk now holds `bytes`: reload or merge, keeping folds where the text kept
    /// its headings.
    @discardableResult
    public func diskChanged(to bytes: [UInt8]) -> DocumentState.ExternalChange {
        update { $0.diskChanged(to: bytes) }
    }

    // MARK: - Folding

    public var foldState: FoldState {
        FoldState(folds: view.folds, bodyFolds: view.bodyFolds)
    }

    private var globalVisibility: GlobalVisibility?

    public func setFolds(_ state: FoldState) {
        view.folds = state.folds
        view.bodyFolds = state.bodyFolds
        view = view.pruned(to: document.tree)
        updateHidden()
        textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
        textView.needsDisplay = true
        let caret = textView.selectedRange().location
        if let range = hidden.containing(caret) { setCaret(range.lowerBound - 1) }
    }

    private func updateHidden() {
        folded.set(view.folds.union(view.bodyFolds))
        hidden.set(Presentation.hiddenRanges(document.tree, folds: view.folds, bodyFolds: view.bodyFolds))
    }

    /// TAB on a heading: folded, children, subtree. Returns false off a heading.
    @discardableResult
    public func cycleAtCaret() -> Bool {
        guard let heading = Presentation.heading(containing: textView.selectedRange().location, in: document.tree) else { return false }
        setFolds(Presentation.cycle(heading, in: document.tree, foldState))
        return true
    }

    /// Shift-TAB: overview, contents, show all.
    public func cycleGlobal() {
        let (visibility, state) = Presentation.cycleGlobal(from: globalVisibility, in: document.tree)
        globalVisibility = visibility
        setFolds(state)
    }

    /// Unfolds whatever hides `offset`, puts the caret there and scrolls to it.
    public func reveal(_ offset: Int) {
        let target = max(0, min(offset, utf16Length))
        unfold(around: target)
        setCaret(target)
        textView.scrollRangeToVisible(NSRange(location: target, length: 0))
    }

    /// Unfolds the headings whose folds hide `offset`, leaving the selection alone.
    func unfold(around offset: Int) {
        var state = foldState
        for entry in Presentation.outline(document.tree) where entry.start < offset && offset < entry.end {
            state.folds.remove(entry.start)
            state.bodyFolds.remove(entry.start)
        }
        guard state != foldState else { return }
        setFolds(state)
    }

    /// Applies edits through the text view as one undo step, not merged with typing around it.
    func applyEdits(_ edits: [TextEdit]) {
        guard !edits.isEmpty, let storage = textView.textStorage else { return }
        textView.breakUndoCoalescing()
        textView.undoManager?.beginUndoGrouping()
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            let range = NSRange(edit.range)
            guard textView.shouldChangeText(in: range, replacementString: edit.replacement) else { continue }
            storage.replaceCharacters(in: range, with: edit.replacement)
            textView.didChangeText()
        }
        textView.undoManager?.endUndoGrouping()
        textView.breakUndoCoalescing()
    }

    func setCaret(_ offset: Int) {
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
        guard isOrg else {
            for run in plainRuns() where run.range.overlaps(range) {
                guard let clipped = clip(run.range, to: range) else { continue }
                theme.apply(.syntax(run.category), to: storage, range: clipped)
            }
            return
        }
        let text = storage.string as NSString
        for run in Presentation.indents(document.tree, in: range) {
            guard let clipped = clip(run.range, to: range) else { continue }
            guard run.firstLine == run.wrapped else {
                storage.addAttribute(.paragraphStyle, value: paragraphStyle(run.firstLine, run.wrapped), range: clipped)
                continue
            }
            // Body lines wrap under their own text: past leading blanks, and past a list bullet
            // and checkbox, as adaptive-wrap does in Emacs.
            var location = clipped.location
            while location < NSMaxRange(clipped) {
                let line = text.lineRange(for: NSRange(location: location, length: 0))
                let hanging = Self.hangingColumns(text.substring(with: line))
                let lineRange = NSIntersectionRange(line, clipped)
                storage.addAttribute(.paragraphStyle, value: paragraphStyle(run.firstLine, run.wrapped + hanging), range: lineRange)
                location = NSMaxRange(line)
            }
        }
        let revealed = caretLine
        for run in Presentation.styles(document.tree, in: range, highlighter: highlighter) {
            guard let clipped = clip(run.range, to: range) else { continue }
            if !showMarkup, hides(run.role), NSIntersectionRange(clipped, revealed).length == 0 {
                storage.addAttributes(theme.hidden, range: clipped)
            } else {
                theme.apply(run.role, to: storage, range: clipped)
            }
        }
    }

    /// Link brackets and targets are hidden as with `org-link-descriptive`; emphasis
    /// markers only when Emacs hides them too.
    private func hides(_ role: StyleRole) -> Bool {
        switch role {
        case .linkMarkup: true
        case .markup: options.hideEmphasisMarkers
        default: false
        }
    }

    /// Moving to another line shows its markup and hides the last one's.
    private func revealCaretLine() {
        guard !showMarkup, isOrg else { return }
        let line = caretLine
        guard line != revealedLine else { return }
        let text = textView.string as NSString
        // The old line may have moved with edits since; restyle the line now at its start.
        let old = revealedLine.flatMap { $0.location <= text.length ? text.lineRange(for: NSRange(location: $0.location, length: 0)) : nil }
        revealedLine = line
        for range in [old, line].compactMap({ $0 }) where range.location < styledUpTo {
            restyleOutsideEditing(range.location..<NSMaxRange(range))
        }
    }

    /// Code highlights for the whole file in plain mode.
    private func plainRuns() -> [(range: Range<Int>, category: SyntaxCategory)] {
        guard case .plain(let language?) = mode, let highlighter else { return [] }
        if let codeRuns, codeRuns.revision == document.revision { return codeRuns.runs }
        let runs = highlighter.highlights(language: language, code: document.text)
        codeRuns = (document.revision, runs)
        return runs
    }

    private func paragraphStyle(_ firstLine: Int, _ wrapped: Int) -> NSParagraphStyle {
        let key = IndentKey(firstLine: firstLine, wrapped: wrapped)
        if let style = paragraphStyles[key] { return style }
        let style = theme.paragraphStyle(firstLine: firstLine, wrapped: wrapped)
        paragraphStyles[key] = style
        return style
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
        markActive = false
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
        let oldShaded = shaded.all
        if isOrg { shaded.set(Presentation.shadedBlocks(document.tree)) }
        if hidden.all != oldHidden.map({ mapRange($0, through: edit) })
            || shaded.all != oldShaded.map({ mapRange($0, through: edit) }) {
            textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
        }
        onEditTiming?(clock.now - start)
        onChange?()
    }

    /// Columns a wrapped continuation of `line` should start past the line's own start.
    nonisolated static func hangingColumns(_ line: String) -> Int {
        var columns = 0
        var rest = Substring(line)
        while let c = rest.first, c == " " || c == "\t" {
            columns = c == "\t" ? (columns / 8 + 1) * 8 : columns + 1
            rest = rest.dropFirst()
        }
        // A bullet (`-`, `+`, `*` when indented, `1.`, `1)`) and its space, then a checkbox.
        var bullet = 0
        if let first = rest.first, first == "-" || first == "+" || (first == "*" && columns > 0) {
            bullet = 1
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            if !digits.isEmpty, let separator = rest.dropFirst(digits.count).first, separator == "." || separator == ")" {
                bullet = digits.count + 1
            }
        }
        guard bullet > 0, rest.dropFirst(bullet).first == " " else { return columns }
        columns += bullet + 1
        let afterBullet = rest.dropFirst(bullet + 1)
        if afterBullet.count >= 4, afterBullet.first == "[", "X x-".contains(afterBullet.dropFirst().first!),
           afterBullet.dropFirst(2).first == "]", afterBullet.dropFirst(3).first == " " {
            columns += 4
        }
        return columns
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
        onSelectionChange?(selection)
        revealCaretLine()
        // A selection reaching into folded text, as a find match does, unfolds it.
        if selection.length > 0 {
            if hidden.containing(selection.location) != nil || hidden.containing(NSMaxRange(selection) - 1) != nil {
                unfold(around: selection.location)
                unfold(around: NSMaxRange(selection) - 1)
            }
            return
        }
        guard let range = hidden.containing(selection.location) else { return }
        setCaret(selection.location >= previousSelection ? range.upperBound : range.lowerBound - 1)
    }
}

extension OrgEditor: DocumentBuffer {
    /// The selected text, for capture's `%i`.
    public var selectedText: String {
        let range = textView.selectedRange()
        guard range.length > 0 else { return "" }
        return (textView.string as NSString).substring(with: range)
    }

    public var selection: [Range<Int>] {
        let selected = textView.selectedRange()
        return [selected.location..<NSMaxRange(selected)]
    }

    /// Runs `change`; if it changed the text, reloads the view with folds and the selection
    /// mapped through the change. Text-view undo refers to the old text, so it is cleared.
    public func update<T>(_ change: (inout DocumentState) throws -> T) rethrows -> T {
        let before = document.text
        let selected = textView.selectedRange()
        let result = try change(&document)
        if document.text != before {
            let edits = lineEdits(from: before, to: document.text)
            var state = view
            state.selection = [selected.location..<NSMaxRange(selected)]
            let mapped = state.mapped(through: edits)
            load(document.text)
            setFolds(FoldState(folds: mapped.folds, bodyFolds: mapped.bodyFolds))
            let selection = mapped.selection[0]
            setCaret(selection.lowerBound)
            if !selection.isEmpty { textView.setSelectedRange(NSRange(selection)) }
            textView.undoManager?.removeAllActions(withTarget: textView.textStorage!)
            textView.undoManager?.removeAllActions(withTarget: textView)
        }
        onChange?()
        return result
    }
}

extension OrgEditor: NSTextViewDelegate {
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
            if shaded.containing(offset) != nil { return ShadedFragment(textElement: textElement, range: range) }
        }
        return NSTextLayoutFragment(textElement: textElement, range: range)
    }
}

/// A line of a block, on a band across the whole width of the view, as Emacs extends the
/// `org-block` face.
final class ShadedFragment: NSTextLayoutFragment, @unchecked Sendable {
    private var band: CGRect {
        let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        return CGRect(x: -layoutFragmentFrame.minX, y: 0, width: width, height: layoutFragmentFrame.height)
    }

    override var renderingSurfaceBounds: CGRect { super.renderingSurfaceBounds.union(band) }

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.setFillColor(Theme.blockBackground.cgColor)
        context.fill(band.offsetBy(dx: point.x, dy: point.y))
        context.restoreGState()
        super.draw(at: point, in: context)
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
