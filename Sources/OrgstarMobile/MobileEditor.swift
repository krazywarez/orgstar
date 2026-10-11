#if os(iOS)
import OrgApp
import OrgCore
import OrgDocument
import OrgHighlight
import OrgPresentation
import UIKit

/// The iOS editor: a TextKit 2 text view that is the open file's live state, as the Mac's
/// `OrgEditor` is. Typing and undo go through the text view and into the document; commands
/// run on the document and apply their edits as one undo step; headings, drawers and blocks
/// fold as TAB cycles them.
@MainActor
final class MobileEditor: NSObject, DocumentBuffer {
    /// One highlighter for every editor and the reader: it caches compiled grammars and results.
    static let highlighter = TreeSitterHighlighter()
    private(set) var document: DocumentState
    let textView: UITextView
    var options: EditingOptions = .org {
        didSet {
            textView.spellCheckingType = options.spellCheck ? .yes : .no
            if !showMarkup, options.hideEmphasisMarkers != oldValue.hideEmphasisMarkers || options.prettyEntities != oldValue.prettyEntities {
                restyleAll()
            }
        }
    }
    /// Colors and type; a change, or a new Dynamic Type size, restyles the file.
    var themeSpec: ThemeSpec {
        get { theme.spec }
        set {
            let new = MobileTheme(newValue)
            guard new.spec != theme.spec || new.font != theme.font else { return }
            theme = new
            paragraphStyles = [:]
            applyThemeToView()
            restyleAll()
        }
    }
    /// Link brackets and targets, and emphasis markers when `org-hide-emphasis-markers` hides
    /// them, shown. Hidden markup shows on the caret's line, so it can be edited.
    var showMarkup = true {
        didSet { if showMarkup != oldValue { restyleAll() } }
    }
    var keymap = KeymapPreset.emacs.keymap {
        didSet { dispatcher = KeyDispatcher(keymap: keymap) }
    }
    /// The Doom preset's modal editing, and its state: the engine, the caret in visual
    /// states, marks, the jump list, what insert state began with, and macros.
    var modal = false {
        didSet {
            if modal != oldValue { vim = Vim() }
            updateCursor()
        }
    }
    var vim = Vim()
    var visualCaret: Int?
    var vimMarks: [Character: Int] = [:]
    var jumpList: [Int] = []
    var jumpIndex = 0
    var insertSnapshot: String?
    var recordingRegister: Character?
    var recordedKeys: [KeyChord] = []
    var replayingMacro = 0
    static var vimRegisters: [Character: (text: String, linewise: Bool)] = [:]
    static var vimClipboardRecord: (text: String, linewise: Bool)?
    static var macros: [Character: [KeyChord]] = [:]
    /// What `:`, `/` and `?` read, oldest first, for `q:`.
    static var promptHistory: [String: [String]] = [:]
    var onChange: (() -> Void)?
    var onMessage: ((String) -> Void)?
    var onPrompt: ((Prompt, @escaping (String?) -> Void) -> Void)?
    var onLink: ((OrgLink) -> Void)?
    /// Edits being applied, which the typing hooks leave alone.
    private var applyingEdits = false
    /// Source blocks to write to their files (C-c C-v t).
    var onTangle: ((Tangle.Scope) -> Void)?
    /// A source block to run (C-c C-c).
    var onBabel: ((BabelJob) -> Void)?
    /// The file's setup files to read again (C-c C-c on a keyword line).
    var onRefreshSetup: (() -> Void)?
    /// A block, a table's formulas or a field to edit apart (C-c ', C-c `).
    var onEditBlock: ((BlockEdit) -> Void)?
    /// A followed timestamp's agenda days: the first (a `Days` number) and how many.
    var onAgenda: ((Int, Int) -> Void)?
    /// Shows a column view.
    var onColumnView: ((ColumnView.View) -> Void)?
    /// Commands the app runs, as `app.clock.in`.
    var onAppCommand: ((String) -> Void)?
    /// Tags used across the workspace, for completion.
    var knownTags: @Sendable () -> [String] = { [] }

