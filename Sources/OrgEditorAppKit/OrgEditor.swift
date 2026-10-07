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
    /// Where lines start, for line numbers.
    let lines = LineIndex()
    /// Blocks drawn on a shaded band.
    let shaded = HiddenRanges()
    private(set) var theme = Theme()
    /// Colors and type; a change restyles the file.
    public var themeSpec: ThemeSpec = .default {
        didSet {
            guard themeSpec != oldValue else { return }
            theme = Theme(themeSpec)
            applyThemeToView()
            restyleEverything()
            textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
        }
    }
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
    /// The text as shown for accessibility, and the storage generation it's for.
    var accessibleCache: (storage: Int, text: AccessibleText)?
    /// Bumped on every character or attribute change to the storage.
    var storageGeneration = 0
    /// The open completion list, and the pause before one opens by itself.
    var completionPopup: CompletionPopup?
    var completionTimer: DispatchWorkItem?
    /// The spell checker's skipped ranges and the text they were found in.
    var spellSkipCache: (text: String, ranges: [Range<Int>])?
    /// Highlights of the whole file in plain mode, and the revision they were made for.
    private var codeRuns: (revision: Int, runs: [(range: Range<Int>, category: SyntaxCategory)])?

    public init(
        document: DocumentState, frame: NSRect = NSRect(x: 0, y: 0, width: 600, height: 800), editable: Bool = true,
        highlighter: (any CodeHighlighter)? = nil, mode: Mode = .org, options: EditingOptions = .org
    ) {
        self.document = document
        self.options = options
        self.highlighter = highlighter
        self.mode = mode
        let orgTextView = OrgTextView(usingTextLayoutManager: true)
        textView = orgTextView
        dispatcher = KeyDispatcher(keymap: KeymapPreset.emacs.keymap)
        super.init()
        orgTextView.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        orgTextView.onCommandClick = { [weak self] offset in
            guard let self, Links.link(at: offset, text: self.document.text, tree: self.document.tree) != nil
                || Links.timestampDays(at: offset, text: self.document.text) != nil else { return false }
            self.setCaret(offset)
            self.run("org.link.open")
            return true
        }
        orgTextView.onClick = { [weak self] offset in self?.click(at: offset) ?? false }
        orgTextView.accessibleText = { [weak self] in
            guard let self, let storage = self.textView.textStorage else { return AccessibleText(NSAttributedString()) }
            if let cached = self.accessibleCache, cached.storage == self.storageGeneration { return cached.text }
            let text = AccessibleText(storage)
            self.accessibleCache = (self.storageGeneration, text)
            return text
        }
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
        applyThemeToView()
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.textStorage?.delegate = self
        textLayoutManager.delegate = self
        textContentStorage.delegate = self

        if isOrg { shaded.set(Presentation.shadedBlocks(document.tree)) }
        load(document.text)
        // Files open at their start, as in Emacs; replacing the storage leaves it at the end.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        if isOrg {
            let words = Presentation.startupOptions(document.tree).map { $0.lowercased() }
            indented = words.contains("indent") ? true : words.contains("noindent") ? false : options.startupIndented
            hideStars = words.contains("hidestars") ? true : words.contains("showstars") ? false : options.hideLeadingStars
            var startup = Presentation.startupFoldState(document.tree) ?? FoldState()
            // VISIBILITY properties and archived trees, unless everything shows.
            if Presentation.startupFoldState(document.tree) != nil, !words.contains("showeverything") {
                startup = Presentation.applyVisibilityProperties(startup, in: document.tree)
            }
            let wrappers = Presentation.startupWrappers(document.tree, hideDrawers: options.hideDrawerStartup, hideBlocks: options.hideBlockStartup)
            startup.wrapperFolds = Set(wrappers.map(\.start))
            if startup != FoldState() { setFolds(startup, wrappers: wrappers) }
            shrinkAtStartup()
            if InlineImages.startup(document.tree) ?? options.startupWithInlineImages { showsImages = true }
            if words.contains("align") || (options.startupAlignAllTables && !words.contains("noalign")) {
                _ = perform(AlignAllTables())
            }
            if !indented || !hideStars { restyleOutsideEditing(0..<utf16Length) }
        }
        spellChecking = options.spellCheck
        truncatesLines = options.startupTruncated
    }

    /// Replaces the storage's text. Setting the attributed string directly is about 100x
    /// faster than `NSTextView.string` for large files.
    private func load(_ text: String) {
        isLoading = true
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: theme.base))
        isLoading = false
        lines.reset(text as NSString)
        orgTextView?.lineIndex = lines
        orgTextView?.updateGutter()
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

    /// The text view's own colors and font, and the line numbers'.
    private func applyThemeToView() {
        textView.font = theme.font
        textView.typingAttributes = theme.base
        textView.drawsBackground = true
        textView.backgroundColor = theme.color("background") ?? .textBackgroundColor
        textView.insertionPointColor = theme.color("cursor") ?? .textColor
        textView.selectedTextAttributes = [.backgroundColor: theme.color("selection") ?? .selectedTextBackgroundColor]
        if let view = orgTextView {
            view.lineNumberFont = NSFont.monospacedDigitSystemFont(ofSize: max(8, theme.font.pointSize - 2), weight: .regular)
            view.lineNumberColor = theme.color("line-number") ?? .tertiaryLabelColor
            view.currentLineNumberColor = theme.color("line-number-current") ?? .labelColor
            view.updateGutter()
            view.needsDisplay = true
        }
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
        orgTextView?.showsLineNumbers = showLineNumbers
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
    /// `:e FILE`: the path as typed, for the app to open.
    public var onOpenFile: ((String) -> Void)?
    /// Called when a command asks a question; reply with the answer, or nil to cancel.
    public var onPrompt: ((Prompt, _ reply: @escaping (String?) -> Void) -> Void)?
    /// Runs work outside the text, such as a table recalculation in Emacs.
    public var onExternal: ((ExternalRequest) -> Void)?
    /// Tags used across the workspace, for tag completion.
    public var knownTags: @Sendable () -> [String] = { [] }
    /// Effects other than messages, for the app to carry out.
    public var onEffect: ((Effect) -> Void)?

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
    /// Line numbers in a ruler beside the text.
    public var showLineNumbers = true {
        didSet { orgTextView?.showsLineNumbers = showLineNumbers }
    }
    var orgTextView: OrgTextView? { textView as? OrgTextView }

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
    /// Vim marks, mapped through edits.
    var vimMarks: [Character: Int] = [:]
    /// Jump positions, oldest first, mapped through edits; `jumpIndex` is where C-o and C-i are.
    var jumpList: [Int] = []
    var jumpIndex = 0
    /// The register keys go into while `q` records, and its keys so far.
    var recordingRegister: Character?
    var recordedKeys: [KeyChord] = []
    var macros: [Character: [KeyChord]] = [:]
    var replayingMacro = 0
    /// A region is active: movement extends the selection, as after C-SPC in Emacs.
    private(set) var markActive = false

    public func context(now: Date = Date(), answers: [String: String] = [:]) -> EditContext {
        let selected = textView.selectedRange()
        return EditContext(
            revision: document.revision, text: document.text, tree: document.tree,
            selection: [selected.location..<NSMaxRange(selected)], now: now, calendar: .current, answers: answers,
            hidden: hidden.all, options: options, knownTags: knownTags,
            lastCommand: lastCommand.flatMap { $0.revision == document.revision ? $0.id : nil }
        )
    }

    /// Offers a key press to the keymap. False lets the text system have it.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let chord = KeyEvents.chord(for: event, optionAsMeta: optionAsMeta) else { return modal && vim.mode != .insert }
        if let handled = completionKey(chord) { return handled }
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
            return electricPair(chord)
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
            return keys.count == 1 && electricPair(chord)
        }
    }

    /// `electric-pair-mode` for a key the keymap leaves to the text system: true when it
    /// typed the key itself.
    func electricPair(_ key: KeyChord) -> Bool {
        guard isOrg, options.electricPair, key.modifiers.isEmpty, !textView.hasMarkedText(),
              key.key == "DEL" || key.key == "RET" || ElectricPairKey.characters.contains(key.key) else { return false }
        let command = ElectricPairKey(key: key.key)
        guard command.applies(in: context()) else { return false }
        _ = perform(command)
        return true
    }

    private func applies(_ id: String, in context: EditContext) -> Bool {
        if !isOrg, id.hasPrefix("org.") { return false }
        return switch EditorCommands.command(id)?.action {
        case .text(let command): command.applies(in: context)
        case .view where id.hasPrefix("org.table."): KeyContext.holds("table", in: context)
        case .view: id != "org.cycle" || Presentation.heading(containing: context.caret, in: context.tree) != nil
            || Wrappers.toggleable(at: context.caret, in: context.tree) != nil
        case .edit, .mark, .app, .find: true
        case nil: true
        }
    }

    /// The last command run and the revision it left, for `last-command`.
    private var lastCommand: (id: String, revision: Int)?

    /// Runs a command by id, as a key, a menu item or the palette would.
    public func run(_ id: String) {
        defer { lastCommand = (id, document.revision) }
        guard let command = EditorCommands.command(id) else {
            onMessage?("Unknown command \(id)")
            return
        }
        if !isOrg, id.hasPrefix("org.") {
            onMessage?("Not an org file")
            return
        }
        // `org-ctrl-c-ctrl-c` first removes sparse tree highlights.
        if id == "org.ctrl-c-ctrl-c", !highlights.isEmpty {
            clearHighlights()
            return
        }
        var keepMark = false
        switch command.action {
        case .text(let text):
            perform(text)
        case .view:
            switch id {
            case "org.cycle": cycleAtCaret()
            case "org.cycle-global": cycleGlobal()
            case "org.narrow.subtree", "org.narrow.block", "org.narrow.toggle", "org.widen": narrow(id)
            case "org.toggle-inline-images": toggleImages()
            case "editor.toggle-spell-check": toggleSpellCheck()
            case "editor.complete": completeAtPoint()
            case "editor.toggle-truncate-lines": toggleTruncateLines()
            default: tableColumnWidth(id)
            }
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
            commandEditing = true
            applyEdits(result.edits)
            commandEditing = false
            if let selection = result.selection?.first {
                if hidden.containing(selection.lowerBound) != nil { unfold(around: selection.lowerBound) }
                setCaret(selection.lowerBound)
                if !selection.isEmpty { textView.setSelectedRange(NSRange(selection)) }
            }
            for effect in result.effects {
                switch effect {
                case .message(let text): onMessage?(text)
                case .sparseTree(let points, let highlights): showSparseTree(points, highlights: highlights)
                case .fold(let start):
                    var state = foldState
                    state.folds.insert(start)
                    setFolds(state)
                default: onEffect?(effect)
                }
            }
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
        FoldState(folds: view.folds, bodyFolds: view.bodyFolds, wrapperFolds: view.wrapperFolds)
    }

    private var globalVisibility: GlobalVisibility?

    public func setFolds(_ state: FoldState) {
        setFolds(state, wrappers: nil)
    }

    /// `wrappers`, when given, holds every folded drawer and block.
    private func setFolds(_ state: FoldState, wrappers: [Wrapper]?) {
        sparseHidden = nil
        view.folds = state.folds
        view.bodyFolds = state.bodyFolds
        view = view.pruned(to: document.tree, wrappers: false)
        // Found one by one, or all at once when there are many.
        let found = wrappers ?? (state.wrapperFolds.count > 32
            ? Wrappers.all(document.tree).filter { state.wrapperFolds.contains($0.start) }
            : state.wrapperFolds.compactMap { Wrappers.starting(at: $0, in: document.tree) })
        wrapperHidden = Dictionary(found.map { ($0.start, $0.hidden) }) { a, _ in a }
        view.wrapperFolds = Set(wrapperHidden.keys)
        updateHidden()
        orgTextView?.redrawLineNumbers()
        textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
        textView.needsDisplay = true
        let caret = textView.selectedRange().location
        if let range = hidden.containing(caret) { setCaret(range.lowerBound - 1) }
    }

    /// What each folded drawer and block hides, by opening-line start; kept in step with
    /// `view.wrapperFolds` and mapped through edits.
    private var wrapperHidden: [Int: Range<Int>] = [:]

    private func updateHidden() {
        if let sparseHidden {
            let ns = textView.string as NSString
            // Headings whose next line is hidden show the fold ellipsis.
            let headings = Presentation.outline(document.tree).map(\.start).filter { start in
                let next = NSMaxRange(ns.lineRange(for: NSRange(location: start, length: 0)))
                return sparseHidden.contains { $0.contains(next) } && !sparseHidden.contains { $0.contains(start) }
            }
            folded.set(Set(headings).union(view.wrapperFolds))
            hidden.set(sparseHidden + Array(wrapperHidden.values) + narrowHidden)
            return
        }
        folded.set(view.folds.union(view.bodyFolds).union(view.wrapperFolds))
        hidden.set(Presentation.hiddenRanges(document.tree, folds: view.folds, bodyFolds: view.bodyFolds, wrapperRanges: Array(wrapperHidden.values)) + narrowHidden)
    }

    // MARK: - Sparse trees

    /// What a sparse tree (`org-sparse-tree`) hides, replacing heading folds until the next
    /// fold change. Mapped through edits.
    private var sparseHidden: [Range<Int>]?
    /// Sparse tree matches, highlighted until the next edit or C-c C-c.
    private var highlights: [Range<Int>] = []

    private func showSparseTree(_ points: [Int], highlights: [Range<Int>]) {
        let text = textView.string
        var state = foldState
        for start in state.wrapperFolds where points.contains(where: { Wrappers.starting(at: start, in: document.tree)?.hidden.contains($0) == true }) {
            state.wrapperFolds.remove(start)
        }
        sparseHidden = nil
        setFolds(state)
        sparseHidden = SparseTree.hidden(points, in: text, tree: document.tree)
        self.highlights = highlights
        updateHidden()
        restyleOutsideEditing(0..<utf16Length)
        textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
        orgTextView?.redrawLineNumbers()
        textView.needsDisplay = true
        let caret = textView.selectedRange().location
        if let range = hidden.containing(caret) { setCaret(max(0, range.lowerBound - 1)) }
    }

    /// Leaves a sparse tree for ordinary folds: headings with something shown below them
    /// open, the others folded.
    private func leaveSparseTree() {
        guard let sparse = sparseHidden else { return }
        sparseHidden = nil
        let outline = Presentation.outline(document.tree)
        let ns = textView.string as NSString
        var open: Set<Int> = []
        for entry in outline where !sparse.contains(where: { $0.contains(entry.start) }) {
            var parent = entry.parent
            while let p = parent {
                open.insert(outline[p].start)
                parent = outline[p].parent
            }
            let next = NSMaxRange(ns.lineRange(for: NSRange(location: entry.start, length: 0)))
            if next < entry.end, !sparse.contains(where: { $0.contains(next) }) { open.insert(entry.start) }
        }
        var state = foldState
        state.folds = Set(outline.map(\.start)).subtracting(open)
        state.bodyFolds = []
        setFolds(state)
    }

    private func clearHighlights() {
        guard !highlights.isEmpty else { return }
        let old = highlights
        highlights = []
        for range in old where range.upperBound <= utf16Length { restyleOutsideEditing(range) }
    }

    private func applyHighlights(_ range: Range<Int>, in storage: NSTextStorage) {
        for highlight in highlights where highlight.overlaps(range) && highlight.upperBound <= storage.length {
            storage.addAttribute(.backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.45), range: NSRange(highlight.clamped(to: range)))
        }
    }

    // MARK: - STARTUP display

    /// `org-indent-mode`: headings' bodies indented under their titles (`#+STARTUP: indent`).
    private var indented = true
    /// `org-hide-leading-stars` (`#+STARTUP: hidestars`); org-indent hides them as well.
    private var hideStars = false

    // MARK: - Inline images

    /// `org-toggle-inline-images`: lines that are only an image link show the image.
    public private(set) var showsImages = false
    /// The file's folder, for relative image paths.
    public var baseDirectory: URL? {
        didSet { if showsImages, oldValue != baseDirectory { refreshImages() } }
    }
    private static let imageCache = NSCache<NSString, NSImage>()

    private func toggleImages() {
        showsImages.toggle()
        refreshImages()
        if showsImages {
            let ns = textView.string as NSString
            var count = 0
            var offset = 0
            while offset < ns.length {
                let line = ns.lineRange(for: NSRange(location: offset, length: 0))
                if let image = InlineImages.image(atLine: line.location, in: ns), loadImage(image.path) != nil { count += 1 }
                offset = NSMaxRange(line)
            }
            onMessage?("\(count) images displayed inline")
        } else {
            onMessage?("Inline image display turned off")
        }
    }

    private func refreshImages() {
        restyleOutsideEditing(0..<utf16Length)
        textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
        textView.needsDisplay = true
    }

    private func loadImage(_ path: String) -> NSImage? {
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : (baseDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).appendingPathComponent(expanded)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(modified)" as NSString
        if let cached = Self.imageCache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        Self.imageCache.setObject(image, forKey: key)
        return image
    }

    /// Image lines in `range` show the image over the link, which is hidden unless the caret is
    /// on the line.
    private func applyImages(_ range: Range<Int>, in storage: NSTextStorage, revealed: NSRange) {
        guard showsImages, isOrg else { return }
        let text = storage.string as NSString
        let maxWidth = max(80, (textView.textContainer?.size.width ?? 600) - 40)
        var location = range.lowerBound
        while location < range.upperBound, location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(line)
            guard let image = InlineImages.image(atLine: line.location, in: text), let picture = loadImage(image.path) else { continue }
            var width = image.width.map(CGFloat.init) ?? picture.size.width
            width = min(width, maxWidth)
            let height = picture.size.width > 0 ? width * picture.size.height / picture.size.width : 0
            let content = NSRange(location: line.location, length: line.length - (text.substring(with: line).hasSuffix("\n") ? 1 : 0))
            // Invisible, keeping the line's height, so line numbers stay apart.
            if line.location != revealed.location, content.length > 0 {
                storage.addAttributes([.foregroundColor: NSColor.clear, .underlineStyle: 0], range: content)
            }
            storage.addAttribute(.orgImage, value: InlineImageBox(image: picture, size: CGSize(width: width, height: height)), range: NSRange(location: line.location, length: max(1, content.length)))
            let style = (storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            // The image sits where the line is; the spacing makes room for the rest of it.
            style.paragraphSpacing = max(0, height + 4 - theme.font.boundingRectForFont.height)
            storage.addAttribute(.paragraphStyle, value: style, range: line)
        }
    }

    // MARK: - Narrowing

    /// The text shown while narrowed (`org-narrow-to-subtree`, `org-narrow-to-block`); the
    /// rest is hidden until `widen`. Mapped through edits.
    public private(set) var narrowed: Range<Int>?

    private func narrow(_ id: String) {
        let caret = textView.selectedRange().location
        do {
            switch id {
            case "org.narrow.subtree": narrowed = try Narrowing.subtree(at: caret, in: textView.string)
            // `org-toggle-narrow-to-subtree`.
            case "org.narrow.toggle": narrowed = narrowed == nil ? try Narrowing.subtree(at: caret, in: textView.string) : nil
            case "org.narrow.block": narrowed = try Narrowing.block(at: caret, in: textView.string)
            default: narrowed = nil
            }
        } catch let failure as Narrowing.Failure {
            onMessage?(failure.message)
            return
        } catch {
            return
        }
        updateHidden()
        textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
        orgTextView?.redrawLineNumbers()
        textView.needsDisplay = true
        if let narrowed {
            setCaret(max(narrowed.lowerBound, min(caret, narrowed.upperBound)))
            textView.scrollRangeToVisible(NSRange(location: narrowed.lowerBound, length: 0))
        } else {
            textView.scrollRangeToVisible(NSRange(location: caret, length: 0))
        }
    }

    /// What narrowing hides: the text before the region, and the lines after it.
    private var narrowHidden: [Range<Int>] {
        guard let narrowed else { return [] }
        let length = utf16Length
        var ranges: [Range<Int>] = []
        if narrowed.lowerBound > 0 { ranges.append(0..<narrowed.lowerBound) }
        let ns = textView.string as NSString
        let tail = narrowed.upperBound < length && ns.character(at: narrowed.upperBound) == 10 ? narrowed.upperBound + 1 : narrowed.upperBound
        if tail < length { ranges.append(tail..<length) }
        return ranges
    }

    // MARK: - Shrunk table columns

    /// Narrowed table columns (`org-table-shrink`): by table start, each column's segments.
    /// Recomputed as the text changes; typing into one widens its column again, as editing
    /// org's overlays deletes them. Commands' edits keep columns narrow, as `org-table-align`
    /// shrinks them again.
    private var shrunk: [Int: [Int: [TableShrink.Segment]]] = [:]
    private var commandEditing = false

    /// Narrows `columns` of `table` and widens its others.
    private func setShrunk(_ columns: [Int], in table: Range<Int>) {
        let text = textView.string
        let segments = Dictionary(uniqueKeysWithValues: columns.map { ($0, TableShrink.segments(table, column: $0, in: text)) })
        shrunk[table.lowerBound] = segments.isEmpty ? nil : segments
        restyleOutsideEditing(table)
        textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
        textView.needsDisplay = true
    }

    /// C-c TAB in a table: `org-table-toggle-column-width`; `shrink` for `org-table-shrink`,
    /// `expand` for `org-table-expand`.
    private func tableColumnWidth(_ id: String) {
        let caret = textView.selectedRange().location
        let text = textView.string
        guard let table = TableShrink.table(at: caret, in: text) else {
            onMessage?("Not in a table")
            return
        }
        let current = shrunk[table.lowerBound].map { Array($0.keys) } ?? []
        switch id {
        case "org.table.shrink": setShrunk(TableShrink.cookieColumns(table, in: text), in: table)
        case "org.table.expand": setShrunk([], in: table)
        default:
            if let column = TableShrink.column(at: caret, in: text) {
                setShrunk(Array(Set(current).symmetricDifference([column])), in: table)
                return
            }
            let line = (text as NSString).lineRange(for: NSRange(location: caret, length: 0))
            onPrompt?(Prompt(key: "columns", message: "Column ranges (e.g. 2-4 6-):")) { [weak self] answer in
                guard let self, let answer else { return }
                self.setShrunk(Array(Set(current).symmetricDifference(TableShrink.columns(answer, max: line.length / 2))), in: table)
            }
        }
    }

    /// `#+STARTUP: shrink`: every table's columns with width cookies start narrow.
    private func shrinkAtStartup() {
        guard Presentation.startupOptions(document.tree).contains(where: { $0.lowercased() == "shrink" }) else { return }
        let text = textView.string
        var offset = 0
        let ns = text as NSString
        while offset < ns.length {
            let line = ns.lineRange(for: NSRange(location: offset, length: 0))
            defer { offset = max(NSMaxRange(line), offset + 1) }
            guard ns.substring(with: line).range(of: "^[ \\t]*\\|", options: .regularExpression) != nil,
                  let table = TableShrink.table(at: line.location, in: text) else { continue }
            let columns = TableShrink.cookieColumns(table, in: text)
            if !columns.isEmpty { shrunk[table.lowerBound] = Dictionary(uniqueKeysWithValues: columns.map { ($0, TableShrink.segments(table, column: $0, in: text)) }) }
            offset = table.upperBound
        }
    }

    /// Moves shrunk columns through `edit`; returns the tables to restyle.
    private func mapShrunk(through edit: TextEdit) -> [Range<Int>] {
        guard !shrunk.isEmpty else { return [] }
        let text = textView.string
        let delta = edit.replacement.utf16.count - edit.range.count
        var mapped: [Int: [Int: [TableShrink.Segment]]] = [:]
        var tables: [Range<Int>] = []
        for (start, columns) in shrunk {
            let kept = columns.filter { _, segments in
                commandEditing || !segments.contains { $0.range.lowerBound <= edit.range.upperBound && edit.range.lowerBound <= $0.range.upperBound }
            }.keys
            let touched = columns.values.joined().contains { $0.range.lowerBound <= edit.range.upperBound && edit.range.lowerBound <= $0.range.upperBound }
            let newStart = start < edit.range.lowerBound ? start : start >= edit.range.upperBound ? start + delta : edit.range.lowerBound
            guard let table = TableShrink.table(at: min(newStart, max(0, text.utf16.count - 1)), in: text) else { continue }
            if touched || kept.count != columns.count { tables.append(table) }
            guard !kept.isEmpty else { continue }
            mapped[table.lowerBound] = Dictionary(uniqueKeysWithValues: kept.map { ($0, TableShrink.segments(table, column: $0, in: text)) })
        }
        shrunk = mapped
        return tables
    }

    /// Hides each shrunk segment's text and draws its display where the text was.
    private func applyShrunk(_ range: Range<Int>, in storage: NSTextStorage) {
        guard !shrunk.isEmpty else { return }
        let cell = ("0" as NSString).size(withAttributes: [.font: theme.font]).width
        for segment in shrunk.values.flatMap({ $0.values.joined() }) where segment.range.overlaps(range) && segment.range.upperBound <= storage.length {
            let r = segment.range
            let shown = segment.display.count
            let kept = min(shown, r.count)
            if r.count > kept { storage.addAttributes(theme.hidden, range: NSRange(location: r.lowerBound, length: r.count - kept)) }
            guard kept > 0 else { continue }
            let visible = NSRange(location: r.upperBound - kept, length: kept)
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: visible)
            storage.addAttribute(.orgEntityDisplay, value: segment.display, range: NSRange(location: visible.location, length: 1))
            if shown > kept { storage.addAttribute(.kern, value: CGFloat(shown - kept) * cell, range: NSRange(location: NSMaxRange(visible) - 1, length: 1)) }
        }
    }

    /// Moves drawer and block folds through `edit`, checking again only those near it.
    private func mapWrapperFolds(through edit: TextEdit, near affected: Range<Int>) {
        guard !wrapperHidden.isEmpty else { return }
        var mapped: [Int: Range<Int>] = [:]
        let entries = Array(wrapperHidden)
        // One pass maps every start and range.
        let moved = ViewState(selection: entries.flatMap { [$0.key..<$0.key, $0.value] }).mapped(through: [edit]).selection
        for i in entries.indices {
            let newStart = moved[2 * i].lowerBound
            let newRange = moved[2 * i + 1]
            if newStart <= affected.upperBound, newRange.upperBound >= affected.lowerBound {
                if let wrapper = Wrappers.starting(at: newStart, in: document.tree) { mapped[newStart] = wrapper.hidden }
            } else {
                mapped[newStart] = newRange
            }
        }
        wrapperHidden = mapped
        view.wrapperFolds = Set(mapped.keys)
    }

    /// TAB on the first or last line of a drawer or block folds or unfolds it; on a heading,
    /// cycles folded, children, subtree. Returns false elsewhere.
    @discardableResult
    public func cycleAtCaret() -> Bool {
        leaveSparseTree()
        let caret = textView.selectedRange().location
        guard let state = Presentation.cycle(at: caret, in: document.tree, foldState) else { return false }
        setFolds(state)
        // Off a closing line that folding hid, to the opening line, as org does.
        if let wrapper = Wrappers.toggleable(at: caret, in: document.tree), hidden.containing(caret) != nil { setCaret(wrapper.start) }
        return true
    }

    /// Shift-TAB: overview, contents, show all.
    public func cycleGlobal() {
        leaveSparseTree()
        let (visibility, state) = Presentation.cycleGlobal(from: globalVisibility, in: document.tree, wrapperFolds: view.wrapperFolds)
        globalVisibility = visibility
        setFolds(state)
    }

    /// Unfolds whatever hides `offset`, puts the caret there and scrolls to it.
    public func reveal(_ offset: Int) {
        let target = max(0, min(offset, utf16Length))
        if let narrowed, !(narrowed.lowerBound...narrowed.upperBound).contains(target) { narrow("org.widen") }
        unfold(around: target)
        setCaret(target)
        textView.scrollRangeToVisible(NSRange(location: target, length: 0))
    }

    /// Unfolds the headings whose folds hide `offset`, leaving the selection alone.
    func unfold(around offset: Int) {
        leaveSparseTree()
        var state = foldState
        for entry in Presentation.outline(document.tree) where entry.start < offset && offset < entry.end {
            state.folds.remove(entry.start)
            state.bodyFolds.remove(entry.start)
        }
        for start in state.wrapperFolds where Wrappers.starting(at: start, in: document.tree)?.hidden.contains(offset) == true {
            state.wrapperFolds.remove(start)
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
        for run in Presentation.indents(document.tree, in: range) where indented {
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
        var scriptExclusions: [Range<Int>] = []
        for run in Presentation.styles(document.tree, in: range, highlighter: highlighter) {
            guard let clipped = clip(run.range, to: range) else { continue }
            if run.role == .leadingStars, !indented, !hideStars { continue }
            if !showMarkup, hides(run.role), NSIntersectionRange(clipped, revealed).length == 0 {
                storage.addAttributes(theme.hidden, range: clipped)
            } else {
                theme.apply(run.role, to: storage, range: clipped)
            }
            switch run.role {
            case .bold, .italic, .underline, .strikeThrough, .verbatim, .code, .link, .linkMarkup, .keyword: scriptExclusions.append(run.range)
            default: break
            }
        }
        if !showMarkup, options.prettyEntities { prettify(range, in: storage, revealed: revealed, scriptExclusions: scriptExclusions) }
        applyShrunk(range, in: storage)
        applyHighlights(range, in: storage)
        applyImages(range, in: storage, revealed: revealed)
    }

    /// `org-pretty-entities`: entities drawn as their character over the entity's last
    /// character (the rest hidden), sub/superscripts raised without their markers. Not on the
    /// caret's line, in comments or in blocks; sub/superscripts not in emphasis, links or
    /// keywords, as `org-raise-scripts` leaves them.
    private func prettify(_ range: Range<Int>, in storage: NSTextStorage, revealed: NSRange, scriptExclusions: [Range<Int>]) {
        let text = storage.string as NSString
        var location = range.lowerBound
        while location < range.upperBound {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            guard line.length > 0 else { break }
            location = NSMaxRange(line)
            if line.location == revealed.location || shaded.containing(line.location) != nil { continue }
            let content = text.substring(with: line)
            if content.range(of: "^[ \\t]*#([ +]|$)", options: .regularExpression) != nil { continue }
            for run in PrettyEntities.runs(in: content, subSuperscriptsNeedBraces: options.subSuperscriptsNeedBraces) {
                switch run {
                case .entity(let r, let display):
                    let start = line.location + r.lowerBound
                    let last = line.location + r.upperBound - 1
                    if last > start { storage.addAttributes(theme.hidden, range: NSRange(location: start, length: last - start)) }
                    storage.addAttributes([.foregroundColor: NSColor.clear, .orgEntityDisplay: display], range: NSRange(location: last, length: 1))
                case .script(let markers, let body, let superscript):
                    let bodyStart = line.location + body.lowerBound
                    if scriptExclusions.contains(where: { $0.contains(bodyStart) }) || body.isEmpty { continue }
                    for marker in markers {
                        storage.addAttributes(theme.hidden, range: NSRange(location: line.location + marker.lowerBound, length: marker.count))
                    }
                    let size = theme.font.pointSize
                    storage.addAttributes([
                        .font: NSFont.monospacedSystemFont(ofSize: size * 0.7, weight: .regular),
                        .baselineOffset: (superscript ? 0.3 : -0.3) * size,
                    ], range: NSRange(location: bodyStart, length: body.count))
                }
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

    private var blockCheck: DispatchWorkItem?

    /// Looks for blocks over the whole file once typing pauses, catching what moving the
    /// ranges can't see (a block's end found far away).
    private func scheduleBlockCheck() {
        blockCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settleBlocks() }
        blockCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func settleBlocks() {
        blockCheck?.cancel()
        guard isOrg else { return }
        let blocks = Presentation.shadedBlocks(document.tree)
        guard blocks != shaded.all else { return }
        shaded.set(blocks)
        textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
    }

    /// Whether the lines around `range`, and the line after it (a deleted newline joins it to
    /// them), hold a block delimiter or a fixed-width line.
    static func mayChangeBlocks(_ text: NSString, _ range: Range<Int>) -> Bool {
        let start = min(range.lowerBound, text.length)
        let end = min(range.upperBound + 1, text.length)
        let lines = text.lineRange(for: NSRange(location: start, length: end - start))
        let content = text.substring(with: lines)
        return content.contains("#+") || content.range(of: "(^|\\n)([ \\t]*:|\\*)", options: .regularExpression) != nil
    }

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
        let newAffected = Self.affectedRange(document.tree, newText, edit.range.lowerBound, newEnd, touchedHeadings: touchedHeadings)
        let delta = edit.replacement.utf16.count - edit.range.count
        let oldMapped = oldAffected.lowerBound..<(oldAffected.upperBound >= edit.range.upperBound ? oldAffected.upperBound + delta : newEnd)
        view = view.mapped(through: [edit]).pruned(to: document.tree, wrappers: false)
        mapWrapperFolds(through: edit, near: min(oldMapped.lowerBound, newAffected.lowerBound)..<max(oldMapped.upperBound, newAffected.upperBound))
        if let narrowed { self.narrowed = ViewState(selection: [narrowed]).mapped(through: [edit]).selection[0] }
        mapVimPositions(through: edit)
        if let sparse = sparseHidden { sparseHidden = ViewState(selection: sparse).mapped(through: [edit]).selection.filter { !$0.isEmpty } }
        let oldHighlights = ViewState(selection: highlights).mapped(through: [edit]).selection
        highlights = []
        updateHidden()
        restyle(min(oldMapped.lowerBound, newAffected.lowerBound)..<min(max(oldMapped.upperBound, newAffected.upperBound), newText.length), in: storage)
        for table in mapShrunk(through: edit) { restyle(table.lowerBound..<min(table.upperBound, newText.length), in: storage) }
        for range in oldHighlights where range.upperBound <= newText.length {
            let lines = newText.lineRange(for: NSRange(range))
            restyle(lines.location..<NSMaxRange(lines), in: storage)
        }
        let oldShaded = shaded.all
        if isOrg {
            // Walking the tree for blocks costs more than typing; only an edit on a line that
            // could start or end one (`#+…`, `: …`) needs it, others move the ranges.
            if Self.mayChangeBlocks(oldText, edit.range) || Self.mayChangeBlocks(newText, edit.range.lowerBound..<newEnd) {
                shaded.set(Presentation.shadedBlocks(document.tree))
            } else {
                shaded.set(oldShaded.map { mapRange($0, through: edit) })
            }
            scheduleBlockCheck()
        }
        if hidden.all != oldHidden.map({ mapRange($0, through: edit) })
            || shaded.all != oldShaded.map({ mapRange($0, through: edit) }) {
            textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
        }
        onEditTiming?(clock.now - start)
        let lineCount = lines.lineCount
        lines.replace(edit.range, newLength: edit.replacement.utf16.count, in: newText)
        if lines.lineCount != lineCount { orgTextView?.updateGutter() }
        orgTextView?.redrawLineNumbers()
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
    func selectionChanged() {
        let selection = textView.selectedRange()
        defer { previousSelection = selection.location }
        onSelectionChange?(selection)
        revealCaretLine()
        orgTextView?.redrawLineNumbers()
        // Narrowing keeps the caret in the region.
        if let narrowed, selection.length == 0, !(narrowed.lowerBound...narrowed.upperBound).contains(selection.location) {
            setCaret(max(narrowed.lowerBound, min(selection.location, narrowed.upperBound)))
            return
        }
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
            setFolds(FoldState(folds: mapped.folds, bodyFolds: mapped.bodyFolds, wrapperFolds: mapped.wrapperFolds))
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

extension OrgEditor: NSTextStorageDelegate {
    public nonisolated func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int
    ) {
        MainActor.assumeIsolated { storageGeneration += 1 }
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
            if let paragraph = textElement as? NSTextParagraph, ImageFragment.image(paragraph.attributedString) != nil {
                return ImageFragment(textElement: textElement, range: range)
            }
            if let paragraph = textElement as? NSTextParagraph, EntityFragment.hasEntities(paragraph.attributedString) {
                return EntityFragment(textElement: textElement, range: range)
            }
        }
        return NSTextLayoutFragment(textElement: textElement, range: range)
    }
}

/// A line of a block, on a band across the whole width of the view, as Emacs extends the
/// `org-block` face.
final class ShadedFragment: NSTextLayoutFragment, @unchecked Sendable {
    private var band: CGRect {
        let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        // Not under the empty line TextKit adds after a final newline.
        let height = textLineFragments.last { $0.characterRange.length > 0 }?.typographicBounds.maxY ?? layoutFragmentFrame.height
        return CGRect(x: -layoutFragmentFrame.minX, y: 0, width: width, height: height)
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

extension NSAttributedString.Key {
    /// The character an entity shows as, on the entity's last character.
    static let orgEntityDisplay = NSAttributedString.Key("OrgEntityDisplay")
    /// The image an image link's line shows under it.
    static let orgImage = NSAttributedString.Key("OrgImage")
}

final class InlineImageBox: NSObject, @unchecked Sendable {
    let image: NSImage
    let size: CGSize
    init(image: NSImage, size: CGSize) {
        self.image = image
        self.size = size
    }
}

/// An image link's line drawn as the image, with the paragraph spacing making room for its
/// height.
final class ImageFragment: NSTextLayoutFragment, @unchecked Sendable {
    static func image(_ string: NSAttributedString) -> InlineImageBox? {
        var found: InlineImageBox?
        string.enumerateAttribute(.orgImage, in: NSRange(location: 0, length: string.length)) { value, _, stop in
            if let box = value as? InlineImageBox { found = box; stop.pointee = true }
        }
        return found
    }

    private var frame: CGRect? {
        guard let box = (textElement as? NSTextParagraph).flatMap({ Self.image($0.attributedString) }), let line = textLineFragments.first else { return nil }
        return CGRect(x: line.typographicBounds.minX, y: line.typographicBounds.minY + 2, width: box.size.width, height: box.size.height)
    }

    override var renderingSurfaceBounds: CGRect {
        frame.map { super.renderingSurfaceBounds.union($0) } ?? super.renderingSurfaceBounds
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let box = (textElement as? NSTextParagraph).flatMap({ Self.image($0.attributedString) }), let frame else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        box.image.draw(in: frame.offsetBy(dx: point.x, dy: point.y), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A paragraph with pretty entities: each is drawn as its character where the entity's last
/// (now invisible) character sits, so it takes one column as in Emacs.
final class EntityFragment: NSTextLayoutFragment, @unchecked Sendable {
    static func hasEntities(_ string: NSAttributedString) -> Bool {
        var found = false
        string.enumerateAttribute(.orgEntityDisplay, in: NSRange(location: 0, length: string.length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        Self.drawEntities(of: self, at: point, in: context)
    }

    static func drawEntities(of fragment: NSTextLayoutFragment, at point: CGPoint, in context: CGContext) {
        guard let string = (fragment.textElement as? NSTextParagraph)?.attributedString else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        string.enumerateAttribute(.orgEntityDisplay, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            guard let display = value as? String,
                  let line = fragment.textLineFragments.first(where: { NSLocationInRange(range.location, $0.characterRange) }) else { return }
            var attributes = string.attributes(at: range.location, effectiveRange: nil)
            attributes[.foregroundColor] = NSColor.textColor
            attributes[.orgEntityDisplay] = nil
            let x = line.locationForCharacter(at: range.location).x
            let bounds = line.typographicBounds
            NSAttributedString(string: display, attributes: attributes).draw(at: CGPoint(x: point.x + bounds.minX + x, y: point.y + bounds.minY))
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A heading line drawn with an ellipsis after it, like org's folded headings.
final class FoldedHeadingFragment: NSTextLayoutFragment, @unchecked Sendable {
    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        EntityFragment.drawEntities(of: self, at: point, in: context)
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
