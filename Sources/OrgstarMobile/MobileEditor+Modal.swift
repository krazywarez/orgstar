#if os(iOS)
import OrgCore
import UIKit

/// Modal editing with the Doom preset on a hardware keyboard, as the Mac's editor does it:
/// keys go to the keymap for the current evil state first, then to `Vim`. Text typed on the
/// on-screen keyboard in normal state goes in as insert state does.
extension MobileEditor {
    func handleModal(_ chord: KeyChord) -> Bool {
        if recordingRegister != nil, replayingMacro == 0 { recordedKeys.append(chord) }
        dispatcher.mode = vim.mode.keymapMode
        if !vim.pending.isEmpty, vim.mode != .insert { return feedVim([chord]) }
        switch dispatcher.feed(chord) {
        case .pending(let keys):
            onMessage?(KeySequence.format(keys) + "-")
            return true
        case .cancelled:
            return true
        case .complete(let keys, let candidates):
            let context = editContext()
            if let binding = candidates.first(where: { binding in
                (binding.when.map { KeyContext.holds($0, in: context) } ?? true) && applies(binding.command, in: context)
            }) {
                run(binding.command)
                updateCursor()
                return true
            }
            return feedVim(keys)
        case .undefined(let keys):
            // The leader and Emacs prefixes mean nothing to evil, as on the Mac.
            if let first = keys.first, first == KeyChord("SPC") || !first.modifiers.isDisjoint(with: [.control, .meta]) {
                onMessage?("\(KeySequence.format(keys)) is undefined")
                return true
            }
            return feedVim(keys)
        case .unbound:
            return feedVim([chord])
        }
    }

    /// Plays keys into the engine. False hands a single key in insert state to the text system.
    func feedVim(_ keys: [KeyChord]) -> Bool {
        for key in keys {
            if vim.mode == .insert, vim.passesThrough(key) {
                if keys.count == 1 { return false }
                insertTyped(key)
                continue
            }
            let leaving = key == KeyChord("ESC") || key == KeyChord("[", .control) || key == KeyChord("g", .control)
            if vim.mode == .insert, leaving, let snapshot = insertSnapshot,
               let edit = TextEdit.between(snapshot, document.text).first, edit.range.count == 0 {
                vim.inserted(edit.replacement)
            }
            let wasInsert = vim.mode == .insert
            let visual = [.visual, .visualLine, .visualBlock].contains(vim.mode)
            let caret = visual ? (visualCaret ?? textView.selectedRange.location) : textView.selectedRange.location
            var marks = vimMarks
            if jumpIndex > 0, jumpIndex <= jumpList.count { marks["'"] = jumpList[jumpIndex - 1] }
            vim.registers = Self.vimRegisters
            vim.clipboardRecord = Self.vimClipboardRecord
            // Reading the clipboard asks for permission, so only the keys that paste read it.
            let pastes = key.modifiers.isEmpty && (key.key == "p" || key.key == "P")
            let clipboard = pastes ? UIPasteboard.general.string : Self.vimClipboardRecord?.text
            let actions = vim.feed(key, Vim.Context(text: document.text, caret: caret, clipboard: clipboard, halfPage: halfPage, marks: marks, visible: visibleText, org: true))
            Self.vimRegisters = vim.registers
            Self.vimClipboardRecord = vim.clipboardRecord
            apply(actions)
            if !wasInsert, vim.mode == .insert {
                insertSnapshot = document.text
            } else if vim.mode != .insert {
                insertSnapshot = nil
            }
        }
        updateCursor()
        return true
    }

    func insertTyped(_ key: KeyChord) {
        let text = key.key == "SPC" ? " " : key.key == "RET" ? "\n" : key.key == "TAB" ? "\t" : key.key
        guard key.modifiers.isEmpty || key.modifiers == [.shift], text.count == 1 else { return }
        textView.insertText(text)
    }

    /// Typing on the on-screen keyboard outside insert state: the keys can't reach the engine,
    /// so the text goes in as from insert state.
    func typedOutsideInsert() {
        guard modal, vim.mode != .insert else { return }
        vim.reset()
        vim.enterInsert(at: textView.selectedRange.location, keys: [KeyChord("i")])
        insertSnapshot = document.text
        updateCursor()
    }

    var halfPage: Int {
        let lineHeight = max(1, theme.font.lineHeight)
        return max(1, Int(textView.bounds.height / lineHeight / 2))
    }

    /// The text the window shows.
    var visibleText: Range<Int>? {
        let top = CGPoint(x: textView.textContainerInset.left, y: textView.contentOffset.y + textView.textContainerInset.top)
        let bottom = CGPoint(x: textView.bounds.width - 1, y: textView.contentOffset.y + textView.bounds.height - 1)
        guard let first = textView.characterRange(at: top), let last = textView.characterRange(at: bottom) else { return nil }
        let lower = textView.offset(from: textView.beginningOfDocument, to: first.start)
        let upper = textView.offset(from: textView.beginningOfDocument, to: last.end)
        return lower..<max(lower, upper)
    }