    var theme: MobileTheme
    internal(set) var fold = FoldState()
    var globalVisibility: GlobalVisibility?
    let hidden = LockedRanges()
    /// Blocks drawn on a band.
    let shaded = LockedRanges()
    let fragmentStyle = FragmentStyle()
    var selectionColor: UIColor = .clear
    /// `org-indent-mode` and `org-hide-leading-stars`, from the settings and `#+STARTUP`.
    var indented = true
    var hideStars = false
    /// One paragraph style per indent pair.
    var paragraphStyles: [[Int]: NSParagraphStyle] = [:]
    /// The line last revealed while markup is hidden, to hide again when the caret leaves.
    var revealedLine: NSRange?
    /// `org-toggle-inline-images`: lines that are only an image link show the image.
    internal(set) var showsImages = false
    /// `org-latex-preview`: LaTeX fragments show as typeset math.
    internal(set) var showsLatex = false
    /// The view width images were last sized for.
    var imageWidth: CGFloat = 0
    /// The file's folder, for relative image paths.
    let baseDirectory: URL?
    static let imageCache = NSCache<NSString, UIImage>()
    var loading = false
    var restyleScheduled: Range<Int>?
    /// Narrowed table columns (`org-table-shrink`).
    var shrunk = ShrunkColumns()
    /// A command's edits being applied, which keep shrunk columns narrow.
    private var commandEditing = false

    init(
        document: DocumentState, editable: Bool, options: EditingOptions = .org, theme spec: ThemeSpec = .default,
        showMarkup: Bool = true, baseDirectory: URL? = nil
    ) {
        self.document = document
        self.options = options
        self.showMarkup = showMarkup
        self.baseDirectory = baseDirectory
        theme = MobileTheme(spec)
        let keyed = KeyedTextView(usingTextLayoutManager: true)
        textView = keyed
        super.init()
        keyed.keyHandler = { [weak self] key in self?.handleKey(key) ?? false }
        keyed.onLayout = { [weak self] in self?.viewResized() }
        textView.isEditable = editable
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = options.spellCheck ? .yes : .no
        textView.keyboardDismissMode = .interactive
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 24, right: 8)
        textView.delegate = self
        textView.textStorage.delegate = self
        textView.textLayoutManager?.delegate = self
        (textView.textLayoutManager?.textContentManager as? NSTextContentStorage)?.delegate = self
        let foldTap = UITapGestureRecognizer(target: self, action: #selector(tappedFold))
        foldTap.delegate = self
        textView.addGestureRecognizer(foldTap)
        let startup = Presentation.startupDisplay(document.tree, options: options)
        indented = startup.indented
        hideStars = startup.hideStars
        showsImages = startup.inlineImages
        showsLatex = startup.latexPreview
        shrunk = ShrunkColumns.startup(document.tree)
        applyThemeToView()
        load(document.text)
        setFolds(startup.folds)
        if startup.alignTables { _ = perform(AlignAllTables()) }
        truncatesLines = startup.truncated
        textView.selectedRange = NSRange(location: 0, length: 0)
    }

    // MARK: - DocumentBuffer

    var selection: [Range<Int>] {
        let selected = textView.selectedRange
        return [selected.location..<NSMaxRange(selected)]
    }

    func update<T>(_ change: (inout DocumentState) throws -> T) rethrows -> T {
        let before = document.text
        let defaultsBefore = document.defaults
        let selected = textView.selectedRange
        let result = try change(&document)
        if document.text != before {
            // A save that merged a change from disk, or a revert: the view shows the new text.
            shrunk = ShrunkColumns()
            load(document.text)
            let length = (document.text as NSString).length
            textView.selectedRange = NSRange(location: min(selected.location, length), length: 0)
            textView.undoManager?.removeAllActions()
            setFolds(fold)
        } else if document.defaults != defaultsBefore {
            restyle(0..<(document.text as NSString).length)
        }
        return result
    }

