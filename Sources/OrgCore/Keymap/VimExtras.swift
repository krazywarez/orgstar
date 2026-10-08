import Foundation

// Doom's evil beyond the basics: marks and the jump list, macros, `gv`, block visual state,
// evil-surround (`ys`, `cs`, `ds`, visual `S`), commenting (`gc`) and evil-org's text objects
// (`e` object, `E` element, `r` greater element, `R` subtree).

extension Vim {
    /// Marks from the editor, over the ones set in this engine.
    var currentMarks: [Character: Int] { marks.merging(contextMarks) { $1 } }

    /// Motions evil records in the jump list.
    static func isJump(_ keys: [KeyChord]) -> Bool {
        guard let key = keys.first, key.modifiers.isEmpty else { return false }
        if ["G", "%", "{", "}", "n", "N", "*", "#", "'", "`", "H", "M", "L"].contains(key.key) { return true }
        return key.key == "g" && keys.count > 1 && keys[1].key == "g"
    }

    /// Keys evil handles here before operators and motions, or nil.
    mutating func parseExtras(_ rest: ArraySlice<KeyChord>, _ buffer: inout Buffer, _ context: Context, register: Character?, count: Int?, keys: [KeyChord]) -> Parse? {
        guard let first = rest.first else { return .incomplete }
        let visual = mode == .visual || mode == .visualLine
        let n = count ?? 1
        let caret = context.caret
        let second = rest.dropFirst().first
        func needSecond() -> Parse? { second == nil ? .incomplete : nil }

        if first.modifiers == [.control] {
            switch first.key {
            case "o" where !visual: return .done([.jumpBack(n)])
            case "i" where !visual: return .done([.jumpForward(n)])
            case "v":
                if visual { lastVisual = (anchor, caret, mode) }
                mode = .visualBlock
                if !visual { anchor = caret }
                return .done(blockActions(buffer, caret))
            default: return nil
            }
        }
        guard first.modifiers.isEmpty else { return nil }

        if visual, first.key == "S" {
            if let wait = needSecond() { return wait }
            let range = visualRange(buffer, caret)
            lastVisual = (anchor, caret, mode)
            mode = .normal
            return .done(surround(range.range, with: second!, linewise: range.linewise, buffer, keys: []))
        }
        guard !visual else { return nil }

        switch first.key {
        case "m":
            if let wait = needSecond() { return wait }
            guard let name = second!.key.first, second!.key.count == 1, name.isLetter else { return .invalid }
            marks[name] = caret
            return .done([.setMark(name, caret)])
        case "q":
            if recording {
                recording = false
                return .done([.recordMacro(nil)])
            }
            if let wait = needSecond() { return wait }
            guard let name = second!.key.first, second!.key.count == 1, name.isLetter || name.isNumber else { return .invalid }
            recording = true
            return .done([.recordMacro(name)])
        case "@":
            if let wait = needSecond() { return wait }
            let name: Character
            if second!.key == "@" {
                guard let last = lastMacro else { return .done([.message("No previous macro")]) }
                name = last
            } else {
                guard let c = second!.key.first, second!.key.count == 1 else { return .invalid }
                name = c
            }
            lastMacro = name
            return .done([.playMacro(name, n)])
        case "g":
            if let wait = needSecond() { return wait }
            guard second!.key == "v", second!.modifiers.isEmpty else { return nil }
            guard let last = lastVisual else { return .done([]) }
            mode = last.mode
            anchor = min(last.anchor, buffer.length)
            let to = min(last.caret, buffer.length)
            return .done(mode == .visualBlock ? blockActions(buffer, to) : visualActions(buffer, to))
        case "y", "c", "d":
            guard second?.key == "s", second?.modifiers.isEmpty == true else { return nil }
            return surroundCommand(first.key, Array(rest.dropFirst(2)), &buffer, caret: caret, count: n, keys: keys)
        default:
            return nil
        }
    }

    // MARK: - Surround

    /// The delimiters evil-surround puts around text for `key`: an opening bracket adds a space
    /// inside, a closing one doesn't.
    static func delimiters(_ key: KeyChord) -> (open: String, close: String)? {
        let pairs: [String: (String, String)] = [
            "(": ("( ", " )"), ")": ("(", ")"), "b": ("(", ")"), "[": ("[ ", " ]"), "]": ("[", "]"), "r": ("[", "]"),
            "{": ("{ ", " }"), "}": ("{", "}"), "B": ("{", "}"), "<": ("< ", " >"), ">": ("<", ">"), "a": ("<", ">"), "SPC": (" ", " "),
        ]
        if let pair = pairs[key.key] { return pair }
        guard key.modifiers.isEmpty, key.key.count == 1 else { return nil }
        return (key.key, key.key)
    }

