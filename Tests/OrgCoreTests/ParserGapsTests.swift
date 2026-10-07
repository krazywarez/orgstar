import Foundation
import Testing
@testable import OrgCore

/// Citations, export snippets, inline Babel calls, diary sexps, table.el tables, and item
/// counters and tags, where org-element finds them.
struct ParserGapsTests {
    static let text = #"""
        As [cite:@doe2020] and [cite/t/b:see @a p. 2; @b;and @c-d:e] say, also [cite:pre; @x; post].
        Not a cite: [cite:no key], [cite/:@x], [cite:@k [nested] here], [cite:@open
        and on @@html:<b>bold</b>@@ or @@latex:\emph{x}@@, not @@x@@ or @@:y@@ or @@html:open.
        Calls: call_square(4) call_f[:results raw](x=1, y=(2))[:exports both] xcall_no(1) call_f[x] call_(1).
        %%(diary-float t 4 2) Thanksgiving
        Diary <%%(diary-float t 4 2)>, <%%(x) 10:00>, <%%()>, <%%(a]b)>, <%%(open and <%%(y)
          %%(indented) is text

        +----+-----+
        | a  | b   |
        +----+-----+
        | c  | d   |
        +----+-----+

        +--+--+
        Single rule is a paragraph.

        +--+
        |x |
        not closed by a rule

        | org | table |
        +---+---+
        | other |
        +-+
        +-+

        - term :: definition with *bold*
        - a :: b :: c
        - [X] boxed :: yes
        - [@3] counted
        - [@start:7] [X] both
        - no tag::here
        - tag ::
        1. one :: two
        2. [@5] five
        - plain
        - *bold* term :: x
        """# + "\n"

    static let kinds: [(lisp: String, ours: SyntaxKind)] = [
        ("citation", .citation), ("citation-reference", .citationReference), ("export-snippet", .exportSnippet),
        ("inline-babel-call", .inlineBabelCall), ("timestamp", .timestamp), ("diary-sexp", .diarySexp), ("paragraph", .paragraph), ("item", .item),
    ]

    @Test func objectsAndElementsMatchOrgElement() throws {
        let tree = OrgParser.parse(Self.text)
        var forms = Self.kinds.map { kind in
            "(mapconcat (lambda (o) (format \"%d\" (1- (org-element-begin o)))) (org-element-map (org-element-parse-buffer) '\(kind.lisp) #'identity) \",\")"
        }
        forms.append("(mapconcat (lambda (o) (format \"%d:%s\" (1- (org-element-begin o)) (org-element-property :type o))) (org-element-map (org-element-parse-buffer) 'table #'identity) \",\")")
        forms.append("""
            (mapconcat (lambda (o) (format "%s|%s|%s" (let ((tag (org-element-interpret-data (org-element-property :tag o)))) (if (string-empty-p tag) "-" tag))
                                           (or (org-element-property :counter o) "-") (or (org-element-property :checkbox o) "-")))
                       (org-element-map (org-element-parse-buffer) 'item #'identity) ",")
            """)
        let emacs = try EmacsOracle.evaluate(Self.text, "(with-current-buffer (find-file-noselect \"oracle.org\") (org-mode) (list \(forms.joined(separator: " "))))")
        let nodes = tree.root.descendants()
        for (i, kind) in Self.kinds.enumerated() {
            let ours = nodes.filter { $0.kind == kind.ours }.map { String($0.range.lowerBound) }
            #expect(ours == emacs[i].split(separator: ",").map(String.init), "\(kind.lisp)")
        }
        let tables = nodes.filter { $0.kind == .table || $0.kind == .tableEl }.map { "\($0.range.lowerBound):\($0.kind == .table ? "org" : "table.el")" }
        #expect(tables == emacs[Self.kinds.count].split(separator: ",").map(String.init), "tables")
        let items = nodes.filter { $0.kind == .item }.map { item -> String in
            let tag = item.firstChild(.itemTag)?.text ?? "-"
            let counter = item.tokens.first { $0.kind == .counter }.map { $0.text.replacingOccurrences(of: "[@start:", with: "").replacingOccurrences(of: "[@", with: "").replacingOccurrences(of: "]", with: "") } ?? "-"
            let box = item.tokens.first { $0.kind == .checkbox }.map { ["[X]": "on", "[x]": "on", "[ ]": "off", "[-]": "trans"][$0.text]! } ?? "-"
            return "\(tag)|\(counter)|\(box)"
        }
        #expect(items == emacs[Self.kinds.count + 1].split(separator: ",").map(String.init), "items")
    }

    @Test func citationParts() throws {
        let tree = OrgParser.parse("[cite/t:see @a p. 2; @b; post]\n")
        let cite = try #require(tree.root.descendants().first { $0.kind == .citation })
        #expect(cite.text == "[cite/t:see @a p. 2; @b; post]")
        let references = cite.children.filter { $0.kind == .citationReference }
        #expect(references.map(\.text) == ["see @a p. 2;", " @b;"])
        #expect(references.compactMap { $0.tokens.first { $0.kind == .citationKey }?.text } == ["@a", "@b"])
    }
}

/// The new syntax through ox-html, compared as the conformance files are.
struct ParserGapsExportTests {
    static let text = """
        Raw @@html:<b>bold</b>@@ and @@latex:\\emph{x}@@ here.

        %%(diary-float t 4 2) Thanksgiving

        - term :: definition here
        - untagged
        - [X] boxed :: yes


        1. one
        2. two


        - [@3] unordered counter
        """ + "\n"

    @Test func htmlMatchesOxHTML() throws {
        let emacs = try EmacsOracle.evaluate(Self.text, """
            (list (progn (require 'ox-html)
                         (with-current-buffer (find-file-noselect "oracle.org")
                           (org-export-as 'html nil nil t '(:with-toc nil :section-numbers nil)))))
            """)
        let ours = Skeleton.reduce(HTMLExport.body(Self.text))
        #expect(ours == Skeleton.reduce(emacs[0]), "ours:\n\(ours)\nemacs:\n\(Skeleton.reduce(emacs[0]))")
        // Org 9.8.7's ox-html fails on an ordered item's counter (`format` given a number);
        // the value is what it means to write.
        #expect(HTMLExport.body("1. one\n2. [@5] five\n").contains("<li value=\"5\">five</li>"))
    }
}
