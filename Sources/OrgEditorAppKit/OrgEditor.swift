#if os(macOS)
import AppKit
import OrgCore
import OrgDocument
import OrgPresentation

/// A TextKit 2 text view over a `DocumentState`. The text storage mirrors the document; every
/// character edit goes through `DocumentState.apply`, and only the affected region is restyled.
///
/// The editor is the buffer: text, undo, folds, narrowing, sparse trees and evil state are its,
/// as they are a buffer's in Emacs. It can show in several text views at once (`addView`),
/// each with its own caret, scroll position and focus, as windows show a buffer.
@MainActor
public final class OrgEditor: NSObject {
    /// The text view commands act on: the one with focus, or the last to have had it.
    public var textView: NSTextView { active }
    private(set) var active: OrgTextView
    /// Every text view on the storage; the first was made with the editor.
    public private(set) var textViews: [NSTextView] = []
    var orgTextViews: [OrgTextView] { textViews.compactMap { $0 as? OrgTextView } }
    var layoutManagers: [NSTextLayoutManager] { textViews.compactMap(\.textLayoutManager) }
    /// One undo history for the buffer, whichever view edits it.
    public let undoManager = UndoManager()
    public private(set) var document: DocumentState
    public internal(set) var view = ViewState()
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
            keepingTopLine {
                applyThemeToView()
                restyleEverything()
                invalidateAllLayout()
            }
        }
    }
    private var isLoading = false
    var previousSelection = 0
    /// The selection shaded block lines last drew.
    private var previousSelectionRange = NSRange(location: 0, length: 0)
    /// Text before this offset is styled; after it, only base attributes until the background
    /// passes reach it. Always at a line start.
    private(set) var styledUpTo = 0
    private var stylingScheduled = false
    /// One paragraph style object per indent pair, shared by every line that uses it.
    var paragraphStyles: [IndentKey: NSParagraphStyle] = [:]

    struct IndentKey: Hashable {
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
    var codeRuns: (revision: Int, runs: [(range: Range<Int>, category: SyntaxCategory)])?

    public init(
        document: DocumentState, frame: NSRect = NSRect(x: 0, y: 0, width: 600, height: 800), editable: Bool = true,
        highlighter: (any CodeHighlighter)? = nil, mode: Mode = .org, options: EditingOptions = .org
    ) {
        self.document = document
        self.options = options
        self.highlighter = highlighter
        self.mode = mode
        let orgTextView = OrgTextView(usingTextLayoutManager: true)
        active = orgTextView
        textViews = [orgTextView]
        dispatcher = KeyDispatcher(keymap: KeymapPreset.emacs.keymap)
        super.init()
        configure(orgTextView, frame: frame, editable: editable)
        applyThemeToView()
        textView.textStorage?.delegate = self
        textContentStorage.delegate = self

        if isOrg { shaded.set(Presentation.shadedBlocks(document.tree)) }
        load(document.text)
        // Files open at their start, as in Emacs; replacing the storage leaves it at the end.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        if isOrg {
            let startup = Presentation.startupDisplay(document.tree, options: options)
            indented = startup.indented
            hideStars = startup.hideStars
            if startup.folds != FoldState() { setFolds(startup.folds, wrappers: startup.wrappers) }
            shrunk = ShrunkColumns.startup(document.tree)
            if startup.inlineImages { showsImages = true }
            if startup.alignTables { _ = perform(AlignAllTables()) }
            if !indented || !hideStars { restyleOutsideEditing(0..<utf16Length) }
        }
        spellChecking = options.spellCheck
        truncatesLines = options.startupTruncated
    }

    /// A text view's settings and callbacks; the same for every view of the editor.
    private func configure(_ view: OrgTextView, frame: NSRect, editable: Bool) {
        view.keyHandler = { [weak self, unowned view] event in
            guard let self else { return false }
            self.active = view
            return self.handleKey(event)
        }
        view.onFocusChange = { [weak self, unowned view] in
            guard let self, let layout = view.textLayoutManager else { return }
            let id = ObjectIdentifier(layout)
            if view.window?.firstResponder === view { self.active = view }
            if let window = view.window, window.isKeyWindow, window.firstResponder === view {
                Theme.focusedLayouts.insert(id)
            } else {
                Theme.focusedLayouts.remove(id)
            }
            self.redrawShaded([view.selectedRange()])
        }
        view.onCommandClick = { [weak self, unowned view] offset in
            guard let self, Links.link(at: offset, text: self.document.text, tree: self.document.tree) != nil
                || Links.timestampDays(at: offset, text: self.document.text) != nil else { return false }
            self.active = view
            self.setCaret(offset)
            self.run("org.link.open")
            return true
        }
        view.onClick = { [weak self, unowned view] offset in
            self?.active = view
            return self?.click(at: offset) ?? false
        }
        view.accessibleText = { [weak self] in
            guard let self, let storage = self.textView.textStorage else { return AccessibleText(NSAttributedString()) }
            if let cached = self.accessibleCache, cached.storage == self.storageGeneration { return cached.text }
            let text = AccessibleText(storage)
            self.accessibleCache = (self.storageGeneration, text)
            return text
        }
        view.onMouseDown = { [weak self, unowned view] in
            self?.active = view
            self?.markActive = false
            self?.modalMouseDown()
        }
        view.sharedUndoManager = undoManager
        view.usesFindBar = true
        view.frame = frame
        view.isRichText = false
        view.isEditable = editable
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.delegate = self
        view.textLayoutManager?.delegate = self
    }

    /// Another text view on the same text, with its own layout, caret and scroll position.
    /// Its layout manager's delegate is set before its first layout, which TextKit needs.
    public func addView(frame: NSRect = NSRect(x: 0, y: 0, width: 600, height: 800)) -> NSTextView {
        let layout = NSTextLayoutManager()
        layout.delegate = self
        textContentStorage.addTextLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude))
        layout.textContainer = container
        let view = OrgTextView(frame: frame, textContainer: container)
        textViews.append(view)
        configure(view, frame: frame, editable: active.isEditable)
        view.lineIndex = lines
        view.showsLineNumbers = showLineNumbers
        view.isContinuousSpellCheckingEnabled = active.isContinuousSpellCheckingEnabled
        view.blockCursor = active.blockCursor
        applyThemeToView()
        return view
    }

    /// Takes a view made by `addView` off the storage. The first view stays.
    public func removeView(_ view: NSTextView) {
        guard let index = textViews.firstIndex(where: { $0 === view }), index > 0 else { return }
        textViews.remove(at: index)
        if active === view { active = orgTextViews[0] }
        if let layout = view.textLayoutManager {
            Theme.focusedLayouts.remove(ObjectIdentifier(layout))
            textContentStorage.removeTextLayoutManager(layout)
        }
    }

    /// Lays every view out again.
    func invalidateAllLayout() {
        for layout in layoutManagers { layout.invalidateLayout(for: layout.documentRange) }
    }

    /// Redraws every view, line numbers included.
    func redrawViews() {
        for view in orgTextViews {
            view.redrawLineNumbers()
            view.needsDisplay = true
        }
    }

    /// Replaces the storage's text. Setting the attributed string directly is about 100x
    /// faster than `NSTextView.string` for large files.
    private func load(_ text: String) {
        isLoading = true
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: theme.base))
        isLoading = false
        lines.reset(text as NSString)
        for view in orgTextViews {
            view.lineIndex = lines
            view.updateGutter()
        }
        styledUpTo = 0
        styleNextChunk(Self.firstStyleChunk)
        scheduleStyling()
    }

    // MARK: - Initial styling

    /// Styles whole lines from the watermark onward, about `size` units.
    func styleNextChunk(_ size: Int) {
        let text = textView.textStorage!.string as NSString
        guard styledUpTo < text.length else { return }
        let target = min(text.length, styledUpTo + size)
        let end = target == text.length ? target : NSMaxRange(text.lineRange(for: NSRange(location: target, length: 0)))
        restyleOutsideEditing(styledUpTo..<end)
        styledUpTo = end
    }

    /// Every text view's own colors and font, and the line numbers'.
    private func applyThemeToView() {
        Theme.selection = theme.color("selection") ?? .selectedTextBackgroundColor
        for view in orgTextViews {
            view.font = theme.font
            view.typingAttributes = theme.base
            view.drawsBackground = true
            view.backgroundColor = theme.color("background") ?? .textBackgroundColor
            view.insertionPointColor = theme.color("cursor") ?? .textColor
            view.selectedTextAttributes = [.backgroundColor: Theme.selection]
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

    var caretLine: NSRange {
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

    /// A scroll view holding `view` (the active text view by default), ready for a window.
    public func makeScrollView(for view: NSTextView? = nil) -> NSScrollView {
        let textView = view ?? self.textView
        let scroll = NSScrollView(frame: textView.frame)
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        (textView as? OrgTextView)?.showsLineNumbers = showLineNumbers
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
        didSet { for view in orgTextViews { view.showsLineNumbers = showLineNumbers } }
    }
    var orgTextView: OrgTextView? { textView as? OrgTextView }

    /// The line last revealed while markup is hidden, to hide again when the caret leaves.
    var revealedLine: NSRange?
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
    /// Vim's lowercase marks, mapped through edits.
    var vimMarks: [Character: Int] = [:]
    /// Uppercase marks, with the editor each is in: global, as evil's file marks are.
    static var fileMarks: [Character: (owner: WeakEditor, offset: Int)] = [:]
    /// Registers and keyboard macros, shared by every editor as evil's are global.
    static var vimRegisters: [Character: (text: String, linewise: Bool)] = [:]
    static var vimClipboardRecord: (text: String, linewise: Bool)?
    static var macros: [Character: [KeyChord]] = [:]
    /// Shows `editor`'s buffer with the caret at the offset, for a jump to a file mark set
    /// there.
    public var onJumpToEditor: ((OrgEditor, Int) -> Void)?
    /// Jump positions, oldest first, mapped through edits; `jumpIndex` is where C-o and C-i are.
    var jumpList: [Int] = []
    var jumpIndex = 0
    /// The register keys go into while `q` records, and its keys so far.
    var recordingRegister: Character?
    var recordedKeys: [KeyChord] = []
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
            let context = context()
            let next = keymap.continuations(of: keys) { runs($0, in: context) }.map { item in
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
            let runnable = candidates.first { runs($0, in: context) }
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

    /// Whether a key's `binding` runs in `context`: its context holds and its command applies.
    private func runs(_ binding: KeyBinding, in context: EditContext) -> Bool {
        (binding.when.map { KeyContext.holds($0, in: context) } ?? true) && applies(binding.command, in: context)
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
            case "org.fold.toggle", "org.fold.open", "org.fold.close": fold(id)
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

    var globalVisibility: GlobalVisibility?
    /// What each folded drawer and block hides, by opening-line start; kept in step with
    /// `view.wrapperFolds` and mapped through edits.
    var wrapperHidden: [Int: Range<Int>] = [:]

    // MARK: - Sparse trees

    /// What a sparse tree (`org-sparse-tree`) hides, replacing heading folds until the next
    /// fold change. Mapped through edits.
    var sparseHidden: [Range<Int>]?
    /// Sparse tree matches, highlighted until the next edit or C-c C-c.
    var highlights: [Range<Int>] = []

    // MARK: - STARTUP display

    /// `org-indent-mode`: headings' bodies indented under their titles (`#+STARTUP: indent`).
    var indented = true
    /// `org-hide-leading-stars` (`#+STARTUP: hidestars`); org-indent hides them as well.
    var hideStars = false

    // MARK: - Inline images

    /// `org-toggle-inline-images`: lines that are only an image link show the image.
    public internal(set) var showsImages = false
    /// The file's folder, for relative image paths.
    public var baseDirectory: URL? {
        didSet { if showsImages, oldValue != baseDirectory { refreshImages() } }
    }

    // MARK: - Narrowing

    /// The text shown while narrowed (`org-narrow-to-subtree`, `org-narrow-to-block`); the
    /// rest is hidden until `widen`. Mapped through edits.
    public internal(set) var narrowed: Range<Int>?

    // MARK: - Shrunk table columns

    /// Narrowed table columns (`org-table-shrink`).
    var shrunk = ShrunkColumns()
    private var commandEditing = false

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
        let old = shaded.all
        shaded.set(blocks)
        invalidateLayout(from: old, to: blocks)
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
        for table in shrunk.map(through: edit, in: storage.string, command: commandEditing) { restyle(table.lowerBound..<min(table.upperBound, newText.length), in: storage) }
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
        invalidateLayout(from: oldHidden.map { mapRange($0, through: edit) }, to: hidden.all)
        invalidateLayout(from: oldShaded.map { mapRange($0, through: edit) }, to: shaded.all)
        onEditTiming?(clock.now - start)
        let lineCount = lines.lineCount
        lines.replace(edit.range, newLength: edit.replacement.utf16.count, in: newText)
        for view in orgTextViews {
            if lines.lineCount != lineCount { view.updateGutter() }
            view.redrawLineNumbers()
        }
        onChange?()
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

    /// Shaded block lines the old or new selection covers are drawn again, as they draw the
    /// selection over their band.
    private func redrawShadedSelection(_ selection: NSRange) {
        defer { previousSelectionRange = selection }
        redrawShaded([previousSelectionRange, selection])
    }

    private func redrawShaded(_ ranges: [NSRange]) {
        let manager = textContentStorage
        for old in ranges where old.length > 0 {
            for block in shaded.all where block.overlaps(old.location..<NSMaxRange(old)) {
                let lower = max(block.lowerBound, old.location)
                let upper = min(block.upperBound, NSMaxRange(old))
                guard let start = manager.location(manager.documentRange.location, offsetBy: lower),
                      let end = manager.location(start, offsetBy: upper - lower),
                      let range = NSTextRange(location: start, end: end) else { continue }
                for layout in layoutManagers { layout.invalidateLayout(for: range) }
            }
        }
    }

    /// Keeps the caret out of folded text: moving forward into a fold jumps past it, moving
    /// back jumps to the end of the heading line.
    func selectionChanged() {
        let selection = textView.selectedRange()
        defer { previousSelection = selection.location }
        redrawShadedSelection(selection)
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

    /// Runs `change`; if it changed the text, reloads the views with folds and each view's
    /// selection mapped through the change. Undo refers to the old text, so it is cleared.
    public func update<T>(_ change: (inout DocumentState) throws -> T) rethrows -> T {
        let before = document.text
        let defaultsBefore = document.defaults
        let selections = textViews.map(\.selectedRange)
        let result = try change(&document)
        if document.text != before {
            let edits = lineEdits(from: before, to: document.text)
            var state = view
            state.selection = selections.map { $0.location..<NSMaxRange($0) }
            let mapped = state.mapped(through: edits)
            // Shrunk columns were measured on the old text.
            shrunk = ShrunkColumns()
            load(document.text)
            setFolds(FoldState(folds: mapped.folds, bodyFolds: mapped.bodyFolds, wrapperFolds: mapped.wrapperFolds))
            for (view, selection) in zip(textViews, mapped.selection) {
                if view === active { setCaret(selection.lowerBound) } else { view.setSelectedRange(NSRange(location: selection.lowerBound, length: 0)) }
                if !selection.isEmpty { view.setSelectedRange(NSRange(selection)) }
            }
            undoManager.removeAllActions()
        } else if document.defaults != defaultsBefore {
            // New settings for the same text: TODO keywords may color differently.
            restyleEverything()
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
#endif
