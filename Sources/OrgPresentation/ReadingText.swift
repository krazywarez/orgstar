import Foundation
import OrgCore

/// A range of a file to read rather than edit: its style runs as segments, with the brackets
/// and targets of described links hidden (`org-link-descriptive`) and folded drawers shown as
/// their first line and `…`, as the editor shows them.
public enum ReadingText {
    public struct Segment: Sendable, Equatable {
        public var text: String
        public var roles: Set<StyleRole>
        /// The link this text belongs to.
        public var link: OrgLink?
        /// Where the text starts in the file.
        public var offset: Int
        /// A pretty sub/superscript's body: true raised, false lowered.
        public var superscript: Bool?
        /// A fold's `…`: where the hidden range it stands for starts.
        public var unfolds: Int?
    }

    /// How the text shows, as the editor's display settings make it.
    public struct Display: Sendable {
        /// Link brackets and targets, and emphasis markers, shown; no pretty entities.
        public var showMarkup = false
        /// `org-hide-emphasis-markers`, `org-pretty-entities` and its braces.
        public var options = EditingOptions.org
        /// Colors code in src blocks.
        public var highlighter: (any CodeHighlighter)?

        public init(showMarkup: Bool = false, options: EditingOptions = .org, highlighter: (any CodeHighlighter)? = nil) {
            self.showMarkup = showMarkup
            self.options = options
            self.highlighter = highlighter
        }
    }

    /// `folded` are drawers' and blocks' hidden ranges (`Wrapper.hidden`).
    public static func segments(_ tree: OrgTree, in range: Range<Int>, folded: [Range<Int>] = [], display: Display = Display()) -> [Segment] {
        let text = tree.text as NSString
        // A fold hides from the end of the opening line through the closing line, so the
        // marker sits on the opening line.
        let folds = folded.compactMap { r -> Range<Int>? in
            guard r.lowerBound > range.lowerBound, r.lowerBound <= range.upperBound else { return nil }
            let end = r.upperBound > r.lowerBound && r.upperBound <= text.length && text.character(at: r.upperBound - 1) == 10 ? r.upperBound - 1 : r.upperBound
            return (r.lowerBound - 1)..<min(end, range.upperBound)
        }
        // Styled only where shown: a folded drawer can hold most of a section.
        var visible: [Range<Int>] = []
        var from = range.lowerBound
        for fold in folds.sorted(by: { $0.lowerBound < $1.lowerBound }) where fold.upperBound > from {
            if fold.lowerBound > from { visible.append(from..<fold.lowerBound) }
            from = fold.upperBound
        }
        if from < range.upperBound || visible.isEmpty { visible.append(from..<max(from, range.upperBound)) }
        let runs = visible.flatMap { Presentation.styles(tree, in: $0, highlighter: display.highlighter) }
        var hidden = runs.filter { !display.showMarkup && Presentation.hidesWithMarkup($0.role, options: display.options) }.map(\.range) + folds
        // `org-pretty-entities`: an entity's last character shows its character, the rest hidden.
        var replaced: [Int: String] = [:]
        var scripts: [(range: Range<Int>, superscript: Bool)] = []
        if !display.showMarkup, display.options.prettyEntities {
            let blocks = Presentation.shadedBlocks(tree)
            let exclusions = runs.filter { Presentation.excludesScripts($0.role) }.map(\.range)
            let pretty = visible.flatMap { part in
                Presentation.prettyRuns(
                    text, in: part, revealedLine: nil, inBlock: { offset in blocks.contains { $0.contains(offset) } },
                    scriptExclusions: exclusions, subSuperscriptsNeedBraces: display.options.subSuperscriptsNeedBraces
                )
            }
            for (lineStart, run) in pretty {
                switch run {
                case .entity(let r, let shown):
                    let last = lineStart + r.upperBound - 1
                    hidden.append((lineStart + r.lowerBound)..<last)
                    replaced[last] = shown
                case .script(let markers, let body, let superscript):
                    hidden += markers.map { (lineStart + $0.lowerBound)..<(lineStart + $0.upperBound) }
                    scripts.append(((lineStart + body.lowerBound)..<(lineStart + body.upperBound), superscript))
                }
            }
        }
        var bounds: Set<Int> = [range.lowerBound, range.upperBound]
        let replacedRanges = replaced.keys.map { $0..<($0 + 1) }
        for r in runs.map(\.range) + hidden + replacedRanges + scripts.map(\.range) {
            bounds.insert(max(range.lowerBound, min(range.upperBound, r.lowerBound)))
            bounds.insert(max(range.lowerBound, min(range.upperBound, r.upperBound)))
        }
        let points = bounds.sorted()
        var segments: [Segment] = []
        func append(_ segment: Segment) {
            if var last = segments.last, last.roles == segment.roles, last.link == segment.link, last.superscript == segment.superscript, last.unfolds == segment.unfolds,
               last.offset + (last.text as NSString).length == segment.offset {
                last.text += segment.text
                segments[segments.count - 1] = last
            } else {
                segments.append(segment)
            }
        }
        // What covers each interval between consecutive points, marked range by range rather
        // than tested interval by interval, which grows with the square of a long section.
        let intervals = max(points.count - 1, 0)
        var position: [Int: Int] = [:]
        for (k, point) in points.enumerated() { position[point] = k }
        func covered(_ r: Range<Int>) -> Range<Int> {
            let lo = position[max(range.lowerBound, min(range.upperBound, r.lowerBound))]!
            let hi = position[max(range.lowerBound, min(range.upperBound, r.upperBound))]!
            return lo..<max(lo, hi)
        }
        var rolesAt = [Set<StyleRole>](repeating: [], count: intervals)
        for run in runs { for k in covered(run.range) { rolesAt[k].insert(run.role) } }
        var hiddenAt = [Bool](repeating: false, count: intervals)
        for r in hidden { for k in covered(r) { hiddenAt[k] = true } }
        var scriptAt = [Bool?](repeating: nil, count: intervals)
        for script in scripts { for k in covered(script.range) where scriptAt[k] == nil { scriptAt[k] = script.superscript } }
        let foldStarts = Set(folds.map(\.lowerBound))
        // A fold's opening line opens it too, a wider target than its `…`.
        let openings = folds.map { (line: text.lineRange(for: NSRange(location: $0.lowerBound, length: 0)).location..<$0.lowerBound, start: $0.lowerBound + 1) }
        for (k, (a, b)) in zip(points, points.dropFirst()).enumerated() {
            if foldStarts.contains(a) {
                segments.append(Segment(text: "…", roles: [.metadata], link: nil, offset: a, unfolds: a + 1))
            }
            if hiddenAt[k] { continue }
            let roles = rolesAt[k]
            let link = roles.contains(.link) ? Links.link(at: a, text: tree.text, tree: tree)?.link : nil
            let superscript = scriptAt[k]
            let shown = replaced[a] ?? text.substring(with: NSRange(location: a, length: b - a))
            let unfolds = openings.first { $0.line.contains(a) }?.start
            let segment = Segment(text: shown, roles: roles, link: link, offset: a, superscript: superscript, unfolds: unfolds)
            if replaced[a] != nil { segments.append(segment) } else { append(segment) }
        }
        return segments
    }
}
