import Foundation
import OrgCore

/// Where spell checking stays off: the faces spell-fu skips in Org (code, links, dates, tags,
/// keywords, meta lines, properties, LaTeX, src and example blocks).
public enum SpellCheck {
    public static func skipped(_ tree: OrgTree) -> [Range<Int>] {
        let ns = tree.text as NSString
        func line(_ p: Int) -> Range<Int> {
            let r = ns.lineRange(for: NSRange(location: p, length: 0))
            return r.location..<(r.location + r.length)
        }
        let whole: Set<SyntaxKind> = [.code, .verbatim, .link, .timestamp, .footnoteReference, .statisticsCookie, .target, .radioTarget,
                                      .macro, .inlineSourceBlock, .latexFragment, .entity, .latexEnvironment, .keyword, .affiliatedKeyword,
                                      .planning, .clock, .propertyDrawer, .fixedWidth, .tableFormula, .horizontalRule,
                                      .citation, .exportSnippet, .inlineBabelCall, .diarySexp]
        let tokens: Set<SyntaxKind> = [.stars, .todoKeyword, .priority, .tags, .bullet, .checkbox, .counter]
        var ranges: [Range<Int>] = []
        for node in tree.root.descendants() {
            if whole.contains(node.kind) {
                ranges.append(node.range)
                continue
            }
            switch node.kind {
            case .block, .dynamicBlock, .drawer:
                let first = line(node.range.lowerBound)
                let name = ns.substring(with: NSRange(location: first.lowerBound, length: first.count)).trimmingCharacters(in: .whitespaces).lowercased()
                if node.kind == .block, ["src", "example", "export", "comment"].contains(where: { name.hasPrefix("#+begin_\($0)") }) {
                    ranges.append(node.range)
                } else {
                    ranges.append(first)
                    var end = node.range.upperBound
                    while end > node.range.lowerBound, ns.character(at: end - 1) == 10 { end -= 1 }
                    ranges.append(line(max(node.range.lowerBound, end - 1)))
                }
            case .heading, .item:
                ranges += node.tokens.filter { tokens.contains($0.kind) }.map(\.range)
            default:
                break
            }
        }
        return ranges
    }

    /// The parts of `range` outside every `skipped` range, in order: what a spell checker of
    /// the app's own checks.
    public static func checkable(_ range: Range<Int>, skipped: [Range<Int>]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = range.lowerBound
        for skip in skipped.filter({ $0.overlaps(range) }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if skip.lowerBound > start { out.append(start..<skip.lowerBound) }
            start = max(start, skip.upperBound)
        }
        if start < range.upperBound { out.append(start..<range.upperBound) }
        return out
    }
}