    private func setCaret(_ offset: Int) {
        let length = (document.text as NSString).length
        textView.selectedRange = NSRange(location: min(max(0, offset), length), length: 0)
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    func apply(_ actions: [Vim.Action]) {
        for action in actions {
            switch action {
            case .edit(let edits, let caret):
                visualCaret = nil
                guard textView.isEditable else {
                    onMessage?("This file is read-only.")
                    continue
                }
                applyEdits(edits)
                setCaret(caret)
            case .move(let caret):
                setCaret(caret)
                visualCaret = caret
            case .select(let range):
                textView.selectedRange = NSRange(range)
            case .selectBlock(let ranges):
                // One selection: from the first line's start to the last line's end.
                if let first = ranges.first, let last = ranges.last {
                    textView.selectedRange = NSRange(location: first.lowerBound, length: max(0, last.upperBound - first.lowerBound))
                }
            case .command(let id):
                run(id)
            case .visualLines(let count):
                moveLines(count)
            case .undo(let count):
                for _ in 0..<count { textView.undoManager?.undo() }
            case .redo(let count):
                for _ in 0..<count { textView.undoManager?.redo() }
            case .setClipboard(let text):
                UIPasteboard.general.string = text
            case .prompt(let kind):
                prompt(kind)
            case .commandWindow(let kind):
                prompt(kind, history: true)
            case .ex(let command):
                ex(command)
            case .fill(let range, let keep):
                visualCaret = nil
                textView.selectedRange = NSRange(location: textView.selectedRange.location, length: 0)
                _ = perform(FillRegion(range: range, keep: keep))
            case .message(let text):
                onMessage?(text)
            case .setMark(let name, let offset):
                vimMarks[name] = offset
            case .jumped(let from):
                jumpList = Array(jumpList.prefix(jumpIndex))
                if jumpList.last != from { jumpList.append(from) }
                if jumpList.count > 100 { jumpList.removeFirst(jumpList.count - 100) }
                jumpIndex = jumpList.count
            case .jumpBack(let count):
                if jumpIndex == jumpList.count {
                    jumpList.append(textView.selectedRange.location)
                    jumpIndex = jumpList.count - 1
                }
                guard jumpIndex - count >= 0 else { continue }
                jumpIndex -= count
                reveal(jumpList[jumpIndex])
            case .jumpForward(let count):
                guard jumpIndex + count < jumpList.count else { continue }
                jumpIndex += count
                reveal(jumpList[jumpIndex])
            case .recordMacro(let name):
                if let name {
                    recordingRegister = name
                    recordedKeys = []
                    onMessage?("Defining keyboard macro…")
                } else if let register = recordingRegister {
                    Self.macros[register] = Array(recordedKeys.dropLast())
                    recordingRegister = nil
                    onMessage?("Keyboard macro defined")
                }
            case .playMacro(let name, let count):
                guard let keys = Self.macros[name], !keys.isEmpty else {
                    onMessage?("No macro in register \(name)")
                    continue
                }
                guard replayingMacro < 20 else { continue }
                replayingMacro += 1
                defer { replayingMacro -= 1 }
                for _ in 0..<count {
                    for key in keys where !handleModal(key) { insertTyped(key) }
                }
            case .scroll(let place):
                scrollCaretLine(place)
            }
        }
    }

    /// `gj` and `gk` by text lines, keeping the column.
    private func moveLines(_ count: Int) {
        let ns = document.text as NSString
        var caret = textView.selectedRange.location
        let column = caret - ns.lineRange(for: NSRange(location: caret, length: 0)).location
        for _ in 0..<abs(count) {
            let line = ns.lineRange(for: NSRange(location: caret, length: 0))
            if count > 0 {
                guard NSMaxRange(line) < ns.length else { break }
                caret = NSMaxRange(line)
            } else {
                guard line.location > 0 else { break }
                caret = ns.lineRange(for: NSRange(location: line.location - 1, length: 0)).location
            }
        }
        let line = ns.lineRange(for: NSRange(location: caret, length: 0))
        var end = 0
        ns.getLineStart(nil, end: nil, contentsEnd: &end, for: line)
        setCaret(min(line.location + column, max(line.location, end - 1)))
    }

    /// `zz`, `zt` and `zb`.
    private func scrollCaretLine(_ place: Vim.ScrollLine) {
        guard let position = textView.selectedTextRange?.start else { return }
        let rect = textView.caretRect(for: position)
        let height = textView.bounds.height - textView.adjustedContentInset.top - textView.adjustedContentInset.bottom
        var y: CGFloat = switch place {
        case .top: rect.minY
        case .center: rect.midY - height / 2
        case .bottom: rect.maxY - height
        }
        y -= textView.adjustedContentInset.top
        let maxY = max(-textView.adjustedContentInset.top, textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)
        textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: min(max(-textView.adjustedContentInset.top, y), maxY)), animated: false)
    }

    /// `/`, `?` and `:`; with `history` (`q:`), the earlier ones to pick and edit.
    private func prompt(_ kind: String, history: Bool = false) {
        let earlier = Array((Self.promptHistory[kind] ?? []).reversed())
        let request = history ? Prompt(key: kind, message: kind, choices: earlier, requireMatch: false) : Prompt(key: kind, message: kind)
        onPrompt?(request) { [weak self] answer in
            guard let self, let answer, !answer.isEmpty else { return }
            var list = Self.promptHistory[kind] ?? []
            list.removeAll { $0 == answer }
            list.append(answer)
            Self.promptHistory[kind] = Array(list.suffix(100))
            if kind == ":" {
                self.ex(answer)
            } else {
                self.apply(self.vim.search(answer, forward: kind == "/", Vim.Context(text: self.document.text, caret: self.textView.selectedRange.location)))
            }
            self.updateCursor()
        }
    }

    /// `:w`, `:N` and `:s` / `:%s`; files save on their own on iOS.
    func ex(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "w", "write", "wq", "x": onAppCommand?("app.save")
        case "noh", "nohlsearch": break
        default:
            if let line = Int(trimmed) {
                let ns = document.text as NSString
                var offset = 0
                for _ in 1..<max(1, line) {
                    let range = ns.lineRange(for: NSRange(location: offset, length: 0))
                    guard NSMaxRange(range) < ns.length else { break }
                    offset = NSMaxRange(range)
                }
                setCaret(offset)
                return
            }
            if let m = trimmed.firstMatch(of: /^(%?)s\/((?:[^\/\\]|\\.)*)\/((?:[^\/\\]|\\.)*)\/?([gi]*)$/) {
                substitute(whole: !m.1.isEmpty, pattern: String(m.2), replacement: String(m.3), flags: String(m.4))
                return
            }
            onMessage?("Not an editor command: \(trimmed)")
        }
    }

    private func substitute(whole: Bool, pattern: String, replacement: String, flags: String) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: flags.contains("i") ? [.caseInsensitive] : []) else {
            onMessage?("Invalid pattern: \(pattern)")
            return
        }
        let ns = document.text as NSString
        let lines = whole ? NSRange(location: 0, length: ns.length) : ns.lineRange(for: NSRange(location: textView.selectedRange.location, length: 0))
        let template = replacement.replacingOccurrences(of: "\\\\([0-9])", with: "\\$$1", options: .regularExpression)
        var edits: [TextEdit] = []
        var location = lines.location
        while location < NSMaxRange(lines) {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let matches = regex.matches(in: ns as String, range: line)
            for m in flags.contains("g") ? matches : Array(matches.prefix(1)) {
                edits.append(TextEdit(range: m.range.location..<NSMaxRange(m.range), replacement: regex.replacementString(for: m, in: ns as String, offset: 0, template: template)))
            }
            location = NSMaxRange(line)
        }
        guard !edits.isEmpty else {
            onMessage?("Pattern not found: \(pattern)")
            return
        }
        applyEdits(edits)
        onMessage?("\(edits.count) substitution\(edits.count == 1 ? "" : "s")")
    }

    /// A block caret outside insert and replace states, drawn by a cursor view of ours in
    /// place of the selection display's while keys are modal.
    func updateCursor() {
        let block = modal && vim.mode != .insert && vim.mode != .replace
        for case let interaction as UITextSelectionDisplayInteraction in textViews.flatMap(\.interactions) {
            if let cursor = interaction.cursorView as? ModalCursorView {
                if cursor.block != block {
                    cursor.block = block
                    interaction.setNeedsSelectionUpdate()
                }
            } else if modal {
                let cursor = ModalCursorView()
                cursor.width = theme.font.pointSize * 0.6
                cursor.tintColor = textView.tintColor
                cursor.block = block
                interaction.cursorView = cursor
                interaction.setNeedsSelectionUpdate()
            }
        }
    }
}

/// The caret with modal keys: a bar in insert and replace states, evil's character-wide box
/// in the others.
final class ModalCursorView: UIView, UITextCursorView {
    var isBlinking = false
    var block = false {
        didSet { setNeedsLayout() }
    }
    var width: CGFloat = 10 {
        didSet { setNeedsLayout() }
    }
    private let box = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        isUserInteractionEnabled = false
        layer.addSublayer(box)
    }

    required init?(coder: NSCoder) { nil }

    func resetBlinkAnimation() {}

    override func layoutSubviews() {
        super.layoutSubviews()
        box.frame = CGRect(x: 0, y: 0, width: block ? width : 2, height: bounds.height)
        box.backgroundColor = (block ? tintColor.withAlphaComponent(0.45) : tintColor).cgColor
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        setNeedsLayout()
    }
}
#endif
