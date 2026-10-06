import Foundation
import Testing
@testable import OrgCore

/// Where org-element finds objects of each kind, against our tree.
struct ObjectParseTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    static let text = """
        * Objects
        Entities \\alpha, \\alpha{}beta, \\nbsp and \\notanentity.
        Scripts x_1 y^2 a_{b c} d^{e} f_(g) h^* snake_case_name n^-1 e_{x_{y}} 2_1.5a.
        Not after space _x ^y.
        Math $x$ and $x+y$, $$e=mc^2$$ and \\(a^2\\) and \\[b\\] and \\frac{1}{2} and \\textbf[opt]{bold}.
        Money $5 and $10, not math $ x$ nor $x $.
        A radio <<<Target Word>>> here; the target word links, Target Words don't.
        In *bold \\beta x_2* and [[link][\\gamma]].
        \\begin{equation}
        x = y^2
        \\end{equation}
          \\begin{align*} a \\end{align*}
        \\begin{x}
        never closed
        """ + "\n"

    static let kinds: [(lisp: String, ours: [SyntaxKind])] = [
        ("entity", [.entity]), ("subscript", [.subscript]), ("superscript", [.superscript]),
        ("latex-fragment", [.latexFragment]), ("radio-target", [.radioTarget]), ("latex-environment", [.latexEnvironment]),
    ]

    func ours(_ kinds: [SyntaxKind]) -> [String] {
        OrgParser.parse(Self.text).root.descendants().filter { kinds.contains($0.kind) }.map { "\($0.range.lowerBound) \($0.range.upperBound)" }
    }

    @Test(.enabled(if: oracle))
    func objectsMatchOrgElement() throws {
        let forms = Self.kinds.map { kind in
            """
            (mapconcat (lambda (o) (format "%d %d" (1- (org-element-begin o))
                                    (1- (save-excursion (goto-char (org-element-end o)) (skip-chars-backward " \\t") (point)))))
                       (org-element-map (org-element-parse-buffer) '\(kind.lisp) #'identity) ",")
            """
        }
        let emacs = try EmacsOracle.evaluate(Self.text, "(with-current-buffer (find-file-noselect \"oracle.org\") (list \(forms.joined(separator: " "))))")
        for (i, kind) in Self.kinds.enumerated() {
            let theirs = emacs[i].split(separator: ",").map(String.init)
            #expect(ours(kind.ours) == theirs, "\(kind.lisp)")
        }
        // Radio links: links whose text is a radio target's.
        let links = try EmacsOracle.evaluate(Self.text, """
            (with-current-buffer (find-file-noselect "oracle.org")
              (list (mapconcat (lambda (o) (format "%d %d" (1- (org-element-begin o)) (1- (save-excursion (goto-char (org-element-end o)) (skip-chars-backward " \\t") (point)))))
                               (org-element-map (org-element-parse-buffer) 'link (lambda (l) (and (equal (org-element-property :type l) "radio") l))) ",")))
            """)
        let radio = OrgParser.parse(Self.text).root.descendants().filter { $0.kind == .link && $0.tokens.first { $0.kind == .linkPath } == nil && !$0.text.hasPrefix("[") && !$0.text.hasPrefix("<") && !$0.text.contains(":") }
        #expect(radio.map { "\($0.range.lowerBound) \($0.range.upperBound)" } == links[0].split(separator: ",").map(String.init))
    }
}
