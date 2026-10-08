#if os(iOS)
import OrgCore
import OrgDocument
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
    func containing(_ offset: Int) -> Range<Int>? { lock.withLock { ranges.first { $0.contains(offset) } } }
}

/// A text view that offers hardware-keyboard presses to the editor's keymap first.
final class KeyedTextView: UITextView {
    var keyHandler: ((UIKey) -> Bool)?
    /// Keys the editor took, whose release the text system doesn't see. Optional: made by
    /// UIKit's `init(usingTextLayoutManager:)`, the view skips Swift's default values.
    private var handled: Set<UIKeyboardHIDUsage>?

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
    private(set) var document: DocumentState
    let textView: UITextView
    var options: EditingOptions = .org {
        didSet { textView.spellCheckingType = options.spellCheck ? .yes : .no }
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

    private let theme = MobileTheme()
    private(set) var fold = FoldState()
    private var globalVisibility: GlobalVisibility?
    let hidden = LockedRanges()
    private var loading = false
    private var restyleScheduled: Range<Int>?

    init(document: DocumentState, editable: Bool) {
        self.document = document
        let keyed = KeyedTextView(usingTextLayoutManager: true)
        textView = keyed
        super.init()
        keyed.keyHandler = { [weak self] key in self?.handleKey(key) ?? false }
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
        load(document.text)
        let tree = document.tree
        var state = Presentation.applyVisibilityProperties(Presentation.startupFoldState(tree) ?? FoldState(), in: tree)
        state.wrapperFolds = Presentation.startupWrapperFolds(tree)
        setFolds(state)
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
            applyEdits(result.edits)
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
        case "edit.undo": textView.undoManager?.undo()
        case "edit.redo": textView.undoManager?.redo()
        case _ where id.hasPrefix("app."):
            if let onAppCommand { onAppCommand(id) } else { onMessage?("Not available on iOS yet") }
        default:
            if let command = Commands.command(id) {
                _ = perform(command)
            } else {
                onMessage?("Not available on iOS yet")
            }
        }
    }

    func applies(_ id: String, in context: EditContext) -> Bool {
        if let command = Commands.command(id) { return command.applies(in: context) }
        switch id {
        case "org.cycle":
            return Presentation.heading(containing: context.caret, in: context.tree) != nil || Wrappers.toggleable(at: context.caret, in: context.tree) != nil
        case "org.cycle-global", "edit.undo", "edit.redo": return true
        case "app.clock.in", "app.clock.out", "app.clock.cancel", "app.clock.goto": return onAppCommand != nil
        case "org.link.open": return OpenLinkAtPoint().applies(in: context)
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
        guard !loading else { return }
        let old = range.location..<(range.location + range.length - delta)
        let replacement = (textView.textStorage.string as NSString).substring(with: range)
        do {
            try document.apply([TextEdit(range: old, replacement: replacement)], baseRevision: document.revision)
        } catch {
            // Out of step: the view's text wins.
            load(textView.textStorage.string)
            return
        }
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
        restyle(0..<(text as NSString).length)
        textView.typingAttributes = theme.base
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
            // Small files are restyled whole: a heading or block line changes what follows it.
            let length = self.textView.textStorage.length
            self.restyle(length < 60_000 ? 0..<length : range)
            self.updateHidden()
            self.textView.typingAttributes = self.theme.base
        }
    }

    private func restyle(_ range: Range<Int>) {
        let storage = textView.textStorage
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }
        let lower = min(range.lowerBound, ns.length)
        let lines = ns.lineRange(for: NSRange(location: lower, length: min(range.count, ns.length - lower)))
        storage.beginEditing()
        storage.setAttributes(theme.base, range: lines)
        for run in Presentation.styles(document.tree, in: lines.location..<NSMaxRange(lines)) {
            let clipped = NSIntersectionRange(NSRange(location: run.range.lowerBound, length: run.range.count), lines)
            if clipped.length > 0 { theme.apply(run.role, to: storage, range: clipped) }
        }
        storage.endEditing()
    }

    // MARK: - Folding

    func setFolds(_ state: FoldState) {
        fold = state
        updateHidden()
    }

    private func updateHidden() {
        let tree = document.tree
        let wrappers = fold.wrapperFolds.compactMap { Wrappers.starting(at: $0, in: tree)?.hidden }
        hidden.set(
            Presentation.hiddenRanges(tree, folds: fold.folds, bodyFolds: fold.bodyFolds, wrapperRanges: wrappers),
            folded: fold.folds.union(fold.bodyFolds).union(fold.wrapperFolds)
        )
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
        let caret = textView.selectedRange.location
        if hidden.containing(caret) != nil { unfold(around: caret) }
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
    /// Folded headings, drawers and blocks end with `…`.
    nonisolated func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let range = textElement.elementRange
        if let range, let manager = textLayoutManager.textContentManager {
            let offset = manager.offset(from: manager.documentRange.location, to: range.location)
            if hidden.isFolded(offset) { return FoldedLineFragment(textElement: textElement, range: range) }
        }
        return NSTextLayoutFragment(textElement: textElement, range: range)
    }
}

/// A folded line drawn with an ellipsis after it, like org's folded headings.
final class FoldedLineFragment: NSTextLayoutFragment, @unchecked Sendable {
    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let line = textLineFragments.first(where: { $0.characterRange.length > 0 }) ?? textLineFragments.first else { return }
        let bounds = line.typographicBounds
        let ellipsis = NSAttributedString(string: " …", attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: UIFont.systemFontSize, weight: .regular),
            .foregroundColor: UIColor.secondaryLabel,
        ])
        UIGraphicsPushContext(context)
        ellipsis.draw(at: CGPoint(x: point.x + bounds.maxX, y: point.y + bounds.minY))
        UIGraphicsPopContext()
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.insetBy(dx: -40, dy: 0).offsetBy(dx: 40, dy: 0)
    }
}
#endif
