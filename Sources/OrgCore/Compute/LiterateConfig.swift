import Foundation

extension Tangle {
    /// The Emacs Lisp a literate configuration (`config.org`) tangles to, as
    /// `org-babel-load-file` and Doom's literate module do: `emacs-lisp` and `elisp` blocks,
    /// with `:tangle` defaulting to the target, so only `:tangle no` leaves a block out, and
    /// none under COMMENT or ARCHIVE headings. Other lines are blank, so that a line of the
    /// result is the same line of `text`.
    public static func literateLisp(_ text: String) -> String {
        let ns = text as NSString
        let model = DocumentModel(tree: OrgParser.parse(text))
        var lines = Array(repeating: "", count: text.components(separatedBy: "\n").count)
        for block in model.srcBlocks where ["emacs-lisp", "elisp"].contains(block.language ?? "") && !excluded(block, model: model) {
            guard let params = try? Babel.Params(block: block, model: model, text: ns, defaults: [(":tangle", "yes")]),
                  params.single[":tangle"] != "no" else { continue }
            let first = ns.substring(to: block.range.lowerBound).components(separatedBy: "\n").count
            for (i, line) in block.body.components(separatedBy: "\n").enumerated() where first + i < lines.count {
                lines[first + i] = line
            }
        }
        return lines.joined(separator: "\n")
    }
}
