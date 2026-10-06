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
    }

    /// `folded` are drawers' and blocks' hidden ranges (`Wrapper.hidden`).
    public static func segments(_ tree: OrgTree, in range: Range<Int>, folded: [Range<Int>] = []) -> [Segment] {
        let text = tree.text as NSString
        let runs = Presentation.styles(tree, in: range)
        // A fold hides from the end of the opening line through the closing line, so the
        // marker sits on the opening line.
        let folds = folded.compactMap { r -> Range<Int>? in
            guard r.lowerBound > range.lowerBound, r.lowerBound <= range.upperBound else { return nil }
            let end = r.upperBound > r.lowerBound && r.upperBound <= text.length && text.character(at: r.upperBound - 1) == 10 ? r.upperBound - 1 : r.upperBound
            return (r.lowerBound - 1)..<min(end, range.upperBound)
        }
        let hidden = runs.filter { $0.role == .linkMarkup }.map(\.range) + folds
        var bounds: Set<Int> = [range.lowerBound, range.upperBound]
        for r in runs.map(\.range) + hidden {
            bounds.insert(max(range.lowerBound, min(range.upperBound, r.lowerBound)))
            bounds.insert(max(range.lowerBound, min(range.upperBound, r.upperBound)))
        }
        let points = bounds.sorted()
        var segments: [Segment] = []
        func append(_ segment: Segment) {
            if var last = segments.last, last.roles == segment.roles, last.link == segment.link, last.offset + (last.text as NSString).length == segment.offset {
                last.text += segment.text
                segments[segments.count - 1] = last
            } else {
                segments.append(segment)
            }
        }
        for (a, b) in zip(points, points.dropFirst()) where a < b {
            if folds.contains(where: { $0.lowerBound == a }) {
                segments.append(Segment(text: "…", roles: [.metadata], link: nil, offset: a))
            }
            if hidden.contains(where: { $0.lowerBound <= a && b <= $0.upperBound }) { continue }
            let roles = Set(runs.filter { $0.range.lowerBound <= a && b <= $0.range.upperBound }.map(\.role))
            let link = roles.contains(.link) ? Links.link(at: a, text: tree.text, tree: tree)?.link : nil
            append(Segment(text: text.substring(with: NSRange(location: a, length: b - a)), roles: roles, link: link, offset: a))
        }
        return segments
    }
}