    /// `ys{motion}{char}`, `yss{char}`, `cs{old}{new}` and `ds{char}`.
    mutating func surroundCommand(_ op: String, _ after: [KeyChord], _ buffer: inout Buffer, caret: Int, count: Int, keys: [KeyChord]) -> Parse {
        switch op {
        case "y":
            guard let (_, count2, motionKeys) = Self.prefix(after), let motionFirst = motionKeys.first else { return .incomplete }
            let total = count * (count2 ?? 1)
            if motionFirst.key == "s", motionFirst.modifiers.isEmpty {
                guard motionKeys.count >= 2 else { return .incomplete }
                let line = buffer.lineStart(caret)
                let range = buffer.firstNonBlank(line)..<buffer.lineEnd(line)
                return .done(surround(range, with: motionKeys[motionKeys.startIndex + 1], linewise: false, buffer, keys: keys))
            }
            if motionFirst.key == "i" || motionFirst.key == "a", motionFirst.modifiers.isEmpty {
                guard motionKeys.count >= 3 else { return .incomplete }
                guard let object = textObject(motionFirst.key == "i", motionKeys[motionKeys.startIndex + 1], buffer, caret, count: total) else { return .invalid }
                return .done(surround(object.range, with: motionKeys[motionKeys.startIndex + 2], linewise: object.linewise, buffer, keys: keys))
            }
            var target = caret
            switch motion(Array(motionKeys), &buffer, &target, count: total, operatorPending: true) {
            case .incomplete: return .incomplete
            case .invalid: return .invalid
            case .moved(let to, let kind):
                // The surround character follows the motion's keys.
                let used = Self.motionLength(Array(motionKeys))
                guard motionKeys.count > used else { return .incomplete }
                let char = motionKeys[motionKeys.startIndex + used]
                var range: Range<Int>
                switch kind {
                case .linewise: range = buffer.lineStart(min(caret, to))..<buffer.lineEnd(max(caret, to))
                case .inclusive: range = min(caret, to)..<min(buffer.length, max(caret, to) + 1)
                case .exclusive: range = min(caret, to)..<max(caret, to)
                }
                // ysw leaves the space after the word outside.
                while range.upperBound > range.lowerBound, let c = buffer.char(range.upperBound - 1), Buffer.isBlank(c) { range = range.lowerBound..<(range.upperBound - 1) }
                return .done(surround(range, with: char, linewise: kind == .linewise, buffer, keys: keys))
            }
        case "d", "c":
            guard let target = after.first else { return .incomplete }
            if op == "c", after.count < 2 { return .incomplete }
            guard let found = surrounding(target, buffer, caret) else { return .invalid }
            var edits: [TextEdit]
            if op == "d" {
                edits = [TextEdit(range: found.close, replacement: ""), TextEdit(range: found.open, replacement: "")]
            } else {
                guard let (open, close) = Self.delimiters(after[after.startIndex + 1]) else { return .invalid }
                edits = [TextEdit(range: found.close, replacement: close), TextEdit(range: found.open, replacement: open)]
            }
            lastChange = (keys, nil)
            return .done([.edit(edits, caret: found.open.lowerBound)])
        default:
            return .invalid
        }
    }

    /// How many keys a motion takes: two for `f`, `t`, `'`, `` ` `` and `g`, otherwise one.
    static func motionLength(_ keys: [KeyChord]) -> Int {
        guard let first = keys.first, first.modifiers.isEmpty else { return 1 }
        return ["f", "F", "t", "T", "'", "`", "g"].contains(first.key) ? 2 : 1
    }

