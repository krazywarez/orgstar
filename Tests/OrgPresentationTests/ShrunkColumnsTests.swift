import Foundation
import OrgCore
import Testing
@testable import OrgPresentation

struct ShrunkColumnsTests {
    static let table = "| <3> | b |\n|------+---|\n| abcdef | x |\n"

    @Test func startupShrinksCookieColumnsOnlyWithTheWord() {
        let plain = OrgParser.parse("intro\n" + Self.table)
        #expect(ShrunkColumns.startup(plain).isEmpty)
        let tree = OrgParser.parse("#+STARTUP: shrink\n" + Self.table + "\n| a | b |\n")
        let shrunk = ShrunkColumns.startup(tree)
        let start = ("#+STARTUP: shrink\n" as NSString).length
        #expect(Array(shrunk.tables.keys) == [start])
        #expect(shrunk.columns(in: start..<start + 1) == [1])
        #expect(!shrunk.segments.isEmpty)
    }

    @Test func togglesTheColumnAtTheCaret() throws {
        let text = Self.table
        var shrunk = ShrunkColumns()
        let caret = (text as NSString).range(of: "abc").location
        guard case .set(let columns, let table) = shrunk.change(for: "org.table.toggle-column-width", at: caret, in: text) else {
            Issue.record("expected a column")
            return
        }
        #expect(columns == [1])
        shrunk.set(columns, in: table, text: text)
        #expect(shrunk.change(for: "org.table.toggle-column-width", at: caret, in: text) == .set([], table: table))
        #expect(shrunk.change(for: "org.table.expand", at: caret, in: text) == .set([], table: table))
        #expect(shrunk.change(for: "org.table.shrink", at: caret, in: text) == .set([1], table: table))
        #expect(shrunk.change(for: "org.table.shrink", at: (text as NSString).length, in: text + "after\n") == .notInTable)
        guard case .ask(_, let current, _) = shrunk.change(for: "org.table.toggle-column-width", at: 0, in: text) else {
            Issue.record("expected a prompt before the first column")
            return
        }
        #expect(ShrunkColumns.toggled(current, TableShrink.columns("1-2", max: 4)) == [2])
    }

    @Test func typingInAColumnWidensItButCommandsKeepIt() throws {
        let text = Self.table
        let table = try #require(TableShrink.table(at: 0, in: text))
        var shrunk = ShrunkColumns()
        shrunk.set([1], in: table, text: text)
        let at = (text as NSString).range(of: "abc").location
        let edit = TextEdit(range: at..<at, replacement: "z")
        let after = (text as NSString).replacingCharacters(in: NSRange(location: at, length: 0), with: "z")
        var byCommand = shrunk
        #expect(byCommand.map(through: edit, in: after, command: true).count == 1)
        #expect(byCommand.columns(in: table) == [1])
        #expect(shrunk.map(through: edit, in: after, command: false).count == 1)
        #expect(shrunk.isEmpty)
    }

    @Test func editsBeforeATableMoveIt() throws {
        let text = "x\n" + Self.table
        let table = try #require(TableShrink.table(at: 2, in: text))
        var shrunk = ShrunkColumns()
        shrunk.set([1], in: table, text: text)
        let after = "xyz\n" + Self.table
        #expect(shrunk.map(through: TextEdit(range: 1..<1, replacement: "yz"), in: after, command: false).isEmpty)
        #expect(Array(shrunk.tables.keys) == [4])
        #expect(shrunk.segments == TableShrink.segments(4..<4 + (Self.table as NSString).length, column: 1, in: after))
    }
}
