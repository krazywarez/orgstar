import Foundation

/// Colored source code for HTML export, as `org-html-htmlize-output-type` `css` writes it:
/// spans with `org-…` classes, and the stylesheet that colors them. The apps make one from
/// their tree-sitter highlighter and theme; without one, code is exported plain.
public struct HTMLCodeStyle: Sendable {
    /// Classes for ranges of `code` (UTF-16 offsets) in a language; later ranges win.
    public let classes: @Sendable (_ language: String, _ code: String) -> [(range: Range<Int>, cls: String)]
    /// CSS rules for the classes, added to the page's stylesheet.
    public let css: String

    public init(css: String, classes: @escaping @Sendable (_ language: String, _ code: String) -> [(range: Range<Int>, cls: String)]) {
        self.classes = classes
        self.css = css
    }

    /// `code` escaped, with the spans; nil when the language has no colors.
    func html(language: String, code: String) -> String? {
        let runs = classes(language, code)
        guard !runs.isEmpty else { return nil }
        let units = Array(code.utf16)
        var at = [String?](repeating: nil, count: units.count)
        for run in runs {
            for i in max(0, run.range.lowerBound)..<min(units.count, run.range.upperBound) { at[i] = run.cls }
        }
        var out = ""
        var start = 0
        while start < units.count {
            var end = start + 1
            while end < units.count, at[end] == at[start] { end += 1 }
            let piece = HTMLRenderer.escape(String(utf16CodeUnits: Array(units[start..<end]), count: end - start))
            out += at[start].map { "<span class=\"\($0)\">\(piece)</span>" } ?? piece
            start = end
        }
        return out
    }
}
