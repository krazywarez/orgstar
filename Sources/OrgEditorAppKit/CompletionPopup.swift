#if os(macOS)
import AppKit
import OrgCore

/// The candidate list under the caret, as corfu shows it: at most 16 rows, nothing selected
/// until C-n or an arrow picks one.
@MainActor
final class CompletionPopup {
    static let rows = 16
    let window: NSPanel
    private let stack = NSStackView()
    private(set) var completion: Completion
    /// The chosen row; nil while the typed text stands (`corfu-preselect` prompt).
    private(set) var selection: Int?

    init(_ completion: Completion) {
        self.completion = completion
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 20), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.identifier = NSUserInterfaceItemIdentifier("completion")
        window.hasShadow = true
        window.backgroundColor = .controlBackgroundColor
        window.isReleasedWhenClosed = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        window.contentView = stack
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.borderColor = NSColor.separatorColor.cgColor
        window.contentView?.layer?.borderWidth = 1
    }

    func update(_ completion: Completion) {
        if completion.candidates != self.completion.candidates { selection = nil }
        self.completion = completion
    }

    func move(_ delta: Int) {
        let count = completion.candidates.count
        guard count > 0 else { return }
        // corfu-cycle: past either end wraps through the typed text.
        if let s = selection {
            let next = s + delta
            selection = next < 0 || next >= count ? nil : next
        } else {
            selection = delta > 0 ? 0 : count - 1
        }
    }

    var selected: String? { selection.map { completion.candidates[$0] } }

    /// Lays the rows out and puts the list under `caret`, a rectangle in screen coordinates.
    func show(under caret: NSRect, in parent: NSWindow?, font: NSFont) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let candidates = completion.candidates
        let first = max(0, min((selection ?? 0) - Self.rows + 1, candidates.count - Self.rows))
        var width: CGFloat = 80
        for (index, candidate) in candidates.enumerated().dropFirst(first).prefix(Self.rows) {
            let label = NSTextField(labelWithString: " " + completion.label(candidate) + " ")
            label.font = font
            label.drawsBackground = index == selection
            label.backgroundColor = .selectedContentBackgroundColor
            label.textColor = index == selection ? .alternateSelectedControlTextColor : .labelColor
            label.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(label)
            width = max(width, label.intrinsicContentSize.width)
        }
        width = min(width, 120 * font.maximumAdvancement.width)
        for label in stack.arrangedSubviews { label.widthAnchor.constraint(equalToConstant: width).isActive = true }
        let height = stack.fittingSize.height
        window.setContentSize(NSSize(width: width, height: height))
        window.setFrameTopLeftPoint(NSPoint(x: caret.minX, y: caret.minY - 2))
        if window.parent == nil { parent?.addChildWindow(window, ordered: .above) }
        window.orderFront(nil)
    }

    func close() {
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
    }
}

extension OrgEditor {
    /// `completion-at-point`: one candidate is inserted, several are listed.
    func completeAtPoint() {
        guard let completion = OrgCompletion.at(context()), !completion.candidates.isEmpty else {
            closeCompletion()
            onMessage?("No match")
            return
        }
        if completion.candidates.count == 1 {
            closeCompletion()
            insertCompletion(completion, completion.candidates[0])
            return
        }
        showCompletion(completion)
    }

    func showCompletion(_ completion: Completion) {
        if let popup = completionPopup { popup.update(completion) } else { completionPopup = CompletionPopup(completion) }
        let screen = textView.firstRect(forCharacterRange: NSRange(location: completion.range.lowerBound, length: 0), actualRange: nil)
        completionPopup?.show(under: screen, in: textView.window, font: theme.font)
    }

    func closeCompletion() {
        completionTimer?.cancel()
        completionPopup?.close()
        completionPopup = nil
    }

    /// After typing: the open list follows the text; otherwise, with `modal` (corfu-auto), a
    /// list opens after a pause once two characters are typed.
    func textTyped() {
        completionTimer?.cancel()
        if completionPopup != nil {
            refreshCompletion()
            return
        }
        guard modal, vim.mode == .insert, isOrg else { return }
        let work = DispatchWorkItem { [weak self] in self?.autoComplete() }
        completionTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func autoComplete() {
        guard completionPopup == nil, textView.selectedRange().length == 0,
              let completion = OrgCompletion.at(context()), completion.range.count >= 2, !completion.candidates.isEmpty else { return }
        showCompletion(completion)
    }

    func refreshCompletion() {
        guard let popup = completionPopup else { return }
        guard textView.selectedRange().length == 0, let completion = OrgCompletion.at(context()),
              completion.range.lowerBound == popup.completion.range.lowerBound, !completion.candidates.isEmpty else {
            closeCompletion()
            return
        }
        showCompletion(completion)
    }

    func insertCompletion(_ completion: Completion, _ candidate: String) {
        let (text, caret) = completion.insertion(candidate)
        let range = NSRange(location: completion.range.lowerBound, length: completion.range.count)
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        setCaret(completion.range.lowerBound + caret)
    }

    /// Keys while the list is open. Nil lets the key through.
    func completionKey(_ chord: KeyChord) -> Bool? {
        guard let popup = completionPopup else { return nil }
        let completion = popup.completion
        switch chord {
        case KeyChord("n", .control), KeyChord("<down>"), KeyChord("j", .control):
            popup.move(1)
        case KeyChord("p", .control), KeyChord("<up>"), KeyChord("k", .control):
            popup.move(-1)
        case KeyChord("TAB"):
            // corfu-complete: the selection, else the candidates' common start.
            if let selected = popup.selected {
                closeCompletion()
                insertCompletion(completion, selected)
            } else if completion.candidates.count == 1 {
                closeCompletion()
                insertCompletion(completion, completion.candidates[0])
            } else {
                let common = completion.candidates.dropFirst().reduce(completion.candidates[0]) { $0.commonPrefix(with: $1) }
                if common.utf16.count > completion.range.count, completion.kind != .template {
                    insertCompletion(completion, common)
                    refreshCompletion()
                }
            }
            return true
        case KeyChord("RET"):
            guard let selected = popup.selected else {
                closeCompletion()
                return nil
            }
            closeCompletion()
            insertCompletion(completion, selected)
            return true
        case KeyChord("ESC"), KeyChord("g", .control):
            closeCompletion()
            return chord == KeyChord("ESC") ? nil : true
        default:
            return nil
        }
        showCompletion(popup.completion)
        return true
    }
}
#endif
