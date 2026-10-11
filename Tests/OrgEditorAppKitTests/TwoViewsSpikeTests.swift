import AppKit
import Testing

/// Spike for windows and panes (docs/plans/2026-10-10-windows-and-panes.md, Task 0): two
/// `NSTextView`s, each with its own `NSTextLayoutManager`, on one `NSTextContentStorage`.
/// Findings are the test names. Two more: the layout manager's delegate must be in place before
/// its first layout (`invalidateLayout(for:)` afterwards kept the old fragments here), and IME
/// composition is not covered headlessly.
@MainActor
struct TwoViewsSpikeTests {
    @MainActor final class Shared: NSObject, NSTextViewDelegate {
        let undo = UndoManager()
        override init() { super.init() }
        func undoManager(for view: NSTextView) -> UndoManager? { undo }
    }

    final class MarkedFragment: NSTextLayoutFragment, @unchecked Sendable {}

    final class FirstMarked: NSObject, NSTextLayoutManagerDelegate, @unchecked Sendable {
        nonisolated func textLayoutManager(_ manager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in element: NSTextElement) -> NSTextLayoutFragment {
            let content = manager.textContentManager!
            if content.offset(from: content.documentRange.location, to: location) == 0 {
                return MarkedFragment(textElement: element, range: element.elementRange)
            }
            return NSTextLayoutFragment(textElement: element, range: element.elementRange)
        }
    }

    @MainActor struct Pair {
        let storage: NSTextContentStorage
        let shared: Shared
        let a: NSTextView
        let b: NSTextView
        let windows: [NSWindow]

        init(_ text: String, delegateForB: NSTextLayoutManagerDelegate? = nil) {
            _ = NSApplication.shared
            storage = NSTextContentStorage()
            shared = Shared()
            let storage = self.storage
            storage.textStorage?.setAttributedString(NSAttributedString(string: text))
            func view(_ delegate: NSTextLayoutManagerDelegate? = nil) -> NSTextView {
                let layout = NSTextLayoutManager()
                layout.delegate = delegate
                storage.addTextLayoutManager(layout)
                let container = NSTextContainer(size: CGSize(width: 600, height: 100_000))
                layout.textContainer = container
                let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800), textContainer: container)
                view.allowsUndo = true
                return view
            }
            a = view(); b = view(delegateForB)
            a.delegate = shared; b.delegate = shared
            windows = [a, b].map { view in
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = view
                window.makeFirstResponder(view)
                return window
            }
            for view in [a, b] { view.textLayoutManager!.ensureLayout(for: view.textLayoutManager!.documentRange) }
        }
    }

    @Test func typingInOneViewShowsInTheOther() {
        let pair = Pair("* a\nbody\n")
        pair.a.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        #expect(pair.b.string == "X* a\nbody\n")
        #expect(pair.b.textLayoutManager!.textContentManager === pair.a.textLayoutManager!.textContentManager)
    }

    @Test func undoFromTheOtherViewRevertsTyping() {
        let pair = Pair("* a\nbody\n")
        pair.a.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        #expect(pair.shared.undo.canUndo)
        pair.b.undoManager?.undo()
        #expect(pair.a.string == "* a\nbody\n")
        #expect(pair.b.string == "* a\nbody\n")
    }

    @Test func fragmentsDifferPerLayoutManager() {
        let delegate = FirstMarked()
        let pair = Pair("* a\nbody\n", delegateForB: delegate)
        func kinds(_ view: NSTextView) -> [String] {
            let layout = view.textLayoutManager!
            layout.ensureLayout(for: layout.documentRange)
            var out: [String] = []
            layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { out.append(String(describing: type(of: $0))); return true }
            return out
        }
        #expect(kinds(pair.b).first == "MarkedFragment")
        #expect(kinds(pair.a).first == "NSTextLayoutFragment")
    }

    @Test func renderingAttributesStayWithTheirLayoutManager() {
        let pair = Pair("* a\nbody\n")
        let layoutA = pair.a.textLayoutManager!, layoutB = pair.b.textLayoutManager!
        let range = NSTextRange(location: layoutA.documentRange.location, end: layoutA.location(layoutA.documentRange.location, offsetBy: 3))!
        layoutA.addRenderingAttribute(.foregroundColor, value: NSColor.red, for: range)
        func hasRed(_ layout: NSTextLayoutManager) -> Bool {
            var found = false
            layout.enumerateRenderingAttributes(from: layout.documentRange.location, reverse: false) { _, attributes, _ in
                if attributes[.foregroundColor] as? NSColor == .red { found = true }
                return !found
            }
            return found
        }
        #expect(hasRed(layoutA))
        #expect(!hasRed(layoutB))
    }

    @Test func selectionInTheOtherViewMovesWithAnInsertionBeforeIt() {
        let pair = Pair("* a\nbody\n")
        pair.b.setSelectedRange(NSRange(location: 5, length: 0))
        pair.a.insertText("XY", replacementRange: NSRange(location: 0, length: 0))
        #expect(pair.b.selectedRange() == NSRange(location: 7, length: 0))
    }
}
