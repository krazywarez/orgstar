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
    /// Code in a src block, by what the language's grammar says it is.
    case syntax(SyntaxCategory)
}

/// Kinds of code token, from tree-sitter highlight capture names.
public enum SyntaxCategory: String, Hashable, Sendable, CaseIterable {
    case keyword, string, comment, function, type, number, constant, variable, property, `operator`
    case punctuation, attribute, tag, escape, label

    /// The category for a capture name such as `keyword.control` or `string.special`.
    public init?(capture name: String) {
        let head = name.split(separator: ".").first.map(String.init) ?? name
        switch head {
        case "keyword", "conditional", "repeat", "include", "exception", "storageclass": self = .keyword
        case "string", "character": self = name.hasPrefix("string.escape") ? .escape : .string
        case "comment": self = .comment
        case "function", "method": self = .function
        case "type", "constructor", "module", "namespace": self = .type
        case "number", "float": self = .number
        case "constant", "boolean": self = .constant
        case "variable", "parameter": self = .variable
        case "property", "field": self = .property
        case "operator": self = .operator
        case "punctuation": self = .punctuation
        case "attribute", "annotation", "decorator": self = .attribute
        case "tag": self = .tag
        case "escape": self = .escape
        case "label": self = .label
        default: return nil
        }
    }
}

extension SyntaxCategory {
    /// The theme color for this kind of token; nil for those drawn in the text color.
    public var themeKey: String? {
        switch self {
        case .keyword: "syntax-keyword"
        case .string: "syntax-string"
        case .comment: "syntax-comment"
        case .function: "syntax-function"
        case .type: "syntax-type"
        case .number, .constant, .escape: "syntax-number"
        case .property, .attribute, .tag: "syntax-property"
        case .label: "syntax-label"
        case .variable, .operator, .punctuation: nil
        }
    }
}

/// Highlights source code; the apps supply tree-sitter's (OrgHighlight).
public protocol CodeHighlighter: Sendable {
    /// Categories for ranges of `code`, in UTF-16 offsets; later runs win over earlier ones.
    /// Empty for languages it doesn't know.
    func highlights(language: String, code: String) -> [(range: Range<Int>, category: SyntaxCategory)]
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
    public static func styles(_ tree: OrgTree, in range: Range<Int>, highlighter: (any CodeHighlighter)? = nil) -> [StyleRun] {
        var runs: [StyleRun] = []
        visit(tree.root, range, tree.settings, highlighter, &runs)
        return runs
    }

    /// Runs for the code inside a src block, from `highlighter`.
    static func sourceRuns(_ node: SyntaxNode, _ highlighter: any CodeHighlighter) -> [StyleRun] {
        let lines = node.tokens.filter { $0.kind == .text }
        guard lines.count >= 2, let first = lines.first, let last = lines.last,
              let match = first.text.firstMatch(of: /^[ \t]*#\+(?i:begin_src)[ \t]+(\S+)/) else { return [] }
        let language = String(match.1)
        let start = first.range.upperBound + 1
        let end = last.range.lowerBound
        guard end > start else { return [] }
        let utf16 = node.text.utf16
        let lower = utf16.index(utf16.startIndex, offsetBy: start - node.range.lowerBound)
        let upper = utf16.index(utf16.startIndex, offsetBy: end - node.range.lowerBound)
        let code = String(node.text[lower..<upper])
        return highlighter.highlights(language: language, code: code).map {
            StyleRun(range: ($0.range.lowerBound + start)..<($0.range.upperBound + start), role: .syntax($0.category))
        }
    }

    private static func visit(_ node: SyntaxNode, _ range: Range<Int>, _ settings: OrgSettings, _ highlighter: (any CodeHighlighter)?, _ runs: inout [StyleRun]) {
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
            if let highlighter { runs += sourceRuns(node, highlighter) }
        default:
            break
        }
        for child in node.children(overlapping: range) {
            visit(child, range, settings, highlighter, &runs)
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
        case .target, .radioTarget: .target
        case .macro: .macro
        case .latexFragment, .latexEnvironment: .latex
        case .inlineSourceBlock, .inlineBabelCall, .exportSnippet: .inlineSource
        case .citation: .link
        case .itemTag: .bold
        case .diarySexp: .timestamp
        case .comment: .comment
        case .keyword, .affiliatedKeyword: .keyword
        case .planning, .propertyDrawer, .drawer, .clock: .metadata
        case .block, .dynamicBlock, .fixedWidth: .block
        case .table, .tableEl: .table
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
        for section in node.children(overlapping: range) where section.kind == .section {
            guard let heading = section.firstChild(.heading) else { continue }
            let level = heading.tokens.first { $0.kind == .stars }?.text.count ?? 1
            runs.append(IndentRun(range: heading.range, firstLine: 0, wrapped: level + 1))
            let bodyEnd = section.firstChild(.section)?.range.lowerBound ?? section.range.upperBound
            if heading.range.upperBound < bodyEnd {
                runs.append(IndentRun(range: heading.range.upperBound..<bodyEnd, firstLine: level + 1, wrapped: level + 1))
            }
            collectIndents(section, range, &runs)
        }
    }

    /// Blocks and fixed-width areas, drawn on a shaded band the width of the view. Sorted.
    public static func shadedBlocks(_ tree: OrgTree) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        func walk(_ node: SyntaxNode) {
            for child in node.children {
                switch child.kind {
                case .block, .dynamicBlock, .fixedWidth:
                    // Without the blank lines org counts as part of the element.
                    let text = child.text
                    let trimmed = text.utf16.count - String(text.reversed().prefix { $0.isWhitespace }).utf16.count
                    ranges.append(child.range.lowerBound..<(child.range.lowerBound + trimmed))
                case .paragraph, .table, .heading, .planning, .propertyDrawer, .drawer, .keyword, .comment: continue
                default: walk(child)
                }
            }
        }
        walk(tree.root)
        return ranges
    }

