import AppKit
import OrgCore
import OrgDocument
import OrgPresentation
@testable import OrgApp
import Testing
@testable import OrgEditorAppKit

/// An editor in an offscreen window, laid out.
@MainActor
final class Harness {
    let editor: OrgEditor
    let window: NSWindow

    convenience init(_ text: String) {
        self.init(DocumentState(bytes: Array(text.utf8)))
        drainStyling()
        layout()
    }

    /// The editor as a window would show it first: background styling not yet run.
    init(_ document: DocumentState, layout: Bool = true, mode: OrgEditor.Mode = .org) {
        _ = NSApplication.shared
        editor = OrgEditor(document: document, mode: mode)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.makeScrollView()
        window.makeFirstResponder(editor.textView)
        if layout { self.layout() }
    }

    func drainStyling() {
        editor.finishStyling()
    }

    var textView: NSTextView { editor.textView }
    var string: String { textView.string }

    func layout() {
        let manager = editor.textLayoutManager
        manager.ensureLayout(for: manager.documentRange)
    }

    /// Text of each laid-out paragraph.
    var visibleLines: [String] {
        layout()
        let manager = editor.textLayoutManager
        var lines: [String] = []
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
            let content = manager.textContentManager!
            let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let end = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.endLocation)
            lines.append((self.string as NSString).substring(with: NSRange(location: start, length: end - start)))
            return true
        }
        return lines.filter { !$0.isEmpty }
    }

    func caret(at offset: Int) {
        textView.setSelectedRange(NSRange(location: offset, length: 0))
    }

    var caret: Int { textView.selectedRange().location }

    func offset(of line: String) -> Int {
        (string as NSString).range(of: line).location
    }

    func checkInSync() {
        #expect(editor.document.text == string)
        #expect(editor.document.tree.green == OrgParser.parse(string).green)
    }
}

let outline = "* a\nbody\n** b\nmore\n* c\ntext\n"

@MainActor
struct FoldingTests {
    @Test func foldingHidesTheSubtree() {
        let h = Harness(outline)
        #expect(h.visibleLines == ["* a\n", "body\n", "** b\n", "more\n", "* c\n", "text\n"])
        h.caret(at: 1)
        #expect(h.editor.cycleAtCaret())
        #expect(h.visibleLines == ["* a\n", "* c\n", "text\n"])
        h.editor.cycleAtCaret()
        #expect(h.visibleLines == ["* a\n", "body\n", "** b\n", "* c\n", "text\n"])
        h.editor.cycleAtCaret()
        #expect(h.visibleLines.count == 6)
    }

    @Test func globalCycleAndStartup() {
        let h = Harness(outline)
        h.editor.run("org.cycle-global")
        h.editor.run("org.cycle-global")
        #expect(h.visibleLines == ["* a\n", "** b\n", "* c\n"])
        h.editor.run("org.cycle-global")
        #expect(h.visibleLines.count == 6)
        #expect(Harness("#+STARTUP: overview\n" + outline).visibleLines == ["#+STARTUP: overview\n", "* a\n", "* c\n"])
    }

    @Test func revealUnfoldsWhatHidesTheTarget() {
        let h = Harness("#+STARTUP: overview\n" + outline)
        let target = h.offset(of: "more")
        h.editor.reveal(target)
        #expect(h.visibleLines.contains("more\n"))
        #expect(h.caret == target)
    }

    @Test func readOnlyAndReloadKeepFolds() {
        let editor = OrgEditor(document: DocumentState(bytes: Array(outline.utf8)), editable: false)
        #expect(!editor.textView.isEditable)
        editor.setFolds(FoldState(folds: [19]))
        editor.diskChanged(to: Array(("new line\n" + outline).utf8))
        #expect(editor.document.text == "new line\n" + outline)
        #expect(editor.foldState.folds == [28])
    }

    @Test func tabFoldsOnlyOnHeadings() {
        let h = Harness(outline)
        h.caret(at: 5)
        #expect(!h.editor.cycleAtCaret())
        h.editor.run("org.cycle-global")
        #expect(h.visibleLines == ["* a\n", "* c\n"])
    }

