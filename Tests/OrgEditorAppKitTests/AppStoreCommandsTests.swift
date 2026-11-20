import Foundation
import OrgEditorAppKit
import Testing
import OrgApp

struct AppStoreCommandsTests {
    @Test func hiddenCommandsExist() {
        let ids = Set(EditorCommands.all.map(\.id))
        #expect(AppStoreCommands.hidden.isSubset(of: ids))
    }

    /// LaTeX export is native, so the sandboxed build has it.
    @Test func latexExportIsShown() {
        #expect(!AppStoreCommands.hidden.contains("app.export.latex"))
        #expect(EditorCommands.all.first { $0.id == "app.export.latex" }?.title == "Export to LaTeX")
    }

    @Test func pdfKeysExportThroughWebKit() throws {
        let replacement = try #require(AppStoreCommands.replacement(for: "app.export.pdf"))
        #expect(replacement == "app.export.print-pdf")
        #expect(!AppStoreCommands.hidden.contains(replacement))
        for id in AppStoreCommands.hidden where id != "app.export.pdf" {
            #expect(AppStoreCommands.replacement(for: id) == nil)
        }
    }
}
