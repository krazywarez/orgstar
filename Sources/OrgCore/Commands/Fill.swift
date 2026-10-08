import Foundation

// M-q: `org-fill-paragraph` (Org 9.8.7) over Emacs's `fill-region-as-paragraph` (fill.el), for
// paragraphs, comments and comment blocks, with `sentence-end-double-space` nil,
// `colon-double-space` nil, `left-margin` 0 and left justification.

extension EmacsBuffer {
    /// `org-element-paragraph-separate`, which org uses as `paragraph-start`.
    var paragraphStartPattern: String {
        let letters = options.listAllowAlphabetical ? "|[A-Za-z]" : ""
        return "(?:\\*+ |\\[fn:[-_\\w]+\\]|%%\\(|[ \\t]*(?:$|\\||\\+(?:-+\\+)+[ \\t]*$|#(?: |$|\\+(?:BEGIN_\\S+|\\S+(?:\\[.*\\])?:[ \\t]*))|:(?: |$|[-_\\w]+:[ \\t]*$)|-{5,}[ \\t]*$|\\\\begin\\{([A-Za-z0-9*]+)\\}|(?:[-+*]|(?:[0-9]+\(letters))[.)])(?:[ \\t]|$)))"
    }

    static let adaptiveFillPattern = "[-–!|#%;>*·•‣⁃◦ \\t]*"
    static let sentenceEndPattern = "([.?!…‽][\\]\"'”’)}»›]*($|[\\t \\u00A0])|[。．？！]+)[ \\u00A0\\t\\n]*"

    /// An element as `org-element-at-point` sees it, with offsets in the buffer.
    struct Element {
        let kind: SyntaxKind
        let range: Range<Int>
        /// The enclosing element, for paragraphs in items.
        let parentKind: SyntaxKind?
        let parentStart: Int?
        /// For blocks: the word after `#+begin_`, lowercased.
        let blockType: String?
        /// For plain lists: the first item's start.
        let firstItem: Int?
    }

    static let elementKinds: Set<SyntaxKind> = [.paragraph, .comment, .block, .table, .tableRow, .item, .plainList, .heading,
                                                .keyword, .fixedWidth, .drawer, .propertyDrawer, .planning, .dynamicBlock,
                                                .footnoteDefinition, .horizontalRule, .clock, .nodeProperty]

    /// The innermost element (not object) holding `offset`, as `org-element-at-point`. Greater
    /// blocks (quote, center, special) are parsed into their elements.
    func element(at offset: Int) -> Element? {
        // Elements never cross a heading, so the section around `offset` is enough to parse.
        let lineBegin = lineStart(offset)
        let from = headingLevel(atLine: lineBegin) != nil ? lineBegin : (previousHeadingStart(before: lineBegin) ?? 0)
        let to = nextHeadingStart(after: lineBegin) ?? length
        return element(at: offset, in: substring(from, to), base: from)
    }