    @Test func caretMovesOverFoldedText() {
        let h = Harness(outline)
        h.caret(at: 1)
        h.editor.cycleAtCaret()
        h.caret(at: 0)
        h.textView.moveDown(nil)
        #expect(h.caret >= h.offset(of: "* c") && h.caret < h.offset(of: "text"))
        h.caret(at: 3)
        h.textView.moveRight(nil)
        #expect(h.caret == h.offset(of: "* c"))
        h.textView.moveLeft(nil)
        #expect(h.caret == 3)
    }

    @Test func copyingAcrossAFoldIncludesHiddenText() {
        let h = Harness(outline)
        h.caret(at: 1)
        h.editor.cycleAtCaret()
        h.textView.setSelectedRange(NSRange(location: 0, length: h.offset(of: "text")))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("orgstar-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(h.textView.writeSelection(to: pasteboard, types: h.textView.writablePasteboardTypes))
        #expect(pasteboard.string(forType: .string) == "* a\nbody\n** b\nmore\n* c\n")
    }

    @Test func foldsFollowEdits() {
        let h = Harness(outline)
        h.caret(at: h.offset(of: "* c") + 1)
        h.editor.cycleAtCaret()
        h.caret(at: 0)
        h.textView.insertText("new ", replacementRange: NSRange(location: 2, length: 0))
        #expect(h.visibleLines == ["* new a\n", "body\n", "** b\n", "more\n", "* c\n"])
        h.checkInSync()
    }
}

@MainActor
struct EditingTests {
    @Test func typingKeepsTheDocumentInSync() {
        let h = Harness(outline)
        h.caret(at: h.offset(of: "body") + 4)
        h.textView.insertText(" *bold*", replacementRange: h.textView.selectedRange())
        h.textView.insertNewline(nil)
        h.textView.insertText("* new heading", replacementRange: h.textView.selectedRange())
        h.textView.deleteBackward(nil)
        h.checkInSync()
        #expect(h.editor.document.isDirty)
    }

    @Test func inputMethodComposition() {
        let h = Harness("* a\n")
        h.caret(at: 3)
        h.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(h.textView.hasMarkedText())
        h.textView.setMarkedText("かん", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        h.textView.insertText("漢", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!h.textView.hasMarkedText())
        #expect(h.string == "* a漢\n")
        h.checkInSync()
    }

    @Test func undoKeepsTheDocumentInSync() {
        let h = Harness(outline)
        h.caret(at: 3)
        h.textView.insertText("xyz", replacementRange: h.textView.selectedRange())
        h.textView.breakUndoCoalescing()
        h.textView.undoManager?.undo()
        #expect(h.string == outline)
        h.checkInSync()
    }

    @Test func styling() throws {
        let h = Harness("** b\nbody\n")
        let storage = try #require(h.textView.textStorage)
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .clear)
        let style = try #require(storage.attribute(.paragraphStyle, at: 6, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.firstLineHeadIndent == 3 * h.editor.theme.column)
        h.caret(at: 0)
        h.textView.insertText("*", replacementRange: NSRange(location: 0, length: 0))
        let deeper = try #require(storage.attribute(.paragraphStyle, at: 7, effectiveRange: nil) as? NSParagraphStyle)
        #expect(deeper.firstLineHeadIndent == 4 * h.editor.theme.column)
    }

    @Test func accessibilityReadsTheWholeText() {
        let h = Harness(outline)
        h.caret(at: 1)
        h.editor.cycleAtCaret()
        #expect(h.textView.accessibilityValue() as? String == outline)
        h.textView.setSelectedRange(NSRange(location: 0, length: 3))
        #expect(h.textView.accessibilitySelectedText() == "* a")
        #expect(h.textView.accessibilityLine(for: h.offset(of: "* c")) >= 1)
    }

    @Test func saveWritesAndClearsDirty() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.org")
        try Data(outline.utf8).write(to: file)
        let h = Harness(outline)
        h.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        let saver = Saver(fileSystem: CoordinatedFileSystem(), recovery: FileRecoveryStore(directory: folder.appendingPathComponent("r")))
        #expect(try h.editor.save(using: saver, to: file) == .saved)
        #expect(!h.editor.document.isDirty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "x" + outline)
    }
}

