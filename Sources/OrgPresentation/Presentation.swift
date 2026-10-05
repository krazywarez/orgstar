import OrgCore

/// What a range of text is, for styling. Platform adapters map roles to attributes.
public enum StyleRole: Hashable, Sendable {
    /// A whole heading line.
    case heading(level: Int)
    /// All stars of a heading but the last, hidden as in `org-hide-leading-stars`.
    case leadingStars
    case todo, done, priority, tags
    case bold, italic, underline, strikeThrough, verbatim, code
    /// Emphasis markers.
    case markup
    case link
    /// Brackets and the target of a described link.
    case linkMarkup
    case timestamp, footnote, cookie, target, macro, latex, inlineSource
    case comment, keyword
    /// Planning lines, drawers, property drawers, clock lines.
    case metadata
    case block, blockDelimiter, table, rule
}

public struct StyleRun: Sendable, Equatable {
    public let range: Range<Int>
    public let role: StyleRole
}

/// org-indent: how many columns a run of whole lines starts in.
public struct IndentRun: Sendable, Equatable {
    public let range: Range<Int>
    public let firstLine: Int
    /// Continuation lines of a wrapped paragraph.
    public let wrapped: Int
}

public enum Presentation {
    /// Style runs for nodes and tokens overlapping `range`, outer before inner, so applying
    /// them in order lets inner roles win.
    public static func styles(_ tree: OrgTree, in range: Range<Int>) -> [StyleRun] {
        var runs: [StyleRun] = []
        visit(tree.root, range, tree.settings, &runs)
        return runs
    }

    private static func visit(_ node: SyntaxNode, _ range: Range<Int>, _ settings: OrgSettings, _ runs: inout [StyleRun]) {
        if let role = role(of: node) { runs.append(StyleRun(range: node.range, role: role)) }
        switch node.kind {
        case .heading:
            for token in node.tokens {
                switch token.kind {
                case .stars where token.range.count > 1:
                    runs.append(StyleRun(range: token.range.lowerBound..<(token.range.upperBound - 1), role: .leadingStars))
                case .todoKeyword:
                    runs.append(StyleRun(range: token.range, role: settings.isDone(token.text) ? .done : .todo))
                case .priority:
                    runs.append(StyleRun(range: token.range, role: .priority))
                case .tags:
                    runs.append(StyleRun(range: token.range, role: .tags))
                default:
                    break
                }
            }
        case .link:
            let described = node.children.contains { $0.kind == .linkDescription }
            for token in node.tokens where token.kind == .marker || (described && token.kind == .linkPath) {
                runs.append(StyleRun(range: token.range, role: .linkMarkup))
            }
        case .bold, .italic, .underline, .strikeThrough, .verbatim, .code:
            for token in node.tokens where token.kind == .marker {
                runs.append(StyleRun(range: token.range, role: .markup))
            }
        case .block, .dynamicBlock:
            let lines = node.tokens.filter { $0.kind == .text }
            for token in [lines.first, lines.count > 1 ? lines.last : nil].compactMap({ $0 }) {
                runs.append(StyleRun(range: token.range, role: .blockDelimiter))
            }
        default:
            break
        }
        for child in node.children where child.range.overlaps(range) {
            visit(child, range, settings, &runs)
        }
    }

    static func role(of node: SyntaxNode) -> StyleRole? {
        switch node.kind {
        case .heading: .heading(level: node.tokens.first { $0.kind == .stars }?.text.count ?? 1)
        case .bold: .bold
        case .italic: .italic
        case .underline: .underline
        case .strikeThrough: .strikeThrough
        case .verbatim: .verbatim
        case .code: .code
        case .link: .link
        case .timestamp: .timestamp
        case .footnoteReference, .footnoteDefinition: .footnote
        case .statisticsCookie: .cookie
        case .target: .target
        case .macro: .macro
        case .latexFragment: .latex
        case .inlineSourceBlock: .inlineSource
        case .comment: .comment
        case .keyword, .affiliatedKeyword: .keyword
        case .planning, .propertyDrawer, .drawer, .clock: .metadata
        case .block, .dynamicBlock, .fixedWidth: .block
        case .table: .table
        case .horizontalRule: .rule
        default: nil
        }
    }

    /// Heading lines start at column 0, with wrapped title lines under the title; a section's
    /// own body starts one column past its stars.
    public static func indents(_ tree: OrgTree, in range: Range<Int>) -> [IndentRun] {
        var runs: [IndentRun] = []
        collectIndents(tree.root, range, &runs)
        return runs
    }

    private static func collectIndents(_ node: SyntaxNode, _ range: Range<Int>, _ runs: inout [IndentRun]) {
        for section in node.children where section.kind == .section && section.range.overlaps(range) {
            let children = section.children
            guard let heading = children.first(where: { $0.kind == .heading }) else { continue }
            let level = heading.tokens.first { $0.kind == .stars }?.text.count ?? 1
            runs.append(IndentRun(range: heading.range, firstLine: 0, wrapped: level + 1))
            let bodyEnd = children.first { $0.kind == .section }?.range.lowerBound ?? section.range.upperBound
            if heading.range.upperBound < bodyEnd {
                runs.append(IndentRun(range: heading.range.upperBound..<bodyEnd, firstLine: level + 1, wrapped: level + 1))
            }
            collectIndents(section, range, &runs)
        }
    }

    /// Ranges to hide for folded headings, given by their start offsets: from the end of the
    /// heading line to the end of its section. Sorted, without nested duplicates.
    public static func hiddenRanges(_ tree: OrgTree, folds: Set<Int>) -> [Range<Int>] {
        guard !folds.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        collectHidden(tree.root, folds, &ranges)
        return ranges
    }

    private static func collectHidden(_ node: SyntaxNode, _ folds: Set<Int>, _ ranges: inout [Range<Int>]) {
        for section in node.children where section.kind == .section {
            guard let heading = section.children.first(where: { $0.kind == .heading }) else { continue }
            if folds.contains(heading.range.lowerBound) {
                if heading.range.upperBound < section.range.upperBound {
                    ranges.append(heading.range.upperBound..<section.range.upperBound)
                }
            } else {
                collectHidden(section, folds, &ranges)
            }
        }
    }

    /// Start offset of the heading whose line contains `offset`.
    public static func heading(containing offset: Int, in tree: OrgTree) -> Int? {
        var node = tree.root
        while let child = node.children.first(where: { $0.range.contains(offset) }) {
            if child.kind == .heading { return child.range.lowerBound }
            guard child.kind == .section || child.kind == .zerothSection else { return nil }
            node = child
        }
        return nil
    }

    /// Start offsets of every heading, for folding everything.
    public static func headings(_ tree: OrgTree) -> [Int] {
        tree.root.descendants().filter { $0.kind == .heading }.map(\.range.lowerBound)
    }
}