    func perform(_ command: any OrgCommand, now: Date = Date(), answers: [String: String] = [:]) -> CommandStep {
        let context = EditContext(
            revision: document.revision, text: document.text, tree: document.tree, selection: selection,
            now: now, answers: answers, hidden: hidden.all, options: options, knownTags: knownTags
        )
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
            if let selected = result.selection?.first {
                unfold(around: selected.lowerBound)
                textView.selectedRange = NSRange(location: selected.lowerBound, length: selected.count)
                textView.scrollRangeToVisible(textView.selectedRange)
            }
            for effect in result.effects {
                switch effect {
                case .message(let text): onMessage?(text)
                case .fold(let start):
                    var state = fold
                    state.folds.insert(start)
                    setFolds(state)
                case .refreshSetup: onRefreshSetup?()
                default: break
                }
            }
        case .failed(let message):
            onMessage?(message)
        case .prompt(let prompt):
            onPrompt?(prompt) { [weak self] answer in
                guard let self else { return }
                guard let answer else { return self.onMessage?("Quit") ?? () }
                _ = self.perform(command, now: now, answers: answers.merging([prompt.key: answer]) { $1 })
            }
        case .external(.editBlock(let edit)) where onEditBlock != nil:
            onEditBlock?(edit)
        case .external(.babel(let job)) where onBabel != nil:
            onBabel?(job)
        case .external(.tangle(let scope)) where onTangle != nil:
            onTangle?(scope)
        case .external(.agenda(let start, let count)) where onAgenda != nil:
            onAgenda?(start, count)
        case .external(.columnView(let view)) where onColumnView != nil:
            onColumnView?(view)
        case .external(let request):
            onMessage?(Self.unavailable(request, title: command.title))
        }
        return step
    }

    /// Why a request the app doesn't handle did nothing: only table recalculation needs Emacs.
    static func unavailable(_ request: ExternalRequest, title: String) -> String {
        if case .emacsTable(_, _, _, let reason, _) = request { return "This table needs Emacs, which runs on the Mac: \(reason)." }
        return "\(title) isn't available on iPhone and iPad."
    }

    // MARK: - Commands by name and key

    /// Runs what `keys` (as `C-c C-t`) is bound to in the Emacs keymap, for the caret's context.
    func run(keys: String) {
        guard let chords = KeySequence.parse(keys) else { return }
        let context = editContext()
        let binding = keymap.candidates(for: chords).first { binding in
            (binding.when.map { KeyContext.holds($0, in: context) } ?? true) && applies(binding.command, in: context)
        }
        guard let binding else { return onMessage?("Nothing to do here") ?? () }
        run(binding.command)
    }

    func run(_ id: String) {
        switch id {
        case "org.cycle":
            if !cycleAtCaret() { onMessage?("Not on a heading, drawer or block") }
        case "org.cycle-global": cycleGlobal()
        case "org.link.open": openLinkAtCaret()
        case "org.toggle-inline-images": toggleImages()
        case "org.latex-preview": toggleLatex()
        case "editor.toggle-truncate-lines":
            truncatesLines.toggle()
            onMessage?(truncatesLines ? "Truncate long lines enabled" : "Truncate long lines disabled")
        case "edit.undo": textView.undoManager?.undo()
        case "edit.redo": textView.undoManager?.redo()
        case "org.table.toggle-column-width", "org.table.shrink", "org.table.expand": tableColumnWidth(id)
        case _ where id.hasPrefix("app.") || Self.linkCommands.contains(id):
            if let onAppCommand { onAppCommand(id) } else { onMessage?("Not available on iOS yet") }
        default:
            if let command = Commands.command(id) {
                _ = perform(command)
            } else {
                onMessage?("Not available on iOS yet")
            }
        }
    }

    /// Link commands that need the stored links or the file, which the screen has.
    static let linkCommands: Set<String> = ["org.link.store", "org.id.store-link", "org.link.insert"]

    func applies(_ id: String, in context: EditContext) -> Bool {
        if let command = Commands.command(id) { return command.applies(in: context) }
        switch id {
        case "org.cycle":
            return Presentation.heading(containing: context.caret, in: context.tree) != nil || Wrappers.toggleable(at: context.caret, in: context.tree) != nil
        case "org.cycle-global", "edit.undo", "edit.redo", "org.toggle-inline-images", "org.latex-preview", "editor.toggle-truncate-lines": return true
        case "app.clock.in", "app.clock.out", "app.clock.cancel", "app.clock.goto", "app.clock.in-recent", "app.clock.in-last",
             "app.clock.goto-recent", "app.clock.default", "app.clock.resolve", "app.toggle-markup": return onAppCommand != nil
        case "app.refile.goto", "app.table-import": return onAppCommand != nil
        case "app.table-export", "app.plot": return onAppCommand != nil && ImportTable.exportText(context.text, at: context.caret, path: "") != nil
        case "app.refile", "app.refile.copy": return onAppCommand != nil && Presentation.heading(containing: context.caret, in: context.tree) != nil
        case _ where Self.linkCommands.contains(id): return onAppCommand != nil
        case "org.link.open": return OpenLinkAtPoint().applies(in: context)
        case "org.table.toggle-column-width", "org.table.shrink", "org.table.expand":
            return TableShrink.table(at: context.caret, in: context.text) != nil
        default: return false
        }
    }

    // MARK: - Hardware keyboard

    lazy var dispatcher = KeyDispatcher(keymap: keymap)

    private static let named: [UIKeyboardHIDUsage: String] = [
        .keyboardTab: "TAB", .keyboardReturnOrEnter: "RET", .keypadEnter: "RET", .keyboardSpacebar: "SPC",
        .keyboardEscape: "ESC", .keyboardDeleteOrBackspace: "DEL", .keyboardDeleteForward: "<delete>",
        .keyboardLeftArrow: "<left>", .keyboardRightArrow: "<right>", .keyboardUpArrow: "<up>", .keyboardDownArrow: "<down>",
        .keyboardHome: "<home>", .keyboardEnd: "<end>", .keyboardPageUp: "<prior>", .keyboardPageDown: "<next>",
    ]

    /// A key press as a chord; Option is Meta, as `option-as-meta` makes it on the Mac.
    static func chord(_ key: UIKey) -> KeyChord? {
        var modifiers: KeyChord.Modifiers = []
        let flags = key.modifierFlags
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.alternate) { modifiers.insert(.meta) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if let name = named[key.keyCode] {
            if flags.contains(.shift) { modifiers.insert(.shift) }
            return KeyChord(name, modifiers)
        }
        var characters = key.charactersIgnoringModifiers
        if flags.contains(.shift), characters.count == 1, characters.lowercased() == characters { characters = characters.uppercased() }
        guard characters.count == 1 else { return nil }
        return KeyChord(characters, modifiers)
    }

    /// The Emacs keymap's commands on an iPad keyboard. Keys it doesn't bind, Command shortcuts
    /// and editing keys (C-a, C-e, C-k...) are the text system's.
    func handleKey(_ key: UIKey) -> Bool {
        guard let chord = Self.chord(key), !chord.modifiers.contains(.command) else { return false }
        if modal { return handleModal(chord) }
        // Option alone types characters unless it begins a binding.
        if chord.modifiers == [.meta], dispatcher.pending.isEmpty,
           keymap.candidates(for: [chord]).isEmpty, !keymap.isPrefix([chord]) { return false }
        switch dispatcher.feed(chord) {
        case .pending(let keys):
            onMessage?(KeySequence.format(keys) + "-")
            return true
        case .cancelled:
            onMessage?("Quit")
            return true
        case .undefined(let keys):
            onMessage?("\(KeySequence.format(keys)) is undefined")
            return true
        case .unbound:
            return false
        case .complete(let keys, let candidates):
            let context = editContext()
            let runnable = candidates.first { binding in
                (binding.when.map { KeyContext.holds($0, in: context) } ?? true) && applies(binding.command, in: context)
            }
            // A sequence runs its command even where it doesn't apply, which says why, as on the Mac.
            guard let binding = runnable ?? (keys.count > 1 ? candidates.first : nil) else { return false }
            if keys.count == 1, binding.command.hasPrefix("edit."), !["edit.undo", "edit.redo"].contains(binding.command) { return false }
            run(binding.command)
            return true
        }
    }

    func editContext() -> EditContext {
        EditContext(revision: document.revision, text: document.text, tree: document.tree, selection: selection, hidden: hidden.all, options: options, knownTags: knownTags)
    }

    private func openLinkAtCaret() {
        let caret = textView.selectedRange.location
        if let link = Links.link(at: caret, text: document.text, tree: document.tree)?.link {
            onLink?(link)
        } else if let days = Links.timestampDays(at: caret, text: document.text) {
            onAgenda?(days.start, days.count)
        } else {
            onMessage?("No link here")
        }
    }

    // MARK: - Editing

    /// Applies `edits` (against the current text) through the text view as one undo step.
    func applyEdits(_ edits: [TextEdit]) {
        let interval = Perf.begin("editor.applyEdits")
        defer { interval.end() }
        guard !edits.isEmpty else { return }
        applyingEdits = true
        defer { applyingEdits = false }
        // Straight into the storage: replacing through text input would take the active
        // keyboard's substitutions (smart dashes) when another view has the keyboard.
        let storage = textView.textStorage
        let old = storage.string as NSString
        // By lines, so a fold between two changes stays.
        let ascending = edits.flatMap { splitByLines($0, in: storage.string) }.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var inverse: [TextEdit] = []
        var delta = 0
        for edit in ascending {
            let start = edit.range.lowerBound + delta
            let length = (edit.replacement as NSString).length
            inverse.append(TextEdit(range: start..<start + length, replacement: old.substring(with: NSRange(edit.range))))
            delta += length - edit.range.count
        }
        let caret = textView.selectedRange
        // One at a time, last first: each is processed alone, so folds between them stay.
        for edit in ascending.reversed() {
            storage.replaceCharacters(in: NSRange(edit.range), with: edit.replacement)
        }
        textView.undoManager?.registerUndo(withTarget: self) { editor in
            editor.applyEdits(inverse)
            editor.textView.selectedRange = caret
        }
    }

    /// The storage changed (typing, a command, undo): the document takes the same edit, and
    /// folds and styles follow.
    fileprivate func storageEdited(range: NSRange, delta: Int) {
        let interval = Perf.begin("editor.edit")
        defer { interval.end() }
        guard !loading else { return }
        let old = range.location..<(range.location + range.length - delta)
        let replacement = (textView.textStorage.string as NSString).substring(with: range)
        let edit = TextEdit(range: old, replacement: replacement)
        do {
            try document.apply([edit], baseRevision: document.revision)
        } catch {
            // Out of step: the view's text wins.
            shrunk = ShrunkColumns()
            load(textView.textStorage.string)
            return
        }
        for table in shrunk.map(through: edit, in: textView.textStorage.string, command: commandEditing) { scheduleRestyle(table) }
        fold = FoldState(
            folds: Self.map(fold.folds, old, delta), bodyFolds: Self.map(fold.bodyFolds, old, delta),
            wrapperFolds: Self.map(fold.wrapperFolds, old, delta)
        )
        scheduleRestyle(range.location..<NSMaxRange(range))
        onChange?()
    }

    /// Starts after the edit move with it; ones inside it go.
    static func map(_ starts: Set<Int>, _ old: Range<Int>, _ delta: Int) -> Set<Int> {
        Set(starts.compactMap { start in
            if start >= old.upperBound { return start + delta }
            return start <= old.lowerBound ? start : nil
        })
    }

}