@MainActor
struct BufferTests {
    @Test func updateMapsCaretAndFoldsAndClearsUndo() {
        let h = Harness(outline)
        var changes = 0
        h.editor.onChange = { changes += 1 }
        h.caret(at: 1)
        h.textView.insertText("x", replacementRange: NSRange(location: 4, length: 0))
        #expect(changes == 1)
        RunLoop.current.run(until: Date())
        #expect(h.textView.undoManager?.canUndo == true)
        h.editor.setFolds(FoldState(folds: [h.offset(of: "** b")]))
        h.caret(at: h.offset(of: "* c") + 2)
        h.editor.update { $0 = DocumentState(bytes: Array(("new\n" + outline).utf8)) }
        #expect(changes == 2)
        #expect(h.string == "new\n" + outline)
        #expect(h.caret == h.offset(of: "* c") + 2)
        #expect(h.editor.foldState.folds == [h.offset(of: "** b")])
        #expect(h.textView.undoManager?.canUndo != true)
        h.checkInSync()
    }

    /// Each buffer's editor reports its own changes: a background buffer's edit saves its
    /// file, not the shown one's.
    @Test func backgroundEditorsSaveTheirOwnFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a.org"), b = folder.appendingPathComponent("b.org")
        try Data("* A\n".utf8).write(to: a)
        try Data("* B\n".utf8).write(to: b)
        let session = DocumentSession(recovery: FileRecoveryStore(directory: folder.appendingPathComponent("r")))
        session.autosaveDelay = .milliseconds(10)
        var harnesses: [String: Harness] = [:]
        for file in [a, b] {
            session.open(file.path)
            let h = Harness(try #require(session.document))
            let path = file.path
            h.editor.onChange = { [weak session] in session?.bufferChanged(path) }
            session.attach(h.editor)
            harnesses[path] = h
        }
        #expect(session.path == b.path)
        harnesses[a.path]!.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        #expect(session.dirtyPaths == [a.path])
        #expect(!session.isDirty)
        for _ in 0..<50 where (try? String(contentsOf: a, encoding: .utf8)) != "x* A\n" {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try String(contentsOf: a, encoding: .utf8) == "x* A\n")
    }

    /// The wiring the app uses: the editor is the session's buffer and reports typing.
    @Test func sessionSavesWhatIsTyped() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.org")
        try Data(outline.utf8).write(to: file)
        let session = DocumentSession(recovery: FileRecoveryStore(directory: folder.appendingPathComponent("r")))
        session.autosaveDelay = .milliseconds(10)
        session.open(file.path)
        let h = Harness(try #require(session.document))
        h.editor.onChange = { [weak session] in session?.bufferChanged() }
        session.attach(h.editor)
        h.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        #expect(session.isDirty)
        await session.autosave?.value
        #expect(!session.isDirty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "x" + outline)

        try Data(("x" + outline + "end\n").utf8).write(to: file)
        session.fileChanged(file.path)
        #expect(h.string == "x" + outline + "end\n")
    }
}

@MainActor
struct RestyleTests {
    func indent(_ h: Harness, at line: String) -> CGFloat? {
        let style = h.textView.textStorage?.attribute(.paragraphStyle, at: h.offset(of: line), effectiveRange: nil) as? NSParagraphStyle
        return style.map { $0.firstLineHeadIndent / h.editor.theme.column }
    }

    @Test func newHeadingReindentsTheLinesItTakesOver() {
        let h = Harness("* a\none\ntwo\nthree\n")
        h.textView.insertText("** b\n", replacementRange: NSRange(location: h.offset(of: "two"), length: 0))
        #expect(indent(h, at: "one") == 2)
        #expect(indent(h, at: "three") == 3)
        h.checkInSync()
    }

    @Test func joiningAwayAHeadingReindentsItsBody() {
        let h = Harness("* a\none\n** b\ntwo\nthree\n")
        h.textView.insertText("", replacementRange: NSRange(location: h.offset(of: "** b") - 1, length: 1))
        #expect(indent(h, at: "three") == 2)
        h.checkInSync()
    }

    @Test func typingASpaceAfterAStarMakesAHeading() {
        let h = Harness("* a\n*x\nbody\nmore\n")
        h.textView.insertText(" ", replacementRange: NSRange(location: h.offset(of: "*x") + 1, length: 0))
        #expect(indent(h, at: "more") == 2)
        h.checkInSync()
    }
}