    private func element(at offset: Int, in text: String, base: Int) -> Element? {
        let tree = OrgParser.parse(text, defaults: settings)
        let local = offset - base
        var node = tree.root
        var found: SyntaxNode?
        while true {
            let child = node.child(containing: local) ?? (local == node.range.upperBound ? node.children.last : nil)
            guard let child, Self.elementKinds.contains(child.kind) || child.kind == .section || child.kind == .zerothSection else { break }
            if Self.elementKinds.contains(child.kind) { found = child }
            if [.heading, .paragraph, .comment, .tableRow, .block].contains(child.kind) { break }
            node = child
        }
        guard let found else { return nil }
        let range = (found.range.lowerBound + base)..<(found.range.upperBound + base)
        var blockType: String?
        if found.kind == .block {
            let first = found.text.prefix { $0 != "\n" }.lowercased()
            blockType = first.firstMatch(of: /#\+begin_(\S+)/).map { String($0.1) }
            if let type = blockType, !["src", "example", "export", "comment", "verse"].contains(type) {
                let contentsStart = lineEnd(range.lowerBound) + 1
                let closing = saveExcursion { () -> Int in
                    point = range.upperBound
                    skipBackward(Self.whitespace)
                    return lineStart(point)
                }
                if offset >= contentsStart, offset < closing, contentsStart < closing {
                    return element(at: offset, in: substring(contentsStart, closing), base: contentsStart)
                }
            }
        }
        let parent = found.parent.flatMap { Self.elementKinds.contains($0.kind) ? $0 : nil }
        return Element(
            kind: found.kind, range: range, parentKind: parent?.kind, parentStart: parent.map { $0.range.lowerBound + base },
            blockType: blockType, firstItem: found.children.first { $0.kind == .item }.map { $0.range.lowerBound + base }
        )
    }

    /// Where an element's contents end: after its last non-blank line.
    func contentsEnd(_ node: Element) -> Int {
        saveExcursion {
            point = node.range.upperBound
            skipBackward(Self.whitespace)
            return min(lineEnd(point) + 1, length)
        }
    }

    /// `org-list-item-body-column`.
    func itemBodyColumn(_ item: Int) -> Int {
        saveExcursion {
            point = item
            let match = looking("[ \\t]*(\\S+)", setsMatch: false)!
            point = match[1]!.upperBound
            return currentColumn + 1
        }
    }

    /// `org-adaptive-fill-function` at point's line.
    func orgAdaptiveFillPrefix() -> String? {
        saveExcursion {
            guard !atHeading else { return nil }
            let lineBegin = lineStart(point)
            guard let element = element(at: lineBegin) else { return nil }
            switch element.kind {
            case .comment:
                let indent = substring(lineBegin, lineBegin + (looking("[ \\t]*", setsMatch: false).map { $0[0]!.count } ?? 0))
                return indent + "# "
            case .item, .plainList:
                let item = element.kind == .item ? element.range.lowerBound : (element.firstItem ?? element.range.lowerBound)
                return String(repeating: " ", count: itemBodyColumn(item))
            case .block where element.blockType == "comment":
                let begin = lineEnd(element.range.lowerBound) + 1
                let end = saveExcursion { () -> Int in
                    point = element.range.upperBound
                    skipBackward(Self.whitespace)
                    return lineStart(point)
                }
                guard lineBegin >= begin, lineBegin < end else { return nil }
                point = lineBegin
                return looking("[ \\t]+", setsMatch: false).map { substring($0[0]!.lowerBound, $0[0]!.upperBound) } ?? ""
            case .paragraph:
                point = lineBegin
                if element.parentKind == .item, let parent = element.parentStart {
                    return String(repeating: " ", count: itemBodyColumn(parent))
                }
                if let prefix = contextPrefix(from: postAffiliated(element), to: element.range.upperBound, paragraphOnly: true) {
                    return prefix
                }
                return looking("[ \\t]+", setsMatch: false).map { substring($0[0]!.lowerBound, $0[0]!.upperBound) } ?? ""
            default:
                return nil
            }
        }
    }

    /// Start of an element after its affiliated keywords.
    func postAffiliated(_ node: Element) -> Int {
        saveExcursion {
            point = node.range.lowerBound
            while looking("[ \\t]*#\\+(?:CAPTION|DATA|HEADERS?|LABEL|NAME|PLOT|RESNAME|RESULTS?|SOURCE|SRCNAME|TBLNAME|ATTR_[-_\\w]+)(?:\\[.*\\])?:", setsMatch: false) != nil {
                if forwardLine(1) != 0 { break }
            }
            return point
        }
    }

    /// `fill-match-adaptive-prefix`, with org's function or, in paragraphs, the regexp after
    /// any markup at the line start.
    func matchAdaptivePrefix(paragraphOnly: Bool) -> String? {
        let prefix: String?
        if paragraphOnly {
            let start = point
            prefix = saveExcursion {
                skipLineStartMarkup()
                return looking(Self.adaptiveFillPattern, setsMatch: false).map { substring($0[0]!.lowerBound, $0[0]!.upperBound) }
            }
            point = start
        } else {
            prefix = orgAdaptiveFillPrefix() ?? looking(Self.adaptiveFillPattern, setsMatch: false).map { substring($0[0]!.lowerBound, $0[0]!.upperBound) }
        }
        guard let prefix else { return nil }
        return (prefix as NSString).length >= options.fillColumn ? nil : prefix
    }

    /// Moves past the opening markup of an object that starts at point, as
    /// `org-adaptive-fill-paragraph-function` does.
    private func skipLineStartMarkup() {
        let line = substring(point, lineEnd(point)) + "\n"
        let tree = OrgParser.parse(line, defaults: settings)
        var node: SyntaxNode? = tree.root
        while let current = node, let child = current.child(containing: 0), child.range.lowerBound == 0 {
            if [.bold, .italic, .underline, .strikeThrough].contains(child.kind) {
                point += 1
                return
            }
            if child.kind == .link, let description = child.firstChild(.linkDescription) {
                point += description.range.lowerBound
                return
            }
            node = child
        }
    }

    /// `fill-context-prefix`.
    func contextPrefix(from: Int, to: Int, paragraphOnly: Bool = false) -> String? {
        saveExcursion {
            point = from
            if eolp { forwardLine(1) }
            point = lineStart(point)
            var first = matchAdaptivePrefix(paragraphOnly: paragraphOnly)
            forwardLine(1)
            if point < to {
                point = lineStart(point)
                let second: String? = looking(paragraphStartPattern, setsMatch: false) != nil ? nil : matchAdaptivePrefix(paragraphOnly: paragraphOnly)
                if let second {
                    if first == nil { first = "" }
                    var pattern = "^"
                    var rest = Substring(second)
                    while let match = rest.firstMatch(of: /^[ \t]*([^ \t]+)/) {
                        pattern += ".*" + NSRegularExpression.escapedPattern(for: String(match.1))
                        rest = rest[match.range.upperBound...]
                    }
                    if first!.range(of: pattern, options: .regularExpression) != nil { return second }
                    let common = zip(first!, second).prefix { $0 == $1 }.count
                    return common == 0 ? nil : String(first!.prefix(common))
                }
            }
            guard let firstPrefix = first else { return nil }
            let keep = firstPrefix.allSatisfy({ $0 == " " || $0 == "\t" }) || firstPrefix.range(of: "^\\s*#( |$)", options: .regularExpression) != nil
            let result = keep ? firstPrefix : String(repeating: " ", count: displayWidth(firstPrefix))
            let probe = result + "a"
            let regex = Self.regex(paragraphStartPattern, caseInsensitive: false)
            if let match = regex.firstMatch(in: probe, options: [.anchored], range: NSRange(location: 0, length: (probe as NSString).length)), match.range.location == 0 {
                return nil
            }
            return result
        }
    }

    /// `fill-nobreak-p` with org's predicates.
    func fillNoBreak() -> Bool {
        if bolp { return false }
        let startsParagraph = saveExcursion { () -> Bool in
            skipForward(Self.blanks)
            return !eolp && looking(paragraphStartPattern, setsMatch: false) != nil
        }
        if startsParagraph { return true }
        let lineBreak = saveExcursion { () -> Bool in
            skipBackward(Self.blanks)
            skipBackward([92])
            return looking("\\\\\\\\($|[^\\\\])", setsMatch: false) != nil
        }
        if lineBreak { return true }
        if looking("[ \\t]*\\{\\{\\{n(?:\\([^\\n)]*\\))?\\}\\}\\}[.)](?:$| )", setsMatch: false) != nil { return true }
        let saved = lastMatch
        defer { lastMatch = saved }
        if atTimestamp() != nil, looking("[\\[<](" + Self.timestampCore + ")[^\\]>\\n]*[\\]>]", setsMatch: false) == nil { return true }
        return false
    }

    /// `fill-move-to-break-point` for text without CJK characters.
    func moveToBreakPoint(_ lineBegin: Int) {
        if lineBegin > point { point = lineBegin }
        while true {
            guard let match = searchBackward("[ \\t]", bound: lineBegin, caseInsensitive: false) else {
                point = lineBegin
                break
            }
            point = match[0]!.lowerBound + 1
            if fillNoBreak() {
                skipBackward(Self.blanks, bound: lineBegin)
            } else {
                break
            }
        }
        skipBackward(Self.blanks)
        if lineBegin >= point {
            let end = lineEnd(point)
            var first = true
            point = lineBegin
            while point < end, first || fillNoBreak() {
                skipForward(Self.blanks)
                while point < length, let c = character(at: point), c != 32, c != 10, c != 9 { point += 1 }
                first = false
            }
        }
    }

    /// `skip-chars-backward` stopping at `bound`.
    func skipBackward(_ set: Set<unichar>, bound: Int) {
        while point > bound, let c = character(at: point - 1), set.contains(c) { point -= 1 }
    }

    /// `canonically-space-region` with single spaces after sentences.
    func canonicallySpace(_ begin: Int, _ endOffset: Int) {
        saveExcursion {
            let end = marker(endOffset, advances: true)
            defer { release(end) }
            for offset in begin..<end.position where character(at: offset) == 9 { replace(offset..<(offset + 1), with: " ") }
            point = begin
            let pattern = "(" + Self.sentenceEndPattern + ") *|  +"
            while point < end.position, let match = searchForward(pattern, bound: end.position, caseInsensitive: false) {
                let matchEnd = match[0]!.upperBound
                let start: Int
                if let sentence = match[1], matchEnd > sentence.upperBound {
                    start = sentence.upperBound
                } else if match[1] != nil {
                    let lastNonSpace = saveExcursion { () -> Int in point = matchEnd; skipBackward([32]); return point }
                    start = min(matchEnd, lastNonSpace + 1)
                } else {
                    let before = saveExcursion { () -> unichar? in
                        point = match[0]!.lowerBound
                        skipBackward(Set(" ]})\"'".utf16))
                        return character(at: point - 1)
                    }
                    start = match[0]!.lowerBound + (before == 10 ? 0 : 1)
                }
                if start < matchEnd { deleteRegion(start, matchEnd) }
            }
        }
    }

    /// `fill-region-as-paragraph` with left justification and adaptive fill. With `nosqueeze`,
    /// spaces between words and at the end stay.
    func fillRegionAsParagraph(_ fromOffset: Int, _ toOffset: Int, prefix fixedPrefix: String? = nil, nosqueeze: Bool = false) {
        point = min(fromOffset, toOffset)
        let to = max(fromOffset, toOffset)
        skipForward(Self.whitespace)
        let fromPlusIndent = point
        point = lineStart(point)
        var from = max(point, fromOffset)
        point = to
        var oneLeft = false
        while point > from, character(at: point - 1) == 10 {
            if oneLeft {
                deleteRegion(point - 1, point)
            } else {
                point -= 1
                oneLeft = true
            }
        }
        let toMarker = marker(point, advances: true)
        defer { release(toMarker) }
        point = fromPlusIndent
        guard toMarker.position > point else { return }
        var prefix = fixedPrefix
        if prefix == nil || prefix == "" { prefix = contextPrefix(from: from, to: toMarker.position) }
        point = lineStart(from)
        // `fill-delete-prefix`.
        let prefixPattern: String
        if let prefix, !prefix.allSatisfy({ $0 == " " || $0 == "\t" }) {
            prefixPattern = "[ \\t]*(" + NSRegularExpression.escapedPattern(for: prefix).replacingOccurrences(of: "[ \\t]+", with: "[ \\t]*", options: .regularExpression) + ")?[ \\t]*"
        } else {
            prefixPattern = "[ \\t]*"
        }
        point = from
        forwardLine(1)
        while point < toMarker.position {
            if let match = looking(prefixPattern, setsMatch: false) { deleteRegion(point, match[0]!.upperBound) }
            if forwardLine(1) != 0 { break }
        }
        point = from
        if let match = looking(prefixPattern, setsMatch: false) { point = match[0]!.upperBound }
        from = point
        // `fill-delete-newlines`.
        var at = from
        while at < toMarker.position {
            if character(at: at) == 10 { replace(at..<(at + 1), with: " ") }
            at += 1
        }
        if !nosqueeze {
            point = from
            skipForward(Self.blanks)
            canonicallySpace(point, toMarker.position)
            point = toMarker.position
            let end = point
            skipBackward(Self.blanks)
            if point < end { deleteRegion(point, end) }
        }
        point = from
        while point < toMarker.position {
            let lineBegin = point
            moveToColumn(options.fillColumn)
            var breaks = false
            if point < toMarker.position, lineBegin < toMarker.position {
                if currentColumn <= options.fillColumn { point += 1 }
                moveToBreakPoint(lineBegin)
                skipForward(Self.blanks)
                breaks = point < toMarker.position
            }
            guard breaks else {
                point = toMarker.position
                break
            }
            // `fill-newline`.
            skipBackward(Self.blanks)
            insert("\n")
            indentLineTo(0)
            if let prefix, !prefix.isEmpty { insertBeforeMarkers(prefix) }
        }
        point = toMarker.position
        if !eobp { point += 1 }
    }

    /// `org-fill-paragraph` without a region or justification.
    func fillParagraph() {
        saveExcursion {
            if lookingAt("^[ \\t]*$") != nil || saveExcursion({ beginningOfLine(); return lookingAt("[ \\t]*$") != nil }) {
                skipForward(Self.whitespace)
            }
            let eol = lineEnd(point)
            guard let element = element(at: eol) else { return }
            switch element.kind {
            case .paragraph:
                let begin = paragraphContentsBegin(element)
                var end = contentsEnd(element)
                guard lineEnd(point) >= begin else { return }
                var cuts = [begin]
                saveExcursion {
                    point = begin
                    while let match = searchForward("\\\\\\\\[ \\t]*\\n", bound: end, caseInsensitive: false) {
                        cuts.insert(match[0]!.upperBound, at: 0)
                    }
                }
                for cut in cuts where cut != end {
                    fillRegionAsParagraph(cut, end)
                    end = cut
                }
            case .comment:
                let begin = postAffiliated(element)
                let elementEnd = element.range.upperBound
                guard point >= begin, point <= elementEnd else { return }
                let from = saveExcursion { () -> Int in
                    endOfLine()
                    if searchBackward("^[ \\t]*#[ \\t]*$", bound: begin, caseInsensitive: false) != nil {
                        forwardLine(1)
                        return point
                    }
                    return begin
                }
                let to = saveExcursion { () -> Int in
                    endOfLine()
                    if searchForward("^[ \\t]*#[ \\t]*$", bound: elementEnd, caseInsensitive: false) != nil {
                        return lineStart(point) - 1
                    }
                    point = elementEnd
                    skipBackward(Self.whitespace)
                    return lineEnd(point)
                }
                guard to > from else { return }
                let prefix = saveExcursion { () -> String in
                    beginningOfLine()
                    let comment = looking("[ \\t]*#", setsMatch: false)!
                    point = comment[0]!.upperBound
                    let marker = substring(comment[0]!.lowerBound, comment[0]!.upperBound)
                    if let rest = looking(Self.adaptiveFillPattern, setsMatch: false) {
                        return marker + substring(rest[0]!.lowerBound, rest[0]!.upperBound)
                    }
                    return marker + " "
                }
                saveExcursion { fillRegionAsParagraph(from, to, prefix: prefix) }
            case .block where element.blockType == "comment":
                let begin = saveExcursion { () -> Int in
                    point = element.range.lowerBound
                    forwardLine(1)
                    return point
                }
                let end = saveExcursion { () -> Int in
                    point = element.range.upperBound
                    skipBackward(Self.whitespace)
                    return lineStart(point)
                }
                guard point >= begin, point <= end else { return }
                let from = saveExcursion { () -> Int in
                    endOfLine()
                    if searchBackward("^[ \\t]*$", bound: begin, caseInsensitive: false) == nil { point = begin }
                    return lineStart(point)
                }
                let to = saveExcursion { () -> Int in
                    beginningOfLine()
                    if searchForward("^[ \\t]*$", bound: end, caseInsensitive: false) == nil { point = end }
                    return lineStart(point)
                }
                fillRegionAsParagraph(from, to)
            default:
                return
            }
        }
    }

    /// `org-fill-paragraph` with an active region: from the region's end back to `start`, M-q at
    /// the end of each paragraph's text, moving back a paragraph at a time.
    func fillParagraphs(_ start: Int, _ end: Int) {
        saveExcursion {
            point = end
            skipBackward(Self.whitespace)
            while point > start {
                let before = point
                fillParagraph()
                point = paragraphBackwardStop()
                skipBackward(Self.whitespace)
                if point >= before { break }
            }
        }
    }

    /// Where `org--backward-paragraph-once` goes from the end of a line's text.
    private func paragraphBackwardStop() -> Int {
        guard let element = element(at: point) else { return lineStart(point) }
        switch element.kind {
        case .block where ["comment", "example", "export", "src", "verse"].contains(element.blockType ?? ""):
            // Between empty lines in the block.
            let contentsStart = lineEnd(element.range.lowerBound) + 1
            guard point > contentsStart else { return element.range.lowerBound }
            let contentsEnd = saveExcursion { () -> Int in
                point = element.range.upperBound
                skipBackward(Self.whitespace)
                return lineStart(point)
            }
            if point > contentsEnd { return contentsEnd }
            return saveExcursion {
                skipBackward(Self.whitespace, bound: element.range.lowerBound)
                return searchBackward("^[ \t]*\n", bound: contentsStart, caseInsensitive: false)?[0]!.lowerBound ?? contentsStart
            }
        case .block, .drawer, .propertyDrawer, .dynamicBlock:
            // On the closing line: inside, to the contents' end.
            return lineStart(point) > element.range.lowerBound ? lineStart(point) : element.range.lowerBound
        default:
            return lineStart(element.range.lowerBound)
        }
    }

    /// `fill-region` over whole lines: each paragraph's part of `from..<to` filled as a
    /// paragraph. Other elements stay.
    func fillRegion(_ from: Int, _ to: Int, nosqueeze: Bool = false) {
        var spans: [Range<Int>] = []
        var line = lineStart(from)
        while line < to, line < length {
            var next = lineEnd(line) + 1
            let blank = substring(line, lineEnd(line)).allSatisfy { $0 == " " || $0 == "\t" }
            if !blank, let element = element(at: lineEnd(line)) {
                if element.kind == .paragraph {
                    let span = max(paragraphContentsBegin(element), from)..<min(contentsEnd(element), to)
                    if !span.isEmpty { spans.append(span) }
                }
                next = max(next, lineStart(min(length, max(element.range.lowerBound, contentsEnd(element)))))
                if next <= line { next = lineEnd(line) + 1 }
            }
            line = next
        }
        // Back to front, so the spans before stay where they are.
        for span in spans.reversed() { fillRegionAsParagraph(span.lowerBound, span.upperBound, nosqueeze: nosqueeze) }
    }

    /// Where a paragraph's text starts: past affiliated keywords, and for a paragraph that
    /// opens an item, past the bullet.
    func paragraphContentsBegin(_ node: Element) -> Int {
        max(postAffiliated(node), node.range.lowerBound)
    }
}

/// M-q: `org-fill-paragraph`. With a selection, as with an active region, every paragraph
/// in it; `point` is where the caret is in it, and stays.
public struct FillParagraph: OrgCommand {
    public let point: Int?