extension MobileEditor: UITextViewDelegate {
    func textViewDidChangeSelection(_ textView: UITextView) {
        selectionChanged()
    }

    /// `electric-pair-mode` for typed brackets and quotes, DEL and RET, from either keyboard.
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if !applyingEdits { typedOutsideInsert() }
        guard options.electricPair, !applyingEdits, textView.markedTextRange == nil else { return true }
        let selected = textView.selectedRange
        let key: String
        if text.isEmpty, selected.length == 0, range.length == 1, NSMaxRange(range) == selected.location {
            key = "DEL"
        } else if range == selected, text == "\n" {
            key = "RET"
        } else if range == selected, ElectricPairKey.characters.contains(text) {
            key = text
        } else {
            return true
        }
        let command = ElectricPairKey(key: key)
        guard command.applies(in: editContext()) else { return true }
        _ = perform(command)
        return false
    }
}

extension MobileEditor: UIGestureRecognizerDelegate {
    /// The drawer or block a tap at `point` folds or unfolds: a folded one's `…`, the space after
    /// its first line, or anywhere on an open drawer's first line.
    private func foldToggle(at point: CGPoint) -> Int? {
        guard let manager = textView.textLayoutManager, let content = manager.textContentManager else { return nil }
        let inContainer = CGPoint(x: point.x - textView.textContainerInset.left, y: point.y - textView.textContainerInset.top)
        guard let fragment = manager.textLayoutFragment(for: inContainer), let range = fragment.textElement?.elementRange else { return nil }
        let start = content.offset(from: content.documentRange.location, to: range.location)
        guard let line = fragment.textLineFragments.first(where: { $0.characterRange.length > 0 }) ?? fragment.textLineFragments.first else { return nil }
        if hidden.isFolded(start) { return inContainer.x - fragment.layoutFragmentFrame.minX >= line.typographicBounds.maxX ? start : nil }
        guard Wrappers.starting(at: start, in: document.tree)?.kind == .drawer,
              inContainer.y - fragment.layoutFragmentFrame.minY < line.typographicBounds.maxY else { return nil }
        return start
    }

