#if os(iOS)
import OrgApp
import OrgCore
import OrgDocument
import OrgHighlight
import OrgPresentation
import UIKit

/// Ranges read by TextKit's delegate callbacks.
final class LockedRanges: @unchecked Sendable {
    private let lock = NSLock()
    private var ranges: [Range<Int>] = []
    private var starts: Set<Int> = []

    func set(_ new: [Range<Int>], folded: Set<Int>) { lock.withLock { ranges = new; starts = folded } }
    var all: [Range<Int>] { lock.withLock { ranges } }
    func covers(_ start: Int, _ end: Int) -> Bool { lock.withLock { ranges.contains { $0.lowerBound <= start && end <= $0.upperBound } } }
    func isFolded(_ start: Int) -> Bool { lock.withLock { starts.contains(start) } }
    var folded: Set<Int> { lock.withLock { starts } }
    func containing(_ offset: Int) -> Range<Int>? { lock.withLock { ranges.first { $0.contains(offset) } } }
}

/// What layout fragments draw beyond the text, read by TextKit's delegate callbacks.
final class FragmentStyle: @unchecked Sendable {
    private let lock = NSLock()
    private var band: (color: UIColor, width: CGFloat) = (.clear, 0)
    private var selected: (range: Range<Int>, color: UIColor)?

    func set(blockBackground color: UIColor, width: CGFloat) { lock.withLock { band = (color, width) } }
    var blockBand: (color: UIColor, width: CGFloat) { lock.withLock { band } }
    /// The selection, which a block's fragment draws over its band, as the Mac's fragments do.
    func set(selection range: Range<Int>?, color: UIColor) { lock.withLock { selected = range.map { ($0, color) } } }
    var selection: (range: Range<Int>, color: UIColor)? { lock.withLock { selected } }
}

/// A text view that offers hardware-keyboard presses to the editor's keymap first.
final class KeyedTextView: UITextView {
    var keyHandler: ((UIKey) -> Bool)?
    /// Keys the editor took, whose release the text system doesn't see. Optional: made by
    /// UIKit's `init(usingTextLayoutManager:)`, the view skips Swift's default values.
    private var handled: Set<UIKeyboardHIDUsage>?
    /// Called after each layout pass, as the view's size settles.
    var onLayout: (() -> Void)?
    /// The text container's width while lines are truncated.
    static let truncatedWidth: CGFloat = 100_000