    /// Wraps `range` in the delimiters for `key`; linewise, on lines of their own.
    mutating func surround(_ range: Range<Int>, with key: KeyChord, linewise: Bool, _ buffer: Buffer, keys: [KeyChord]) -> [Action] {
        guard let (open, close) = Self.delimiters(key) else { return [] }
        var edits: [TextEdit]
        if linewise {
            let start = buffer.lineStart(range.lowerBound)
            let end = buffer.lineEnd(max(range.lowerBound, range.upperBound - 1))
            edits = [TextEdit(range: end..<end, replacement: "\n" + close.trimmingCharacters(in: .whitespaces)),
                     TextEdit(range: start..<start, replacement: open.trimmingCharacters(in: .whitespaces) + "\n")]
        } else {
            edits = [TextEdit(range: range.upperBound..<range.upperBound, replacement: close), TextEdit(range: range.lowerBound..<range.lowerBound, replacement: open)]
        }
        if !keys.isEmpty { lastChange = (keys, nil) }
        return [.edit(edits, caret: range.lowerBound)]
    }

    /// The delimiters around `caret` for `key`, as `ds` and `cs` find them; with an opening
    /// bracket, the blanks inside go too.
    func surrounding(_ key: KeyChord, _ buffer: Buffer, _ caret: Int) -> (open: Range<Int>, close: Range<Int>)? {
        let pairs: [String: (unichar, unichar)] = ["(": (40, 41), ")": (40, 41), "b": (40, 41), "[": (91, 93), "]": (91, 93), "r": (91, 93),
                                                    "{": (123, 125), "}": (123, 125), "B": (123, 125), "<": (60, 62), ">": (60, 62), "a": (60, 62)]
        let outer: Range<Int>
        if let (open, close) = pairs[key.key] {
            guard let r = buffer.bracketObject(caret, open: open, close: close, inner: false) else { return nil }
            outer = r
        } else if key.key.count == 1, let quote = key.key.utf16.first {
            guard let r = buffer.quoteObject(caret, quote: quote, inner: false) else { return nil }
            outer = r
            // `a"` takes blanks after the closing quote; the delimiter is the quote itself.
            var end = r.upperBound
            while end > r.lowerBound, buffer.char(end - 1) != quote { end -= 1 }
            return (r.lowerBound..<(r.lowerBound + 1), (end - 1)..<end)
        } else {
            return nil
        }
        var open = outer.lowerBound..<(outer.lowerBound + 1)
        var close = (outer.upperBound - 1)..<outer.upperBound
        if ["(", "[", "{", "<"].contains(key.key) {
            while open.upperBound < close.lowerBound, let c = buffer.char(open.upperBound), Buffer.isBlank(c) { open = open.lowerBound..<(open.upperBound + 1) }
            while close.lowerBound > open.upperBound, let c = buffer.char(close.lowerBound - 1), Buffer.isBlank(c) { close = (close.lowerBound - 1)..<close.upperBound }
        }
        return (open, close)
    }

    // MARK: - Commenting

    /// `comment-or-uncomment-region` in Org: `# ` at the shallowest indentation of the lines'
    /// text, blank lines left alone; when every line is a comment, the comments come off.
    static func toggleComments(_ buffer: Buffer, _ range: Range<Int>) -> [TextEdit] {
        var lines: [Int] = []
        var line = buffer.lineStart(range.lowerBound)
        let last = buffer.lineStart(max(range.lowerBound, range.upperBound - 1))
        while true {
            lines.append(line)
            let end = buffer.lineEnd(line)
            guard line < last, end < buffer.length else { break }
            line = end + 1
        }
        let content = lines.filter { buffer.firstNonBlankOrEnd($0) < buffer.lineEnd($0) }
        guard !content.isEmpty else { return [] }
        let commented = content.allSatisfy { start in
            let text = buffer.substring(buffer.firstNonBlankOrEnd(start)..<buffer.lineEnd(start))
            return text == "#" || text.hasPrefix("# ")
        }
        if commented {
            return content.reversed().map { start in
                let at = buffer.firstNonBlankOrEnd(start)
                let length = buffer.lineEnd(start) - at >= 2 && buffer.char(at + 1) == 32 ? 2 : 1
                return TextEdit(range: at..<(at + length), replacement: "")
            }
        }
        let column = content.map { buffer.firstNonBlankOrEnd($0) - $0 }.min() ?? 0
        return content.reversed().map { TextEdit(range: ($0 + column)..<($0 + column), replacement: "# ") }
    }

    // MARK: - Org text objects

