#if os(macOS)
import AppKit
import OrgCore
import OrgDocument

/// An editor a file mark is in, gone when its buffer closes.
struct WeakEditor {
    weak var editor: OrgEditor?
}

/// Modal editing: keys go to the keymap for the current evil state first (leader keys,
/// evil-org's org keys), then to `Vim`.
extension OrgEditor {
    func handleModal(_ chord: KeyChord) -> Bool {
        // ⌘ shortcuts stay with the menus.
        if chord.modifiers.contains(.command) { return false }
        if recordingRegister != nil, replayingMacro == 0 { recordedKeys.append(chord) }
        dispatcher.mode = vim.mode.keymapMode
        if !vim.pending.isEmpty, vim.mode != .insert {
            return feedVim([chord])
        }
        switch dispatcher.feed(chord) {
        case .pending(let keys):
            let context = editContext()
            let next = keymap.continuations(of: keys, mode: dispatcher.mode) { modalRuns($0, in: context) }.map { item in
                (key: item.key.description, title: item.command.map { EditorCommands.command($0)?.title ?? $0 } ?? "+prefix")
            }
            onKeysPending?(KeySequence.format(keys), next)
            return true
        case .cancelled:
            onKeysPending?(nil, [])
            return true
        case .complete(let keys, let candidates):
            if keys.count > 1 { onKeysPending?(nil, []) }
            let context = editContext()
            if let binding = candidates.first(where: { modalRuns($0, in: context) }) {
                if binding.command == "org.fill-paragraph", vim.mode == .visual || vim.mode == .visualLine || vim.mode == .visualBlock {
                    fillVisual()
                } else {
                    run(binding.command)
                }
                updateCursor()
                return true
            }
            return feedVim(keys)
        case .undefined(let keys):
            onKeysPending?(nil, [])
            // The leader and Emacs prefixes (C-c, C-x) mean nothing to evil: the sequence is
            // undefined, as in Doom. Other prefixes (g, z, [, ]) are evil's too.
            if let first = keys.first, first == KeyChord("SPC") || !first.modifiers.isDisjoint(with: [.control, .meta]) {
                onMessage?("\(KeySequence.format(keys)) is undefined")
                return true
            }
            return feedVim(keys)
        case .unbound:
            return feedVim([chord])
        }
    }

    /// M-q in visual states: `org-fill-paragraph` on the region, the cursor kept. Evil turns
    /// `transient-mark-mode` off in block state, so there it fills the paragraph at the cursor.
    /// A change deactivates the region, which leaves visual state.
    private func fillVisual() {
        let selected = textView.selectedRanges
        let cursor = visualCaret ?? textView.selectedRange().location
        let text = document.text
        if vim.mode == .visualBlock {
            textView.setSelectedRange(NSRange(location: cursor, length: 0))
            perform(FillParagraph())
        } else {
            perform(FillParagraph(point: cursor))
        }
        if document.text == text {
            textView.selectedRanges = selected
            visualCaret = cursor
        } else {
            vim.reset()
            visualCaret = nil
            clampCaret()
        }
    }

    /// Plays keys into the engine. False hands a single key in insert state to the text
    /// system.
    func feedVim(_ keys: [KeyChord]) -> Bool {
        for (index, key) in keys.enumerated() {
            if vim.mode == .insert, vim.passesThrough(key) {
                if keys.count == 1 { return electricPair(key) }
                if !electricPair(key) { insertTyped(key) }
                continue
            }
            let leaving = key == KeyChord("ESC") || key == KeyChord("[", .control) || key == KeyChord("g", .control)
            if vim.mode == .insert, leaving, let snapshot = insertSnapshot {
                // What was typed since insert state began, for `.`.
                if let edit = TextEdit.between(snapshot.text, document.text).first, edit.range.count == 0 {
                    vim.inserted(edit.replacement)
                }
            }
            let wasInsert = vim.mode == .insert
            let visual = vim.mode == .visual || vim.mode == .visualLine || vim.mode == .visualBlock
            let caret = visual ? (visualCaret ?? textView.selectedRange().location) : textView.selectedRange().location
            if jumpToFileMark(key) { continue }
            let clipboard = NSPasteboard.general.string(forType: .string)
            var marks = vimMarks
            for (name, mark) in Self.fileMarks where mark.owner.editor === self { marks[name] = mark.offset }
            if jumpIndex > 0, jumpIndex <= jumpList.count { marks["'"] = jumpList[jumpIndex - 1] }
            vim.registers = Self.vimRegisters
            vim.clipboardRecord = Self.vimClipboardRecord
            let actions = vim.feed(key, Vim.Context(text: document.text, caret: caret, clipboard: clipboard, halfPage: halfPage, marks: marks, visible: visibleText, org: isOrg))
            Self.vimRegisters = vim.registers
            Self.vimClipboardRecord = vim.clipboardRecord
            apply(actions)
            if !wasInsert, vim.mode == .insert {
                insertSnapshot = (document.text, textView.selectedRange().location)
            } else if vim.mode != .insert {
                insertSnapshot = nil
            }
            _ = index
        }
        updateCursor()
        return true
    }

