import Foundation
import Testing
@testable import OrgCore

/// Where org-element finds inline tasks, property drawers and list items.
struct ElementParseTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    static let text = """
        # A comment
        :PROPERTIES:
        :Owner:    me
        :END:
        Intro.
        * Heading
        Body.
        *************** TODO Inline task :tag:
        :PROPERTIES:
        :Effort:   1:00
        :END:
        Task body.
        *************** END
        After the task.
        *************** Single-line task
        More text.
        ** Child
        a. alpha item
        b) beta item
        - plain
        1. one
        """ + "\n"

    static let kinds: [(lisp: String, ours: SyntaxKind)] = [("inlinetask", .inlineTask), ("property-drawer", .propertyDrawer), ("item", .item), ("headline", .section)]

    @Test(.enabled(if: oracle))
    func elementsMatchOrgElement() throws {
        var settings = OrgSettings.default
        settings.listAllowAlphabetical = true
        let tree = OrgParser.parse(Self.text, defaults: settings)
        let forms = Self.kinds.map { kind in
            "(mapconcat (lambda (o) (format \"%d\" (1- (org-element-begin o)))) (org-element-map (org-element-parse-buffer) '\(kind.lisp) #'identity) \",\")"
        }
        let emacs = try EmacsOracle.evaluate(Self.text, "(with-current-buffer (find-file-noselect \"oracle.org\") (org-mode) (list \(forms.joined(separator: " "))))",
                                             prelude: "(require 'org-inlinetask) (setq org-list-allow-alphabetical t)")
        for (i, kind) in Self.kinds.enumerated() {
            let ours = tree.root.descendants().filter { $0.kind == kind.ours }.map { String($0.range.lowerBound) }
            #expect(ours == emacs[i].split(separator: ",").map(String.init), "\(kind.lisp)")
        }
        #expect(DocumentModel(tree: tree).fileProperties.contains { $0.key == "Owner" && $0.value == "me" })
    }
}
