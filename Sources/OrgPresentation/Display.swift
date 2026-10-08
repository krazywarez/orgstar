import Foundation
import OrgCore

/// How a file shows when it opens, from the display settings and its `#+STARTUP` words.
public struct StartupDisplay: Sendable, Equatable {
    /// Headings, drawers and blocks folded.
    public var folds: FoldState
    /// The folded drawers and blocks.
    public var wrappers: [Wrapper]
    /// `org-indent-mode` (`indent`, `noindent`).
    public var indented: Bool
    /// `org-hide-leading-stars` (`hidestars`, `showstars`).
    public var hideStars: Bool
    /// `org-startup-with-inline-images` (`inlineimages`, `noinlineimages`).
    public var inlineImages: Bool
    /// `org-startup-align-all-tables` (`align`, `noalign`).
    public var alignTables: Bool
    /// `org-startup-truncated`.
    public var truncated: Bool
}

/// Org's display, shared by the Mac and iOS editors.
extension Presentation {
    public static func startupDisplay(_ tree: OrgTree, options: EditingOptions) -> StartupDisplay {
        let words = startupOptions(tree).map { $0.lowercased() }
        var folds = startupFoldState(tree) ?? FoldState()
        // VISIBILITY properties and archived trees, unless everything shows.
        if startupFoldState(tree) != nil, !words.contains("showeverything") {
            folds = applyVisibilityProperties(folds, in: tree)
        }
        let wrappers = startupWrappers(tree, hideDrawers: options.hideDrawerStartup, hideBlocks: options.hideBlockStartup)
        folds.wrapperFolds = Set(wrappers.map(\.start))
        return StartupDisplay(
            folds: folds, wrappers: wrappers,
            indented: words.contains("indent") ? true : words.contains("noindent") ? false : options.startupIndented,
            hideStars: words.contains("hidestars") ? true : words.contains("showstars") ? false : options.hideLeadingStars,
            inlineImages: InlineImages.startup(tree) ?? options.startupWithInlineImages,
            alignTables: words.contains("align") || (options.startupAlignAllTables && !words.contains("noalign")),
            truncated: options.startupTruncated
        )
    }

    /// Whether `role` hides while markup is hidden: link brackets and targets as with
    /// `org-link-descriptive`; emphasis markers only when Emacs hides them too.
    public static func hidesWithMarkup(_ role: StyleRole, options: EditingOptions) -> Bool {
        switch role {
        case .linkMarkup: true
        case .markup: options.hideEmphasisMarkers
        default: false
        }
    }

    /// Whether a style run is skipped: leading stars show as the heading's color unless the
    /// view is indented or hides them.
    public static func skipsLeadingStars(_ role: StyleRole, indented: Bool, hideStars: Bool) -> Bool {
        role == .leadingStars && !indented && !hideStars
    }

    /// One line's indentation under org-indent, in columns.
    public struct LineIndent: Sendable, Equatable {
        public let range: Range<Int>
        public let firstLine: Int
        public let wrapped: Int
    }

    /// org-indent's indentation for the lines in `range`: each run of `indents`, with body lines
    /// wrapping under their own text (past leading blanks, a list bullet and a checkbox) as
    /// adaptive-wrap does in Emacs.
    public static func lineIndents(_ tree: OrgTree, in range: Range<Int>) -> [LineIndent] {
        let text = tree.text as NSString
        var out: [LineIndent] = []
        for run in indents(tree, in: range) {
            let clipped = run.range.clamped(to: range)
            guard !clipped.isEmpty else { continue }
            guard run.firstLine == run.wrapped else {
                out.append(LineIndent(range: clipped, firstLine: run.firstLine, wrapped: run.wrapped))
                continue
            }
            var location = clipped.lowerBound
            while location < clipped.upperBound {
                let line = text.lineRange(for: NSRange(location: location, length: 0))
                let hanging = hangingColumns(text.substring(with: line))
                let lineRange = max(line.location, clipped.lowerBound)..<min(NSMaxRange(line), clipped.upperBound)
                out.append(LineIndent(range: lineRange, firstLine: run.firstLine, wrapped: run.wrapped + hanging))
                location = NSMaxRange(line)
            }
        }
        return out
    }

    /// Columns a wrapped continuation of `line` should start past the line's own start.
    public static func hangingColumns(_ line: String) -> Int {
        var columns = 0
        var rest = Substring(line)
        while let c = rest.first, c == " " || c == "\t" {
            columns = c == "\t" ? (columns / 8 + 1) * 8 : columns + 1
            rest = rest.dropFirst()
        }
        // A bullet (`-`, `+`, `*` when indented, `1.`, `1)`) and its space, then a checkbox.
        var bullet = 0
        if let first = rest.first, first == "-" || first == "+" || (first == "*" && columns > 0) {
            bullet = 1
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            if !digits.isEmpty, let separator = rest.dropFirst(digits.count).first, separator == "." || separator == ")" {
                bullet = digits.count + 1
            }
        }
        guard bullet > 0, rest.dropFirst(bullet).first == " " else { return columns }
        columns += bullet + 1
        let afterBullet = rest.dropFirst(bullet + 1)
        if afterBullet.count >= 4, afterBullet.first == "[", "X x-".contains(afterBullet.dropFirst().first!),
           afterBullet.dropFirst(2).first == "]", afterBullet.dropFirst(3).first == " " {
            columns += 4
        }
        return columns
    }

    /// `org-pretty-entities` for the lines in `range`, with each run's line start: not on the
    /// line starting at `revealedLine`, in comments or in blocks; sub/superscripts not in
    /// `scriptExclusions` (emphasis, links, keywords), as `org-raise-scripts` leaves them.
    public static func prettyRuns(
        _ text: NSString, in range: Range<Int>, revealedLine: Int?, inBlock: (Int) -> Bool,
        scriptExclusions: [Range<Int>], subSuperscriptsNeedBraces: Bool
    ) -> [(lineStart: Int, run: PrettyEntities.Run)] {
        var out: [(lineStart: Int, run: PrettyEntities.Run)] = []
        var location = range.lowerBound
        while location < range.upperBound {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            guard line.length > 0 else { break }
            location = NSMaxRange(line)
            if line.location == revealedLine || inBlock(line.location) { continue }
            let content = text.substring(with: line)
            if content.range(of: "^[ \\t]*#([ +]|$)", options: .regularExpression) != nil { continue }
            for run in PrettyEntities.runs(in: content, subSuperscriptsNeedBraces: subSuperscriptsNeedBraces) {
                if case .script(_, let body, _) = run {
                    let bodyStart = line.location + body.lowerBound
                    if body.isEmpty || scriptExclusions.contains(where: { $0.contains(bodyStart) }) { continue }
                }
                out.append((line.location, run))
            }
        }
        return out
    }

    /// Roles whose text keeps sub/superscript markers as written.
    public static func excludesScripts(_ role: StyleRole) -> Bool {
        switch role {
        case .bold, .italic, .underline, .strikeThrough, .verbatim, .code, .link, .linkMarkup, .keyword: true
        default: false
        }
    }
}