    /// Long lines run off the right edge and the view scrolls sideways.
    var truncates: Bool {
        get { !textContainer.widthTracksTextView }
        set {
            textContainer.widthTracksTextView = !newValue
            if newValue {
                textContainer.size = CGSize(width: Self.truncatedWidth, height: CGFloat.greatestFiniteMagnitude)
            } else {
                textContainer.size = CGSize(width: bounds.width - textContainerInset.left - textContainerInset.right, height: CGFloat.greatestFiniteMagnitude)
                contentOffset.x = 0
            }
            showsHorizontalScrollIndicator = newValue
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        // The text view sets its container's width to its own when it lays out.
        if truncates, textContainer.size.width != Self.truncatedWidth {
            textContainer.size = CGSize(width: Self.truncatedWidth, height: CGFloat.greatestFiniteMagnitude)
        }
        super.layoutSubviews()
        // The text view sizes its content to its own width; truncated lines need the widest
        // laid-out line's.
        if truncates, let manager = textLayoutManager {
            let width = ceil(manager.usageBoundsForTextContainer.maxX + textContainerInset.left + textContainerInset.right)
            if contentSize.width < width { contentSize.width = width }
        }
        onLayout?()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest: Set<UIPress> = []
        for press in presses {
            if let key = press.key, keyHandler?(key) == true {
                handled = (handled ?? []).union([key.keyCode])
            } else {
                rest.insert(press)
            }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.filter { press in
            guard let code = press.key?.keyCode, handled?.contains(code) == true else { return true }
            handled?.remove(code)
            return false
        }
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }
}

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
    var keymap = KeymapPreset.emacs.keymap
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
    /// Commands the app runs, as `app.clock.in`.
    var onAppCommand: ((String) -> Void)?
    /// Tags used across the workspace, for completion.
    var knownTags: @Sendable () -> [String] = { [] }

    private var theme: MobileTheme
    private(set) var fold = FoldState()
    private var globalVisibility: GlobalVisibility?
    let hidden = LockedRanges()
    /// Blocks drawn on a band.
    let shaded = LockedRanges()
    let fragmentStyle = FragmentStyle()
    private var selectionColor: UIColor = .clear
    /// `org-indent-mode` and `org-hide-leading-stars`, from the settings and `#+STARTUP`.
    private var indented = true
    private var hideStars = false
    /// One paragraph style per indent pair.
    private var paragraphStyles: [[Int]: NSParagraphStyle] = [:]
    /// The line last revealed while markup is hidden, to hide again when the caret leaves.
    private var revealedLine: NSRange?
    /// `org-toggle-inline-images`: lines that are only an image link show the image.
    private(set) var showsImages = false
    /// The view width images were last sized for.
    private var imageWidth: CGFloat = 0
    /// The file's folder, for relative image paths.
    let baseDirectory: URL?
    private static let imageCache = NSCache<NSString, UIImage>()
    private var loading = false
    private var restyleScheduled: Range<Int>?
    /// Narrowed table columns (`org-table-shrink`).
    private var shrunk = ShrunkColumns()
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
        case "org.cycle-global", "edit.undo", "edit.redo", "org.toggle-inline-images", "editor.toggle-truncate-lines": return true
        case "app.clock.in", "app.clock.out", "app.clock.cancel", "app.clock.goto", "app.clock.in-recent", "app.clock.in-last",
             "app.clock.goto-recent", "app.clock.default", "app.clock.resolve", "app.toggle-markup": return onAppCommand != nil
        case _ where Self.linkCommands.contains(id): return onAppCommand != nil
        case "org.link.open": return OpenLinkAtPoint().applies(in: context)
        case "org.table.toggle-column-width", "org.table.shrink", "org.table.expand":
            return TableShrink.table(at: context.caret, in: context.text) != nil
        default: return false
        }
    }

    // MARK: - Hardware keyboard

    private lazy var dispatcher = KeyDispatcher(keymap: keymap)

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
    private static func map(_ starts: Set<Int>, _ old: Range<Int>, _ delta: Int) -> Set<Int> {
        Set(starts.compactMap { start in
            if start >= old.upperBound { return start + delta }
            return start <= old.lowerBound ? start : nil
        })
    }

    // MARK: - Styling

    private func load(_ text: String) {
        loading = true
        textView.textStorage.setAttributedString(NSAttributedString(string: text, attributes: theme.base))
        loading = false
        shaded.set(Presentation.shadedBlocks(document.tree), folded: [])
        restyle(0..<(text as NSString).length)
        textView.typingAttributes = theme.base
    }

    /// The text view's own colors, and the block band's.
    private func applyThemeToView() {
        textView.backgroundColor = theme.color("background") ?? .systemBackground
        textView.tintColor = theme.color("cursor")
        textView.typingAttributes = theme.base
        fragmentStyle.set(blockBackground: theme.color("block-background") ?? .clear, width: textView.bounds.width)
        themeSelection()
    }

    /// The selection in the theme's selection color: the text view's selection display
    /// interaction draws it with our highlight view; the cursor and handles keep the tint.
    private func themeSelection() {
        guard let interaction = textView.interactions.lazy.compactMap({ $0 as? UITextSelectionDisplayInteraction }).first else { return }
        let view = interaction.highlightView as? SelectionHighlightView ?? SelectionHighlightView()
        view.color = theme.color("selection") ?? UIColor.tintColor.withAlphaComponent(0.25)
        if interaction.highlightView !== view { interaction.highlightView = view }
        selectionColor = view.color
    }

    /// The highlight view draws under the text, so a block's band would cover it: blocks the
    /// selection enters or leaves are laid out again to draw it over their band.
    private func redrawSelectedBlocks() {
        let selected = textView.selectedRange
        let range = selected.length > 0 ? selected.location..<NSMaxRange(selected) : nil
        let old = fragmentStyle.selection?.range
        fragmentStyle.set(selection: range, color: selectionColor)
        guard let manager = textView.textLayoutManager, let content = manager.textContentManager else { return }
        let touched = [old, range].compactMap { $0 }
        for block in shaded.all where touched.contains(where: { $0.overlaps(block) }) {
            guard let start = content.location(content.documentRange.location, offsetBy: block.lowerBound),
                  let end = content.location(start, offsetBy: block.count),
                  let textRange = NSTextRange(location: start, end: end) else { continue }
            // Fragments are kept across layout passes, so they are asked to draw again too.
            manager.invalidateRenderingAttributes(for: textRange)
            manager.invalidateLayout(for: textRange)
        }
        textView.setNeedsDisplay()
    }

    /// The band behind blocks spans the view's width, or the widest line's when truncated;
    /// images are as wide as the view allows.
    private func viewResized() {
        let band = fragmentStyle.blockBand
        let width = max(textView.bounds.width, truncatesLines ? textView.contentSize.width : 0)
        let resized = imageWidth != textView.bounds.width
        guard band.width != width || resized else { return }
        fragmentStyle.set(blockBackground: band.color, width: width)
        imageWidth = textView.bounds.width
        if showsImages, resized { restyle(0..<textView.textStorage.length) }
        if let manager = textView.textLayoutManager {
            manager.invalidateRenderingAttributes(for: manager.documentRange)
            manager.invalidateLayout(for: manager.documentRange)
        }
    }

    /// Styles the whole file again.
    private func restyleAll() {
        let interval = Perf.begin("editor.restyleAll")
        defer { interval.end() }
        restyle(0..<textView.textStorage.length)
        if let manager = textView.textLayoutManager { manager.invalidateLayout(for: manager.documentRange) }
    }

    /// Styles are set after the edit has been processed, as TextKit asks.
    private func scheduleRestyle(_ range: Range<Int>) {
        if let pending = restyleScheduled {
            restyleScheduled = min(pending.lowerBound, range.lowerBound)..<max(pending.upperBound, range.upperBound)
            return
        }
        restyleScheduled = range
        DispatchQueue.main.async { [weak self] in
            guard let self, let range = self.restyleScheduled else { return }
            self.restyleScheduled = nil
            self.shaded.set(Presentation.shadedBlocks(self.document.tree), folded: [])
            // Small files are restyled whole: a heading or block line changes what follows it.
            let length = self.textView.textStorage.length
            self.restyle(length < 60_000 ? 0..<length : range)
            self.updateHidden()
            self.textView.typingAttributes = self.theme.base
        }
    }

    private var caretLine: NSRange {
        let text = textView.textStorage.string as NSString
        return text.lineRange(for: NSRange(location: min(textView.selectedRange.location, text.length), length: 0))
    }

    /// Sets attributes for the whole lines in `range`, as the Mac editor does.
    private func restyle(_ range: Range<Int>) {
        let interval = Perf.begin("editor.restyle")
        defer { interval.end() }
        let storage = textView.textStorage
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }
        let lower = min(range.lowerBound, ns.length)
        let lines = ns.lineRange(for: NSRange(location: lower, length: min(range.count, ns.length - lower)))
        let whole = lines.location..<NSMaxRange(lines)
        storage.beginEditing()
        storage.setAttributes(theme.base, range: lines)
        if indented {
            for line in Presentation.lineIndents(document.tree, in: whole) {
                storage.addAttribute(.paragraphStyle, value: paragraphStyle(line.firstLine, line.wrapped), range: NSRange(line.range))
            }
        }
        let revealed = caretLine
        var scriptExclusions: [Range<Int>] = []
        for run in Presentation.styles(document.tree, in: whole, highlighter: Self.highlighter) {
            let clipped = NSIntersectionRange(NSRange(run.range), lines)
            guard clipped.length > 0 else { continue }
            if Presentation.skipsLeadingStars(run.role, indented: indented, hideStars: hideStars) { continue }
            if !showMarkup, Presentation.hidesWithMarkup(run.role, options: options), NSIntersectionRange(clipped, revealed).length == 0 {
                storage.addAttributes(theme.hidden, range: clipped)
            } else {
                theme.apply(run.role, to: storage, range: clipped)
            }
            if Presentation.excludesScripts(run.role) { scriptExclusions.append(run.range) }
        }
        if !showMarkup, options.prettyEntities { prettify(whole, in: storage, revealed: revealed, scriptExclusions: scriptExclusions) }
        applyShrunk(whole, in: storage)
        applyImages(whole, in: storage, revealed: revealed)
        storage.endEditing()
    }

    private func paragraphStyle(_ firstLine: Int, _ wrapped: Int) -> NSParagraphStyle {
        if let style = paragraphStyles[[firstLine, wrapped]] { return style }
        let style = theme.paragraphStyle(firstLine: firstLine, wrapped: wrapped)
        paragraphStyles[[firstLine, wrapped]] = style
        return style
    }

    /// `org-pretty-entities`: entities drawn as their character over the entity's last
    /// character (the rest hidden), sub/superscripts raised without their markers.
    private func prettify(_ range: Range<Int>, in storage: NSTextStorage, revealed: NSRange, scriptExclusions: [Range<Int>]) {
        let runs = Presentation.prettyRuns(
            storage.string as NSString, in: range, revealedLine: revealed.location, inBlock: { shaded.containing($0) != nil },
            scriptExclusions: scriptExclusions, subSuperscriptsNeedBraces: options.subSuperscriptsNeedBraces
        )
        for (lineStart, run) in runs {
            switch run {
            case .entity(let r, let display):
                let start = lineStart + r.lowerBound
                let last = lineStart + r.upperBound - 1
                let color = storage.attribute(.foregroundColor, at: last, effectiveRange: nil) as? UIColor ?? theme.foreground
                if last > start { storage.addAttributes(theme.hidden, range: NSRange(location: start, length: last - start)) }
                storage.addAttributes([.foregroundColor: UIColor.clear, .orgEntityDisplay: display, .orgEntityColor: color], range: NSRange(location: last, length: 1))
            case .script(let markers, let body, let superscript):
                for marker in markers {
                    storage.addAttributes(theme.hidden, range: NSRange(location: lineStart + marker.lowerBound, length: marker.count))
                }
                let size = theme.font.pointSize
                storage.addAttributes([
                    .font: theme.font.withSize(size * 0.7),
                    .baselineOffset: (superscript ? 0.3 : -0.3) * size,
                ], range: NSRange(location: lineStart + body.lowerBound, length: body.count))
            }
        }
    }

    /// Moving to another line shows its markup and hides the last one's.
    private func revealCaretLine() {
        guard !showMarkup else { return }
        let line = caretLine
        guard line != revealedLine else { return }
        let text = textView.textStorage.string as NSString
        // The old line may have moved with edits since; restyle the line now at its start.
        let old = revealedLine.flatMap { $0.location <= text.length ? text.lineRange(for: NSRange(location: $0.location, length: 0)) : nil }
        revealedLine = line
        for range in [old, line].compactMap({ $0 }) {
            restyle(range.location..<NSMaxRange(range))
        }
    }

    // MARK: - Shrunk table columns

    /// C-c TAB in a table: `org-table-toggle-column-width`; `shrink` for `org-table-shrink`,
    /// `expand` for `org-table-expand`.
    private func tableColumnWidth(_ id: String) {
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
        restyleAll()
    }

    /// Hides each shrunk segment's text and draws its display where the text was, as pretty
    /// entities draw theirs.
    private func applyShrunk(_ range: Range<Int>, in storage: NSTextStorage) {
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

    private func toggleImages() {
        showsImages.toggle()
        restyleAll()
        if showsImages {
            let ns = textView.textStorage.string as NSString
            var count = 0
            var offset = 0
            while offset < ns.length {
                let line = ns.lineRange(for: NSRange(location: offset, length: 0))
                if let image = InlineImages.image(atLine: line.location, in: ns), Self.loadImage(image.path, relativeTo: baseDirectory) != nil { count += 1 }
                offset = NSMaxRange(line)
            }
            onMessage?("\(count) images displayed inline")
        } else {
            onMessage?("Inline image display turned off")
        }
    }

    /// An image link's image, by its path or one relative to `baseDirectory`.
    static func loadImage(_ path: String, relativeTo baseDirectory: URL?) -> UIImage? {
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
    /// on the line.
    private func applyImages(_ range: Range<Int>, in storage: NSTextStorage, revealed: NSRange) {
        guard showsImages else { return }
        let text = storage.string as NSString
        let inset = textView.textContainerInset
        let maxWidth = max(80, textView.bounds.width - inset.left - inset.right - 40)
        var location = range.lowerBound
        while location < range.upperBound, location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(line)
            guard let image = InlineImages.image(atLine: line.location, in: text), let picture = Self.loadImage(image.path, relativeTo: baseDirectory) else { continue }
            let width = min(image.width.map(CGFloat.init) ?? picture.size.width, maxWidth)
            let height = picture.size.width > 0 ? width * picture.size.height / picture.size.width : 0
            let content = NSRange(location: line.location, length: line.length - (text.substring(with: line).hasSuffix("\n") ? 1 : 0))
            // Invisible, keeping the line's height.
            if line.location != revealed.location, content.length > 0 {
                storage.addAttributes([.foregroundColor: UIColor.clear, .underlineStyle: 0], range: content)
            }
            storage.addAttribute(.orgImage, value: InlineImageBox(image: picture, size: CGSize(width: width, height: height)), range: NSRange(location: line.location, length: max(1, content.length)))
            let style = (storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            // The image sits where the line is; the spacing makes room for the rest of it.
            style.paragraphSpacing = max(0, height + 4 - theme.font.lineHeight)
            storage.addAttribute(.paragraphStyle, value: style, range: line)
        }
    }

    // MARK: - Truncation

    /// `toggle-truncate-lines`: long lines run off the right edge, scrolling sideways, instead
    /// of wrapping.
    var truncatesLines: Bool {
        get { (textView as? KeyedTextView)?.truncates ?? false }
        set {
            guard newValue != truncatesLines, let view = textView as? KeyedTextView else { return }
            view.truncates = newValue
            if let manager = textView.textLayoutManager { manager.invalidateLayout(for: manager.documentRange) }
        }
    }

    // MARK: - Folding

    func setFolds(_ state: FoldState) {
        fold = state
        updateHidden()
    }

    private func updateHidden() {
        let tree = document.tree
        let wrappers = fold.wrapperFolds.compactMap { Wrappers.starting(at: $0, in: tree)?.hidden }
        let before = hidden.folded
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
        if let manager = textView.textLayoutManager { manager.invalidateLayout(for: manager.documentRange) }
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

    /// The caret left hidden text (a tap past a fold): what hides it opens.
    fileprivate func selectionChanged() {
        let interval = Perf.begin("editor.selection")
        defer { interval.end() }
        redrawSelectedBlocks()
        let caret = textView.selectedRange.location
        if hidden.containing(caret) != nil { unfold(around: caret) }
        revealCaretLine()
    }
}

extension MobileEditor: UITextViewDelegate {
    func textViewDidChangeSelection(_ textView: UITextView) {
        selectionChanged()
    }

    /// `electric-pair-mode` for typed brackets and quotes, DEL and RET, from either keyboard.
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
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
    /// The start of the folded line whose `…` is at `point`: the space after its text.
    private func foldedLine(at point: CGPoint) -> Int? {
        guard let manager = textView.textLayoutManager, let content = manager.textContentManager else { return nil }
        let inContainer = CGPoint(x: point.x - textView.textContainerInset.left, y: point.y - textView.textContainerInset.top)
        guard let fragment = manager.textLayoutFragment(for: inContainer), let range = fragment.textElement?.elementRange else { return nil }
        let start = content.offset(from: content.documentRange.location, to: range.location)
        guard hidden.isFolded(start),
              let line = fragment.textLineFragments.first(where: { $0.characterRange.length > 0 }) ?? fragment.textLineFragments.first
        else { return nil }
        return inContainer.x - fragment.layoutFragmentFrame.minX >= line.typographicBounds.maxX ? start : nil
    }

    /// A tap on a fold's `…` opens it, as TAB on its line does.
    @objc fileprivate func tappedFold(_ tap: UITapGestureRecognizer) {
        guard let start = foldedLine(at: tap.location(in: textView)),
              let next = Presentation.cycle(at: start, in: document.tree, fold) else { return }
        setFolds(next)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        foldedLine(at: gestureRecognizer.location(in: textView)) != nil
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
        guard folded || band != nil || image != nil || entities else { return NSTextLayoutFragment(textElement: textElement, range: range) }
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

extension NSAttributedString.Key {
    /// The character an entity shows as, on the entity's last character.
    static let orgEntityDisplay = NSAttributedString.Key("OrgEntityDisplay")
    /// The color the entity's character is drawn in.
    static let orgEntityColor = NSAttributedString.Key("OrgEntityColor")
    /// The image an image link's line shows under it.
    static let orgImage = NSAttributedString.Key("OrgImage")
}

final class InlineImageBox: NSObject, @unchecked Sendable {
    let image: UIImage
    let size: CGSize
    init(image: UIImage, size: CGSize) {
        self.image = image
        self.size = size
    }
}

/// Selected text's background, in one color however the rects overlap.
final class SelectionHighlightView: UIView, UITextSelectionHighlightView {
    var selectionRects: [UITextSelectionRect] = [] { didSet { setNeedsDisplay() } }
    var color: UIColor = .clear { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SelectionHighlightView, _) in view.setNeedsDisplay() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        let path = UIBezierPath()
        for selection in selectionRects where !selection.rect.isEmpty { path.append(UIBezierPath(rect: selection.rect)) }
        color.setFill()
        path.fill()
    }
}

/// A line drawn with more than its text, as the Mac editor's fragments draw them: a folded
/// line's ellipsis, a block's band across the view, an image under an image link, and pretty
/// entities' characters where the entities' last (invisible) characters sit.
final class OrgLineFragment: NSTextLayoutFragment, @unchecked Sendable {
    var folded = false
    var band: (color: UIColor, width: CGFloat)?
    var image: InlineImageBox?
    /// For a block's lines: where the fragment starts, and where the selection is read.
    var start = 0
    var style: FragmentStyle?

    static func image(_ string: NSAttributedString) -> InlineImageBox? {
        var found: InlineImageBox?
        string.enumerateAttribute(.orgImage, in: NSRange(location: 0, length: string.length)) { value, _, stop in
            if let box = value as? InlineImageBox { found = box; stop.pointee = true }
        }
        return found
    }

    static func hasEntities(_ string: NSAttributedString) -> Bool {
        var found = false
        string.enumerateAttribute(.orgEntityDisplay, in: NSRange(location: 0, length: string.length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    private var bandRect: CGRect? {
        guard let band else { return nil }
        // Not under the empty line TextKit adds after a final newline.
        let height = textLineFragments.last { $0.characterRange.length > 0 }?.typographicBounds.maxY ?? layoutFragmentFrame.height
        // The width as it is now: the view may have been laid out since this fragment was made.
        let width = style?.blockBand.width ?? band.width
        return CGRect(x: -layoutFragmentFrame.minX, y: 0, width: max(width, layoutFragmentFrame.maxX), height: height)
    }

    private var imageRect: CGRect? {
        guard let image, let line = textLineFragments.first else { return nil }
        return CGRect(x: line.typographicBounds.minX, y: line.typographicBounds.minY + 2, width: image.size.width, height: image.size.height)
    }

    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        if folded { bounds = bounds.insetBy(dx: -40, dy: 0).offsetBy(dx: 40, dy: 0) }
        for rect in [bandRect, imageRect].compactMap({ $0 }) { bounds = bounds.union(rect) }
        return bounds
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if let band, let rect = bandRect {
            context.saveGState()
            context.setFillColor(band.color.cgColor)
            context.fill(rect.offsetBy(dx: point.x, dy: point.y))
            context.restoreGState()
            drawSelection(at: point, in: context, bandRect: rect)
        }
        super.draw(at: point, in: context)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        drawEntities(at: point)
        if let image, let rect = imageRect { image.image.draw(in: rect.offsetBy(dx: point.x, dy: point.y)) }
        if folded, let line = textLineFragments.first(where: { $0.characterRange.length > 0 }) ?? textLineFragments.first {
            let bounds = line.typographicBounds
            let ellipsis = NSAttributedString(string: " …", attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: UIFont.systemFontSize, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel,
            ])
            ellipsis.draw(at: CGPoint(x: point.x + bounds.maxX, y: point.y + bounds.minY))
        }
    }

    /// The selected part of each line, over the band; a selection running past a line's end
    /// fills to the band's edge.
    private func drawSelection(at point: CGPoint, in context: CGContext, bandRect: CGRect) {
        guard let selection = style?.selection else { return }
        context.saveGState()
        context.setFillColor(selection.color.cgColor)
        for line in textLineFragments where line.characterRange.length > 0 {
            let lineStart = start + line.characterRange.location
            let lineEnd = lineStart + line.characterRange.length
            let from = max(selection.range.lowerBound, lineStart), to = min(selection.range.upperBound, lineEnd)
            guard from < to || (from == to && selection.range.upperBound > lineEnd && from == lineEnd) else { continue }
            let bounds = line.typographicBounds
            // From the margin when the selection began on an earlier line, as the system draws it.
            let margin = bandRect.minX + (textLayoutManager?.textContainer?.lineFragmentPadding ?? 0)
            let x1 = selection.range.lowerBound < lineStart ? margin : bounds.minX + line.locationForCharacter(at: from - start).x
            let x2 = selection.range.upperBound >= lineEnd ? bandRect.maxX : bounds.minX + line.locationForCharacter(at: to - start).x
            context.fill(CGRect(x: point.x + x1, y: point.y + bounds.minY, width: max(0, x2 - x1), height: bounds.height))
        }
        context.restoreGState()
    }

    private func drawEntities(at point: CGPoint) {
        guard let string = (textElement as? NSTextParagraph)?.attributedString else { return }
        string.enumerateAttribute(.orgEntityDisplay, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            guard let display = value as? String,
                  let line = textLineFragments.first(where: { NSLocationInRange(range.location, $0.characterRange) }) else { return }
            var attributes = string.attributes(at: range.location, effectiveRange: nil)
            attributes[.foregroundColor] = attributes[.orgEntityColor] ?? UIColor.label
            attributes[.orgEntityDisplay] = nil
            attributes[.orgEntityColor] = nil
            let x = line.locationForCharacter(at: range.location).x
            let bounds = line.typographicBounds
            NSAttributedString(string: display, attributes: attributes).draw(at: CGPoint(x: point.x + bounds.minX + x, y: point.y + bounds.minY))
        }
    }
}
#endif