    public init(point: Int? = nil) { self.point = point }
    public var id: String { "org.fill-paragraph" }
    public var title: String { "Fill Paragraph" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep {
        commitBuffer(context) { buffer in
            if let selection = context.selection.first, !selection.isEmpty {
                if let point { buffer.point = point }
                buffer.fillParagraphs(selection.lowerBound, selection.upperBound)
            } else {
                buffer.fillParagraph()
            }
        }
    }
}

/// evil's `gq` and `gw` operators: the paragraphs in `range`'s lines filled, as `fill-region`.
/// With `keep` (`gw`) the caret stays there; without (`gq`) it goes to the first non-blank
/// of the range's last line. Spaces are not squeezed, as Doom's `+evil--no-squeeze-on-fill-a`
/// has it.
public struct FillRegion: OrgCommand {
    public let range: Range<Int>
    public let keep: Int?

    public init(range: Range<Int>, keep: Int?) {
        self.range = range
        self.keep = keep
    }

    public var id: String { "org.fill-region" }
    public var title: String { "Fill Region" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep {
        commitBuffer(context) { buffer in
            let target = buffer.marker(keep ?? max(range.lowerBound, range.upperBound - 1))
            defer { buffer.release(target) }
            buffer.fillRegion(range.lowerBound, range.upperBound, nosqueeze: true)
            buffer.point = target.position
            if keep == nil {
                buffer.beginningOfLine()
                buffer.skipForward(EmacsBuffer.blanks)
            }
        }
    }
}
