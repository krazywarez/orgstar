import Foundation
import OrgCore
import OrgPresentation
import Testing
@testable import OrgHighlight

struct HTMLCodeStyleTests {
    @Test func sourceBlocksGetHtmlizeClassesAndThemeColors() {
        let style = HTMLCodeStyle(highlighter: TreeSitterHighlighter(), theme: .default)
        let text = "#+begin_src python\ndef f(x):\n    return \"<a>\"  # note\n#+end_src\n"
        let page = HTMLExport.page(text, fallbackTitle: "t", codeStyle: style)
        #expect(page.contains("<span class=\"org-keyword\">def</span>"))
        #expect(page.contains("<span class=\"org-string\">&quot;&lt;a&gt;&quot;</span>") || page.contains("<span class=\"org-string\">\"&lt;a&gt;\"</span>"))
        #expect(page.contains("<span class=\"org-comment\"># note</span>"))
        #expect(page.contains(".org-keyword { color: #") && page.contains("@media (prefers-color-scheme: dark) { .org-"))
        // Unknown languages and plain export stay as before.
        #expect(HTMLExport.page("#+begin_src nosuchlang\na < b\n#+end_src\n", fallbackTitle: "t", codeStyle: style).contains("<code class=\"language-nosuchlang\">a &lt; b</code>"))
        #expect(!HTMLExport.page(text, fallbackTitle: "t").contains("<span class=\"org-"))
    }
}