    /// evil-org's text objects: `e` the object at point, `E` the element, `r` the greater element
    /// around it, `R` the subtree. `a` takes the blanks after; `i` the contents.
    /// An org-element: `end` takes the blanks after it, `contents` is nil for elements without any.
    struct OrgElement {
        var begin: Int
        var end: Int
        var contents: Range<Int>?
        var greater: Bool
        var block = false
        var node: SyntaxNode?
    }

    /// `j` and `k` are evil-org's `gj` and `gk` (`org-forward-element`, `org-backward-element`):
    /// an empty range where they go, nil where they can't.
    static func orgObject(_ key: String, inner: Bool, _ buffer: Buffer, _ position: Int) -> (range: Range<Int>, linewise: Bool)? {
        let tree = OrgParser.parse(buffer.ns as String)
        /// The point the element functions look at, and the nodes containing it.
        var c = position
        var chain: [SyntaxNode] = []
        func look(at p: Int) {
            c = p
            chain = []
            var node = tree.root
            while let child = node.child(containing: c) {
                chain.append(child)
                node = child
            }
        }
        look(at: position)
        /// The end of the line ending at or after `p`, without trailing blank lines.
        func trimmed(_ lower: Int, _ upper: Int) -> Int {
            var end = upper
            while end > lower, let ch = buffer.char(end - 1), ch == 10 || Buffer.isBlank(ch) { end -= 1 }
            if end > lower, buffer.char(end) == 10 { end += 1 }
            return max(lower, end)
        }
        /// The org-element for a node of ours; a `section` here is Org's headline.
        func element(_ n: SyntaxNode) -> OrgElement {
            let r = n.range
            var post = r.upperBound
            let limit = n.parent?.range.upperBound ?? buffer.length
            while post < limit {
                let lineEnd = buffer.lineEnd(post)
                guard (post..<lineEnd).allSatisfy({ buffer.char($0).map(Buffer.isBlank) ?? true }), lineEnd < buffer.length else { break }
                post = min(limit, lineEnd + 1)
            }
            switch n.kind {
            case .section:
                let body = min(r.upperBound, buffer.lineEnd(r.lowerBound) + 1)
                let contentsEnd = trimmed(body, r.upperBound)
                return OrgElement(begin: r.lowerBound, end: r.upperBound, contents: body < contentsEnd ? body..<contentsEnd : nil, greater: true, node: n)
            case .plainList, .table, .drawer, .propertyDrawer, .dynamicBlock, .footnoteDefinition, .inlineTask:
                return OrgElement(begin: r.lowerBound, end: post, contents: r.lowerBound..<trimmed(r.lowerBound, r.upperBound), greater: true, node: n)
            case .item:
                let first = n.children.first { ![.bullet, .checkbox, .itemTag].contains($0.kind) }?.range.lowerBound ?? r.upperBound
                return OrgElement(begin: r.lowerBound, end: post, contents: min(first, r.upperBound)..<trimmed(first, r.upperBound), greater: true, node: n)
            case .block:
                let name = buffer.substring(r.lowerBound..<buffer.lineEnd(r.lowerBound)).lowercased()
                let greater = !["src", "example", "export", "verse", "comment"].contains { name.hasPrefix("#+begin_\($0)") }
                return OrgElement(begin: r.lowerBound, end: post, contents: nil, greater: greater, block: true, node: n)
            case .latexEnvironment:
                return OrgElement(begin: r.lowerBound, end: post, contents: nil, greater: false, block: true, node: n)
            case .paragraph:
                return OrgElement(begin: r.lowerBound, end: post, contents: r.lowerBound..<trimmed(r.lowerBound, r.upperBound), greater: false, node: n)
            default:
                return OrgElement(begin: r.lowerBound, end: post, contents: nil, greater: false, node: n)
            }
        }
        /// Org's section: the text under a heading before its first child, or before the first heading.
        func section(_ n: SyntaxNode) -> OrgElement? {
            let begin = n.kind == .zerothSection ? n.range.lowerBound : min(n.range.upperBound, buffer.lineEnd(n.range.lowerBound) + 1)
            let end = n.children.first { $0.kind == .section && $0.range.lowerBound >= begin }?.range.lowerBound ?? n.range.upperBound
            guard begin < end else { return nil }
            return OrgElement(begin: begin, end: end, contents: begin..<trimmed(begin, end), greater: true)
        }
        func parent(_ e: OrgElement) -> OrgElement? {
            guard let n = e.node else {
                // A section's parent is its headline.
                return chain.last { $0.kind == .section && $0.range.lowerBound < e.begin }.map(element)
            }
            guard let up = n.parent else { return nil }
            switch up.kind {
            case .section where n.kind != .section: return section(up)
            case .zerothSection: return section(up)
            case .document: return nil
            default: return element(up)
            }
        }
        /// org-element-at-point.
        func atPoint() -> OrgElement? {
            let objects: Set<SyntaxKind> = [.title, .heading, .bold, .italic, .underline, .strikeThrough, .verbatim, .code, .link, .linkDescription,
                                            .timestamp, .footnoteReference, .statisticsCookie, .target, .radioTarget, .macro, .inlineSourceBlock,
                                            .latexFragment, .lineBreak, .superscript, .subscript, .entity, .tableCell, .nodeProperty,
                                            .citation, .citationReference, .exportSnippet, .inlineBabelCall, .itemTag]
            var elements = chain.filter { !objects.contains($0.kind) }
            if chain.contains(where: { $0.kind == .heading }), let i = elements.lastIndex(where: { $0.kind == .section }) {
                elements = Array(elements[...i])
            }
            guard var n = elements.last else { return nil }
            if [.section, .zerothSection, .plainList, .item].contains(n.kind), !chain.contains(where: { $0.kind == .heading }) {
                // On a blank line: the element before it, whose post-blank it is.
                if let before = n.children.last(where: { $0.range.upperBound <= c && $0.kind != .heading && $0.kind != .bullet }), !n.children.contains(where: { $0.range.contains(c) }) {
                    n = before
                } else if n.kind == .zerothSection || n.kind == .section {
                    return section(n)
                }
            }
            if let up = n.parent, up.range.lowerBound == n.range.lowerBound, (n.kind == .item && up.kind == .plainList) || (n.kind == .tableRow && up.kind == .table) {
                n = up
            }
            return element(n)
        }
        func innerRange(_ e: OrgElement) -> Range<Int> {
            if e.block {
                let first = min(e.end, buffer.lineEnd(e.begin) + 1)
                let closing = buffer.lineStart(max(e.begin, trimmed(e.begin, e.end) - 1))
                return min(first, closing)..<closing
            }
            if let contents = e.contents { return contents }
            return e.begin..<max(e.begin, trimmed(e.begin, e.end) - (buffer.char(trimmed(e.begin, e.end) - 1) == 10 ? 1 : 0))
        }
        /// The stars of the heading on the line holding `p`, or nil.
        func headingLevel(_ p: Int) -> Int? {
            let line = buffer.substring(buffer.lineStart(p)..<buffer.lineEnd(p))
            guard let stars = line.range(of: "^\\*+(?=[ \\t]|$)", options: .regularExpression) else { return nil }
            return line.distance(from: stars.lowerBound, to: stars.upperBound)
        }
        func at(_ p: Int) -> (range: Range<Int>, linewise: Bool) { (p..<p, false) }
        switch key {
        case "j":
            guard position < buffer.length else { return nil }
            if headingLevel(position) != nil {
                // To the end of the subtree, when a heading is there.
                guard let section = chain.last(where: { $0.kind == .section }) else { return nil }
                let end = section.range.upperBound
                return end < buffer.length && headingLevel(end) != nil ? at(end) : nil
            }
            guard let e = atPoint() else { return nil }
            if let up = parent(e), up.contents?.upperBound == e.end { return at(up.end) }
            return at(e.end)
        case "k":
            guard position > 0 else { return nil }
            if let level = headingLevel(position) {
                // The previous heading at this level, or else the parent.
                var line = buffer.lineStart(position)
                while line > 0 {
                    line = buffer.lineStart(line - 1)
                    if let other = headingLevel(line), other <= level { return at(line) }
                }
                return nil
            }
            guard let e = atPoint() else { return nil }
            if position != e.begin { return at(e.begin) }
            var p = e.begin
            while p > 0, let ch = buffer.char(p - 1), Buffer.isSpace(ch) { p -= 1 }
            guard p > 0 else { return at(0) }
            look(at: p)
            guard var prev = atPoint() else { return at(e.begin) }
            var target = prev.begin
            while let up = parent(prev), up.end <= e.begin {
                target = up.begin
                prev = up
            }
            return at(target)
        case "R":
            guard let headline = chain.last(where: { $0.kind == .section }).map(element) else { return nil }
            return (inner ? (headline.contents ?? headline.begin..<headline.begin) : headline.begin..<headline.end, true)
        case "E":
            guard let e = atPoint() else { return nil }
            return (inner ? innerRange(e) : e.begin..<e.end, false)
        case "r":
            guard var e = atPoint() else { return nil }
            if !e.greater, let up = parent(e) { e = up }
            return (inner ? innerRange(e) : e.begin..<e.end, !inner)
        default:
            let objects: Set<SyntaxKind> = [.bold, .italic, .underline, .strikeThrough, .verbatim, .code, .link, .timestamp, .footnoteReference,
                                            .statisticsCookie, .target, .radioTarget, .macro, .inlineSourceBlock, .latexFragment, .entity, .superscript, .subscript,
                                            .citation, .citationReference, .exportSnippet, .inlineBabelCall]
            guard let found = chain.last(where: { objects.contains($0.kind) }) else {
                guard let e = atPoint() else { return nil }
                return (inner ? innerRange(e) : e.begin..<e.end, false)
            }
            var range = found.range
            var end = range.upperBound
            while let ch = buffer.char(end), Buffer.isBlank(ch) { end += 1 }
            if inner {
                switch found.kind {
                case .bold, .italic, .underline, .strikeThrough, .verbatim, .code:
                    range = (range.lowerBound + 1)..<(range.upperBound - 1)
                case .link:
                    if let description = found.firstChild(.linkDescription) { range = description.range }
                default:
                    break
                }
                return (range, false)
            }
            return (range.lowerBound..<end, false)
        }
    }