    /// `'A` or `` `A `` for a file mark in another editor: that editor's buffer shows at the
    /// mark. True when the key went there.
    private func jumpToFileMark(_ key: KeyChord) -> Bool {
        guard vim.mode == .normal, vim.pending.count == 1, let quote = vim.pending.first, quote == KeyChord("'") || quote == KeyChord("`"),
              key.modifiers.isEmpty, key.key.count == 1, let name = key.key.first, name.isUppercase,
              let mark = Self.fileMarks[name], let owner = mark.owner.editor, owner !== self else { return false }
        vim.reset()
        let ns = owner.document.text as NSString
        var target = min(mark.offset, ns.length)
        if quote == KeyChord("'") {
            // The line's first non-blank.
            target = ns.lineRange(for: NSRange(location: target, length: 0)).location
            while target < ns.length, ns.character(at: target) == 32 || ns.character(at: target) == 9 { target += 1 }
        }
        onJumpToEditor?(owner, target)
        return true
    }

    /// Moves marks and jump positions through an edit.
    func mapVimPositions(through edit: TextEdit) {
        let owned = Self.fileMarks.filter { $0.value.owner.editor === self }
        guard !vimMarks.isEmpty || !jumpList.isEmpty || !owned.isEmpty else { return }
        let names = Array(vimMarks.keys)
        let fileNames = Array(owned.keys)
        let positions = names.map { vimMarks[$0]! } + fileNames.map { owned[$0]!.offset } + jumpList
        let mapped = ViewState(selection: positions.map { $0..<$0 }).mapped(through: [edit]).selection
        for (i, name) in names.enumerated() { vimMarks[name] = mapped[i].lowerBound }
        for (i, name) in fileNames.enumerated() { Self.fileMarks[name]?.offset = mapped[names.count + i].lowerBound }
        jumpList = mapped.dropFirst(names.count + fileNames.count).map { $0.lowerBound }
    }

