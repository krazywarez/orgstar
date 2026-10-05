import OrgCore
import Testing
@testable import OrgDocument

func state(_ text: String) -> DocumentState {
    DocumentState(bytes: Array(text.utf8))
}

struct DocumentStateTests {
    @Test func applyUndoRedo() throws {
        var doc = state("* a\nbody\n")
        try doc.apply([TextEdit(range: 2..<3, replacement: "TODO b")], baseRevision: 0)
        #expect(doc.text == "* TODO b\nbody\n")
        #expect(doc.revision == 1)
        #expect(doc.isDirty)
        #expect(doc.tree.green == OrgParser.parse(doc.text).green)

        #expect(doc.undo() != nil)
        #expect(doc.text == "* a\nbody\n")
        #expect(!doc.isDirty)
        #expect(doc.tree.green == OrgParser.parse(doc.text).green)

        #expect(doc.redo() != nil)
        #expect(doc.text == "* TODO b\nbody\n")
    }

    @Test func groupedEditsAreOneUndoStep() throws {
        var doc = state("ab cd ef\n")
        try doc.apply([TextEdit(range: 0..<2, replacement: "X"), TextEdit(range: 6..<8, replacement: "YYY")], baseRevision: 0)
        #expect(doc.text == "X cd YYY\n")
        _ = doc.undo()
        #expect(doc.text == "ab cd ef\n")
    }

    @Test func rejectsStaleOverlappingAndReadOnly() throws {
        var doc = state("abc\n")
        #expect(throws: DocumentState.EditError.staleRevision) { try doc.apply([], baseRevision: 5) }
        #expect(throws: DocumentState.EditError.overlappingEdits) {
            try doc.apply([TextEdit(range: 0..<2, replacement: ""), TextEdit(range: 1..<3, replacement: "")], baseRevision: 0)
        }
        var invalid = DocumentState(bytes: [0x61, 0xFF])
        #expect(throws: DocumentState.EditError.readOnly) { try invalid.apply([], baseRevision: 0) }
        #expect(throws: DocumentState.EditError.readOnly) { try invalid.encodedText() }
    }

    @Test func newEditClearsRedo() throws {
        var doc = state("a\n")
        try doc.apply([TextEdit(range: 0..<0, replacement: "x")], baseRevision: 0)
        _ = doc.undo()
        try doc.apply([TextEdit(range: 0..<0, replacement: "y")], baseRevision: doc.revision)
        #expect(!doc.canRedo)
    }

    @Test func keepsBOMWhenEncoding() throws {
        var doc = DocumentState(bytes: [0xEF, 0xBB, 0xBF] + Array("a\n".utf8))
        try doc.apply([TextEdit(range: 0..<1, replacement: "b")], baseRevision: 0)
        #expect(try doc.encodedText() == [0xEF, 0xBB, 0xBF] + Array("b\n".utf8))
    }

    @Test func externalChangeReloadsCleanBuffer() {
        var doc = state("a\nb\n")
        #expect(doc.diskChanged(to: Array("a\nb\n".utf8)) == .unchanged)
        guard case .reloaded = doc.diskChanged(to: Array("a\nc\n".utf8)) else {
            Issue.record("expected a reload")
            return
        }
        #expect(doc.text == "a\nc\n")
        #expect(!doc.isDirty)
    }

    @Test func externalChangeMergesIntoEditedBuffer() throws {
        var doc = state("a\nb\nc\n")
        try doc.apply([TextEdit(range: 0..<1, replacement: "A")], baseRevision: 0)
        guard case .merged = doc.diskChanged(to: Array("a\nb\nC\n".utf8)) else {
            Issue.record("expected a merge")
            return
        }
        #expect(doc.text == "A\nb\nC\n")
        #expect(doc.mergeBase == Array("a\nb\nC\n".utf8))
        #expect(doc.isDirty)
        #expect(!doc.canUndo)
    }

    @Test func conflictingExternalChangeLeavesBufferAlone() throws {
        var doc = state("a\n")
        try doc.apply([TextEdit(range: 0..<1, replacement: "X")], baseRevision: 0)
        guard case .conflict = doc.diskChanged(to: Array("Y\n".utf8)) else {
            Issue.record("expected a conflict")
            return
        }
        #expect(doc.text == "X\n")
        #expect(doc.mergeBase == Array("a\n".utf8))
    }
}

struct ViewStateTests {
    @Test func mapsSelectionAndFolds() {
        let view = ViewState(selection: [2..<6], folds: [0, 10])
        let mapped = view.mapped(through: [TextEdit(range: 1..<1, replacement: "xx"), TextEdit(range: 8..<9, replacement: "")])
        #expect(mapped.selection == [4..<8])
        #expect(mapped.folds == [0, 11])
    }

    @Test func offsetsInsideAReplacementMoveToItsEnd() {
        let edits = [TextEdit(range: 2..<5, replacement: "ab")]
        #expect(mapOffset(2, edits) == 2)
        #expect(mapOffset(3, edits) == 4)
        #expect(mapOffset(5, edits) == 4)
        #expect(mapOffset(6, edits) == 5)
        #expect(mapOffset(2, [TextEdit(range: 2..<2, replacement: "ab")]) == 4)
    }

    @Test func pruneDropsFoldsThatAreNoLongerHeadings() {
        let tree = OrgParser.parse("* a\ntext\n* b\n")
        #expect(ViewState(folds: [0, 4, 9]).pruned(to: tree).folds == [0, 9])
    }
}

struct CommandRunTests {
    @Test func runAppliesEditsAsOneStep() throws {
        var doc = state("* a\n")
        let step = try doc.run(TodoCycle(), selection: [2..<2])
        guard case .commit(let result) = step else {
            Issue.record("expected a commit")
            return
        }
        #expect(doc.text == "* TODO a\n")
        #expect(result.selection == [7..<7])
        #expect(doc.tree.green == OrgParser.parse(doc.text).green)
        _ = doc.undo()
        #expect(doc.text == "* a\n")
    }

    @Test func failuresChangeNothing() throws {
        var doc = state("text\n")
        #expect(try doc.run(TodoCycle(), selection: [0..<0]) == .failed("Before first headline"))
        #expect(doc.revision == 0)
    }
}