    // MARK: - Block visual

    /// The block's columns and line starts, from `anchor` to `caret`; `$` stretches it to each
    /// line's end.
    func block(_ buffer: Buffer, _ caret: Int) -> (lines: [Int], left: Int, right: Int) {
        let a = min(anchor, caret), b = max(anchor, caret)
        let left = min(anchor - buffer.lineStart(anchor), caret - buffer.lineStart(caret))
        let right = blockToEnd ? Int.max : max(anchor - buffer.lineStart(anchor), caret - buffer.lineStart(caret))
        var lines: [Int] = []
        var line = buffer.lineStart(a)
        while true {
            lines.append(line)
            let end = buffer.lineEnd(line)
            guard end < buffer.length, line < buffer.lineStart(b) else { break }
            line = end + 1
        }
        return (lines, left, right)
    }

    /// Each line's part of the block.
    func blockRanges(_ buffer: Buffer, _ caret: Int) -> [Range<Int>] {
        let (lines, left, right) = block(buffer, caret)
        return lines.map { line in
            let end = buffer.lineEnd(line)
            let lower = min(line + left, end)
            let upper = right == Int.max ? end : min(line + right + 1, end)
            return lower..<max(lower, upper)
        }
    }

    func blockActions(_ buffer: Buffer, _ caret: Int) -> [Action] {
        [.move(caret: caret), .selectBlock(blockRanges(buffer, caret))]
    }

