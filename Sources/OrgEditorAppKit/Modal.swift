#if os(macOS)
import AppKit
import OrgCore

/// Modal editing: keys go to the keymap for the current evil state first (leader keys,
/// evil-org's org keys), then to `Vim`.
extension OrgEditor {
    func handleModal(_ chord: KeyChord) -> Bool {
        // ⌘ shortcuts stay with the menus.
        if chord.modifiers.contains(.command) { return false }
        dispatcher.mode = vim.mode.keymapMode
        if !vim.pending.isEmpty, vim.mode != .insert {
            return feedVim([chord])
        }
        switch dispatcher.feed(chord) {
        case .pending(let keys):
            let next = keymap.continuations(of: keys, mode: dispatcher.mode).map { item in
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
            if let binding = candidates.first(where: { binding in
                (binding.when.map { KeyContext.holds($0, in: context) } ?? true) && commandApplies(binding.command, in: context)
            }) {
                run(binding.command)
                updateCursor()
                return true
            }
            return feedVim(keys)
        case .undefined(let keys):
            onKeysPending?(nil, [])
            return feedVim(keys)
        case .unbound:
            return feedVim([chord])
        }
    }

    /// Plays keys into the engine. False hands a single key in insert state to the text
    /// system.
    func feedVim(_ keys: [KeyChord]) -> Bool {
        for (index, key) in keys.enumerated() {
            if vim.mode == .insert, vim.passesThrough(key) {
                if keys.count == 1 { return false }
                insertTyped(key)
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
            let visual = vim.mode == .visual || vim.mode == .visualLine
            let caret = visual ? (visualCaret ?? textView.selectedRange().location) : textView.selectedRange().location
            let clipboard = NSPasteboard.general.string(forType: .string)
            let actions = vim.feed(key, Vim.Context(text: document.text, caret: caret, clipboard: clipboard, halfPage: halfPage))
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

    private func insertTyped(_ key: KeyChord) {
        let text = key.key == "SPC" ? " " : key.key == "RET" ? "\n" : key.key == "TAB" ? "\t" : key.key
        guard key.modifiers.isEmpty, text.count == 1 else { return }
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    var halfPage: Int {
        guard let scroll = textView.enclosingScrollView, let font = textView.font else { return 15 }
        let lineHeight = max(1, font.ascender - font.descender + font.leading)
        return max(1, Int(scroll.contentView.bounds.height / lineHeight / 2))
    }

    private func editContext() -> EditContext {
        let selected = textView.selectedRange()
        return EditContext(revision: document.revision, text: document.text, tree: document.tree, selection: [selected.location..<NSMaxRange(selected)], options: options)
    }

    private func commandApplies(_ id: String, in context: EditContext) -> Bool {
        switch EditorCommands.command(id)?.action {
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
            case .message(let text):
                onMessage?(text)
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

    /// The ex commands people reach for: `:w`, `:q`, `:wq`, `:x`, `:N`, `:s` and `:%s`.
    func ex(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "w", "write": onAppCommand?("app.save")
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
        (textView as? OrgTextView)?.blockCursor = block
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