@MainActor
struct RestyleFuzzTests {
    /// After each random edit, the restyled text must equal a fresh editor's full styling. Set
    /// `ORGSTAR_RESTYLE_EDITS` and `ORGSTAR_FUZZ_SEED` for longer runs.
    @Test func incrementalRestyleEqualsFullRestyle() throws {
        let environment = ProcessInfo.processInfo.environment
        var state = UInt64(environment["ORGSTAR_FUZZ_SEED"] ?? "") ?? 20261006
        let count = Int(environment["ORGSTAR_RESTYLE_EDITS"] ?? "") ?? 300
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        let pieces = ["* ", "** ", "*", " ", "\n", "x", "*b*", "TODO ", "- ", "| a |", "#+begin_src\n", "#+end_src\n", ":PROPERTIES:\n", ":END:\n", "[[l][d]]", "<2026-10-04 Sun>"]
        let h = Harness("* a\nbody *b*\n** b\n- item\nmore\n* c\ntext\n")
        for n in 0..<count {
            let length = (h.string as NSString).length
            let start = next(length + 1)
            let end = min(length, start + next(4))
            let replacement = next(3) == 0 ? "" : pieces[next(pieces.count)]
            h.textView.insertText(replacement, replacementRange: NSRange(location: start, length: end - start))
            let fresh = Harness(h.string)
            let same = h.textView.textStorage!.isEqual(to: fresh.textView.textStorage!)
            #expect(same, "edit \(n): \(start)..<\(end) \(replacement.debugDescription) -> \(h.string.debugDescription)")
            if !same { break }
        }
        h.checkInSync()
    }
}

@MainActor
struct InitialStylingTests {
    @Test func stylesTheFirstScreenThenTheRest() throws {
        let line = "* heading *bold*\nbody text\n"
        let text = String(repeating: line, count: 4_000)
        let h = Harness(DocumentState(bytes: Array(text.utf8)), layout: false)
        let length = (text as NSString).length
        #expect(h.editor.styledUpTo >= OrgEditor.firstStyleChunk && h.editor.styledUpTo < length)
        h.textView.insertText("x", replacementRange: NSRange(location: length - 3, length: 0))
        h.drainStyling()
        #expect(h.editor.styledUpTo == length + 1)
        #expect(h.textView.textStorage!.isEqual(to: Harness(h.string).textView.textStorage!))
    }

    @Test func editsBeforeTheWatermarkShiftIt() {
        let text = String(repeating: "line of text\n", count: 5_000)
        let h = Harness(DocumentState(bytes: Array(text.utf8)), layout: false)
        let before = h.editor.styledUpTo
        h.textView.insertText("abc", replacementRange: NSRange(location: 0, length: 0))
        #expect(h.editor.styledUpTo == before + 3)
    }
}

struct HangingIndentTests {
    @Test(arguments: [
        ("plain", 0), ("  indented", 2), ("- item", 2), ("  - [X] done", 8), ("12. step", 4),
        ("* heading-like", 0), ("  * starred item", 4), ("-not a bullet", 0), ("\t- tab", 10),
    ])
    func columns(line: String, expected: Int) {
        #expect(OrgEditor.hangingColumns(line) == expected)
    }
}

@MainActor
struct CommandTests {
    @Test func performEditsThroughTheTextView() {
        let h = Harness("* a :t:\nbody\n")
        var messages: [String] = []
        h.editor.onMessage = { messages.append($0) }
        h.caret(at: 2)
        h.editor.perform(PriorityUp())
        #expect(h.string.hasPrefix("* [#B] a "))
        #expect(h.caret == 2)
        h.checkInSync()
        // Undo groups by event: let the run loop close the first command's group, as a key
        // press would.
        RunLoop.current.run(until: Date())
        h.editor.perform(TodoCycle())
        #expect(h.string.hasPrefix("* TODO [#B] a "))
        RunLoop.current.run(until: Date())
        h.textView.undoManager?.undo()
        #expect(h.string.hasPrefix("* [#B] a "))
        h.checkInSync()
        h.caret(at: h.offset(of: "body"))
        h.editor.perform(PromoteHeading())
        #expect(messages == ["Not on a heading"])
    }

    @Test func readOnlyEditorsRefuseEdits() {
        let editor = OrgEditor(document: DocumentState(bytes: Array("* a\n".utf8)), editable: false)
        editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(editor.perform(TodoCycle()) == .failed("read-only"))
        #expect(editor.document.text == "* a\n")
    }
}