    /// Keys in block visual state.
    mutating func parseBlock(_ rest: ArraySlice<KeyChord>, _ buffer: inout Buffer, _ context: Context, register: Character?, count n: Int, keys: [KeyChord]) -> Parse {
        guard let first = rest.first else { return .incomplete }
        let caret = context.caret
        let ranges = blockRanges(buffer, caret)
        func leave() {
            lastVisual = (anchor, caret, .visualBlock)
            mode = .normal
            blockToEnd = false
        }
        if first == KeyChord("v", .control) || (first.modifiers.isEmpty && first.key == "ESC") {
            leave()
            return .done([.move(caret: buffer.clampNormal(caret))])
        }
        guard first.modifiers.isEmpty else { return .invalid }
        switch first.key {
        case "v", "V":
            lastVisual = (anchor, caret, .visualBlock)
            mode = first.key == "v" ? .visual : .visualLine
            blockToEnd = false
            return .done(visualActions(buffer, caret))
        case "o", "O":
            let old = anchor
            anchor = caret
            return .done(blockActions(buffer, old))
        case "$":
            blockToEnd = true
            return .done(blockActions(buffer, buffer.lineEnd(caret) > buffer.lineStart(caret) ? buffer.lineEnd(caret) - 1 : caret))
        case "d", "x", "y", "c":
            let removed = ranges.map { buffer.substring($0) }.joined(separator: "\n")
            leave()
            var actions = store(removed, linewise: false, register: register, yank: first.key == "y")
            let top = ranges.first?.lowerBound ?? caret
            if first.key == "y" { return .done(actions + [.move(caret: top)]) }
            let edits = ranges.reversed().map { TextEdit(range: $0, replacement: "") }
            if first.key == "c" {
                let (lines, left, _) = block(buffer, caret)
                blockInsert = (lines.dropFirst().map { buffer.lineNumber($0) }, left, false)
                actions.insert(.edit(edits, caret: top), at: 0)
                enterInsert(at: top, keys: [])
                return .done(actions)
            }
            actions.insert(.edit(edits, caret: buffer.removing(top..<top).clampNormal(top)), at: 0)
            return .done(actions)
        case "I", "A":
            let (lines, left, right) = block(buffer, caret)
            leave()
            let column = first.key == "I" ? left : (right == Int.max ? Int.max : right + 1)
            let top = lines.first ?? caret
            let at: Int
            if column == Int.max {
                at = buffer.lineEnd(top)
            } else {
                at = min(top + column, buffer.lineEnd(top))
            }
            blockInsert = (lines.dropFirst().map { buffer.lineNumber($0) }, column, first.key == "A")
            var actions: [Action] = []
            // `A` past a short first line pads it with spaces.
            if first.key == "A", column != Int.max, buffer.lineEnd(top) < top + column {
                let pad = top + column - buffer.lineEnd(top)
                actions.append(.edit([TextEdit(range: buffer.lineEnd(top)..<buffer.lineEnd(top), replacement: String(repeating: " ", count: pad))], caret: top + column))
                enterInsert(at: top + column, keys: [])
                return .done(actions)
            }
            enterInsert(at: at, keys: [])
            return .done([.move(caret: at)])
        case "r":
            guard rest.count >= 2 else { return .incomplete }
            let char = rest[rest.startIndex + 1].key == "SPC" ? " " : rest[rest.startIndex + 1].key
            guard char.count == 1 else { return .invalid }
            leave()
            let edits = ranges.reversed().map { TextEdit(range: $0, replacement: String(repeating: char, count: $0.count)) }
            return .done([.edit(edits, caret: ranges.first?.lowerBound ?? caret)])
        case "~", "u", "U":
            leave()
            let edits = ranges.reversed().map { r -> TextEdit in
                let s = buffer.substring(r)
                let t = first.key == "u" ? s.lowercased() : first.key == "U" ? s.uppercased() : String(s.map { $0.isUppercase ? Character($0.lowercased()) : Character($0.uppercased()) })
                return TextEdit(range: r, replacement: t)
            }
            return .done([.edit(edits, caret: ranges.first?.lowerBound ?? caret)])
        case ">", "<":
            leave()
            let lines = block(buffer, caret).lines
            let range = (lines.first ?? caret)..<min(buffer.length, buffer.lineEnd(lines.last ?? caret) + 1)
            mode = .normal
            return .done(apply(first.key, range: range, linewise: true, buffer, register: register, keys: [], count: n))
        default:
            var target = caret
            switch motion(Array(rest), &buffer, &target, count: n, operatorPending: false) {
            case .incomplete: return .incomplete
            case .invalid: return .invalid
            case .moved(let to, _): return .done(blockActions(buffer, to))
            }
        }
    }

    /// What block `I`, `A` or `c` typed, put on the block's other lines at its column.
    func replicateBlockInsert(_ block: (lines: [Int], column: Int, pad: Bool), _ buffer: Buffer, caret: Int) -> [Action] {
        var edits: [TextEdit] = []
        for number in block.lines.reversed() {
            let line = buffer.lineOffset(number)
            let end = buffer.lineEnd(line)
            if block.column == Int.max {
                edits.append(TextEdit(range: end..<end, replacement: insertedText))
            } else if line + block.column <= end {
                edits.append(TextEdit(range: (line + block.column)..<(line + block.column), replacement: insertedText))
            } else if block.pad {
                edits.append(TextEdit(range: end..<end, replacement: String(repeating: " ", count: line + block.column - end) + insertedText))
            }
        }
        let lineStart = buffer.lineStart(caret)
        let back = caret > lineStart ? caret - 1 : caret
        return edits.isEmpty ? [.move(caret: back)] : [.edit(edits, caret: back)]
    }
}