    /// A tap on a fold's `…` opens it, and one on an open drawer's first line folds it, as TAB
    /// on the line does.
    @objc fileprivate func tappedFold(_ tap: UITapGestureRecognizer) {
        guard let start = foldToggle(at: tap.location(in: textView)),
              let next = Presentation.cycle(at: start, in: document.tree, fold) else { return }
        setFolds(next)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        foldToggle(at: gestureRecognizer.location(in: textView)) != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

extension MobileEditor: NSTextStorageDelegate {
    nonisolated func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions, range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated { storageEdited(range: editedRange, delta: delta) }
    }
}

extension MobileEditor: NSTextContentStorageDelegate {
    /// Folded text isn't enumerated, so it isn't laid out or drawn.
    nonisolated func textContentManager(
        _ textContentManager: NSTextContentManager, shouldEnumerate textElement: NSTextElement, options: NSTextContentManager.EnumerationOptions = []
    ) -> Bool {
        guard let range = textElement.elementRange else { return true }
        let documentStart = textContentManager.documentRange.location
        let start = textContentManager.offset(from: documentStart, to: range.location)
        let end = textContentManager.offset(from: documentStart, to: range.endLocation)
        return !hidden.covers(start, end)
    }
}

extension MobileEditor: NSTextLayoutManagerDelegate {
    /// Folded headings, drawers and blocks end with `…`; blocks are on a band; image lines
    /// show their image; pretty entities draw their character.
    nonisolated func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let range = textElement.elementRange
        guard let range, let manager = textLayoutManager.textContentManager else { return NSTextLayoutFragment(textElement: textElement, range: range) }
        let offset = manager.offset(from: manager.documentRange.location, to: range.location)
        let folded = hidden.isFolded(offset)
        let band = shaded.containing(offset) != nil ? fragmentStyle.blockBand : nil
        let string = (textElement as? NSTextParagraph)?.attributedString
        let image = string.flatMap(OrgLineFragment.image)
        let entities = string.map(OrgLineFragment.hasEntities) ?? false
        let latex = string.map(OrgLineFragment.hasLatex) ?? false
        guard folded || band != nil || image != nil || entities || latex else { return NSTextLayoutFragment(textElement: textElement, range: range) }
        let fragment = OrgLineFragment(textElement: textElement, range: range)
        fragment.folded = folded
        fragment.band = band
        if band != nil {
            fragment.start = offset
            fragment.style = fragmentStyle
        }
        fragment.image = image
        return fragment
    }
}
#endif