    func insertTyped(_ key: KeyChord) {
        let text = key.key == "SPC" ? " " : key.key == "RET" ? "\n" : key.key == "TAB" ? "\t" : key.key
        guard key.modifiers.isEmpty, text.count == 1 else { return }
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    var halfPage: Int {
        guard let scroll = textView.enclosingScrollView, let font = textView.font else { return 15 }
        let lineHeight = max(1, font.ascender - font.descender + font.leading)
        return max(1, Int(scroll.contentView.bounds.height / lineHeight / 2))
    }

    /// The text the window shows, from the line at its top to the line at its bottom.
    var visibleText: Range<Int>? {
        guard let layout = textView.textLayoutManager, let content = layout.textContentManager, let scroll = textView.enclosingScrollView else { return nil }
        let bounds = scroll.contentView.bounds
        let origin = textView.textContainerOrigin
        let start = content.documentRange.location
        guard let top = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, bounds.minY - origin.y))) else { return nil }
        let lower = content.offset(from: start, to: top.rangeInElement.location)
        let bottom = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, bounds.maxY - origin.y - 1)))
        let upper = bottom.map { content.offset(from: start, to: $0.rangeInElement.endLocation) } ?? utf16Length
        return lower..<max(lower, upper)
    }

    private func editContext() -> EditContext {
        let selected = textView.selectedRange()
        return EditContext(revision: document.revision, text: document.text, tree: document.tree, selection: [selected.location..<NSMaxRange(selected)], options: options)
    }

    private func modalRuns(_ binding: KeyBinding, in context: EditContext) -> Bool {
        (binding.when.map { KeyContext.holds($0, in: context) } ?? true) && commandApplies(binding.command, in: context)
    }

    private func commandApplies(_ id: String, in context: EditContext) -> Bool {
        if !isOrg, id.hasPrefix("org.") { return false }
        return switch EditorCommands.command(id)?.action {
        case .text(let command): command.applies(in: context)
        default: true
        }
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
                textView.scrollRangeToVisible(NSRange(location: min(caret, document.text.utf16.count), length: 0))
            case .move(let caret):
                setCaret(caret)
                visualCaret = caret
                textView.scrollRangeToVisible(NSRange(location: caret, length: 0))
            case .select(let range):
                textView.setSelectedRange(NSRange(range))
            case .command(let id):
                run(id)
            case .visualLines(let count):
                for _ in 0..<abs(count) {
                    if count > 0 { textView.moveDown(nil) } else { textView.moveUp(nil) }
                }
                clampCaret()
            case .undo(let count):
                for _ in 0..<count { textView.undoManager?.undo() }
                clampCaret()
            case .redo(let count):
                for _ in 0..<count { textView.undoManager?.redo() }
                clampCaret()
            case .setClipboard(let text):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            case .prompt(let kind):
                prompt(kind)
            case .ex(let command):
                ex(command)
            case .fill(let range, let keep):
                visualCaret = nil
                textView.setSelectedRange(NSRange(location: textView.selectedRange().location, length: 0))
                _ = perform(FillRegion(range: range, keep: keep))
                clampCaret()
            case .message(let text):
                onMessage?(text)
            case .setMark(let name, let offset):
                if name.isUppercase { Self.fileMarks[name] = (WeakEditor(editor: self), offset) } else { vimMarks[name] = offset }
            case .jumped(let from):
                // A new jump drops the ones C-o went back past.
                jumpList = Array(jumpList.prefix(jumpIndex))
                if jumpList.last != from { jumpList.append(from) }
                if jumpList.count > 100 { jumpList.removeFirst(jumpList.count - 100) }
                jumpIndex = jumpList.count
            case .jumpBack(let count):
                // Leaving the newest place keeps it, so C-i comes back to it.
                if jumpIndex == jumpList.count {
                    jumpList.append(textView.selectedRange().location)
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
                    // Without the `q` that ended it.
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
                    for key in keys where !handleModal(key) {
                        // Printable keys in insert state type, as the text system would.
                        insertTyped(key)
                    }
                }
            case .selectBlock(let ranges):
                textView.setSelectedRanges(ranges.map { NSValue(range: NSRange($0)) }, affinity: .downstream, stillSelecting: false)
            }
        }
    }

    private func clampCaret() {
        guard vim.mode == .normal else { return }
        let ns = document.text as NSString
        let caret = min(textView.selectedRange().location, ns.length)
        let line = ns.lineRange(for: NSRange(location: caret, length: 0))
        var end = 0
        ns.getLineStart(nil, end: nil, contentsEnd: &end, for: line)
        if caret >= end, end > line.location { setCaret(end - 1) }
    }

    /// `/`, `?` and `:` read their argument in the echo area.
    private func prompt(_ kind: String) {
        onPrompt?(Prompt(key: kind, message: kind)) { [weak self] answer in
            guard let self, let answer, !answer.isEmpty else { return }
            let caret = self.textView.selectedRange().location
            let context = Vim.Context(text: self.document.text, caret: caret)
            if kind == ":" {
                self.ex(answer)
            } else {
                self.apply(self.vim.search(answer, forward: kind == "/", context))
            }
            self.updateCursor()
        }
    }

    /// The ex commands people reach for: `:w`, `:q`, `:wq`, `:x`, `:N`, `:s`, `:%s`, `:e FILE`,
    /// `:bn`, `:bp`, `:bd`, `:b` and `:ls`.
    func ex(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if let m = trimmed.firstMatch(of: #/^e(?:dit)?!?\s+(.+)$/#) {
            onOpenFile?(String(m.1).trimmingCharacters(in: .whitespaces))
            return
        }
        switch trimmed {
        case "w", "write": onAppCommand?("app.save")
        case "bn", "bnext": onAppCommand?("app.buffer.next")
        case "bp", "bprevious", "bN", "bNext": onAppCommand?("app.buffer.previous")
        case "bd", "bdelete", "bd!", "bw", "bwipeout": onAppCommand?("app.buffer.kill")
        case "b", "buffer", "ls", "buffers", "files": onAppCommand?("app.buffer.switch")
        case "e", "edit", "e!", "edit!": onAppCommand?("app.revert")
        case "q", "quit", "q!": textView.window?.performClose(nil)
        case "wq", "x", "wq!":
            onAppCommand?("app.save")
            textView.window?.performClose(nil)
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
                textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
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
        let options: NSRegularExpression.Options = flags.contains("i") ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            onMessage?("Invalid pattern: \(pattern)")
            return
        }
        let ns = document.text as NSString
        let caret = textView.selectedRange().location
        let lines = whole ? NSRange(location: 0, length: ns.length) : ns.lineRange(for: NSRange(location: caret, length: 0))
        var edits: [TextEdit] = []
        var location = lines.location
        while location < NSMaxRange(lines) {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let matches = regex.matches(in: ns as String, range: line)
            for m in flags.contains("g") ? matches : Array(matches.prefix(1)) {
                let template = regex.replacementString(for: m, in: ns as String, offset: 0, template: replacement.replacingOccurrences(of: "\\\\([0-9])", with: "\\$$1", options: .regularExpression))
                edits.append(TextEdit(range: m.range.location..<NSMaxRange(m.range), replacement: template))
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

    /// A block cursor in normal and visual states, a bar in insert state.
    func updateCursor() {
        let block = modal && vim.mode != .insert
        for view in orgTextViews { view.blockCursor = block }
        dispatcher.mode = modal ? vim.mode.keymapMode : nil
        let state = modal ? vim.mode.rawValue : nil
        if state != reportedMode {
            reportedMode = state
            onModeChange?(state)
        }
    }

    /// A mouse click leaves visual state, as in evil.
    func modalMouseDown() {
        guard modal else { return }
        vim.reset()
        visualCaret = nil
        updateCursor()
    }
}
#endif