    /// Ranges to hide. A heading in `folds` hides everything after its line to the end of its
    /// section; one in `bodyFolds` hides only its own body, up to its first child heading.
    /// Sorted, without nested duplicates.
    /// A drawer or block in `wrapperFolds` hides the lines after its opening line.
    public static func hiddenRanges(_ tree: OrgTree, folds: Set<Int>, bodyFolds: Set<Int> = [], wrapperFolds: Set<Int> = []) -> [Range<Int>] {
        hiddenRanges(tree, folds: folds, bodyFolds: bodyFolds, wrapperRanges: wrapperFolds.compactMap { Wrappers.starting(at: $0, in: tree)?.hidden })
    }

    /// The same, with the folded drawers' and blocks' hidden ranges already found.
    public static func hiddenRanges(_ tree: OrgTree, folds: Set<Int>, bodyFolds: Set<Int>, wrapperRanges: [Range<Int>]) -> [Range<Int>] {
        guard !folds.isEmpty || !bodyFolds.isEmpty || !wrapperRanges.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        if !folds.isEmpty || !bodyFolds.isEmpty { collectHidden(tree.root, folds, bodyFolds, &ranges) }
        guard !wrapperRanges.isEmpty else { return ranges }
        ranges += wrapperRanges
        ranges.sort { $0.lowerBound != $1.lowerBound ? $0.lowerBound < $1.lowerBound : $0.upperBound > $1.upperBound }
        var merged: [Range<Int>] = []
        for range in ranges where !(merged.last.map { $0.upperBound >= range.upperBound } ?? false) { merged.append(range) }
        return merged
    }

    private static func collectHidden(_ node: SyntaxNode, _ folds: Set<Int>, _ bodyFolds: Set<Int>, _ ranges: inout [Range<Int>]) {
        for section in node.children where section.kind == .section {
            guard let heading = section.firstChild(.heading) else { continue }
            let start = heading.range.lowerBound
            if folds.contains(start) {
                if heading.range.upperBound < section.range.upperBound {
                    ranges.append(heading.range.upperBound..<section.range.upperBound)
                }
                continue
            }
            if bodyFolds.contains(start) {
                let bodyEnd = section.firstChild(.section)?.range.lowerBound ?? section.range.upperBound
                if heading.range.upperBound < bodyEnd { ranges.append(heading.range.upperBound..<bodyEnd) }
            }
            collectHidden(section, folds, bodyFolds, &ranges)
        }
    }

    /// Start offset of the heading whose line contains `offset`.
    public static func heading(containing offset: Int, in tree: OrgTree) -> Int? {
        var node = tree.root
        while let child = node.child(containing: offset) {
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
