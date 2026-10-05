import Foundation

/// A whole-text buffer with Emacs's point and marker rules, for porting org commands that
/// edit several lines. Offsets are UTF-16, as everywhere in `OrgCore`.
///
/// Inserting at point moves point past the text; a marker at the insertion point stays before
/// it unless the insertion is `insertBeforeMarkers`. Deleting a range moves positions inside
/// it to its start. `saveExcursion` restores point from a marker, as Emacs does.
final class EmacsBuffer {
    final class Marker {
        var position: Int
        /// Inserting at the marker moves it past the text, as `set-marker-insertion-type` t.
        let advances: Bool
        init(_ position: Int, advances: Bool = false) {
            self.position = position
            self.advances = advances
        }
    }

    struct UserError: Error {
        let message: String
    }

    private(set) var text: NSMutableString
    var point: Int
    private var markers: [Marker] = []
    let settings: OrgSettings
    /// Groups of the last successful match, as Emacs's match data.
    var lastMatch: [Range<Int>?] = []

    let options: EditingOptions

    init(_ text: String, point: Int, settings: OrgSettings = .default, options: EditingOptions = .org) {
        self.text = NSMutableString(string: text)
        self.point = point
        self.settings = settings
        self.options = options
        unchangedPrefix = self.text.length
        unchangedSuffix = self.text.length
    }

    /// Lengths of the start and end of the text no edit has touched, so the result's diff can
    /// look only between them.
    private(set) var unchangedPrefix: Int
    private(set) var unchangedSuffix: Int

    private func touched(_ range: Range<Int>) {
        unchangedPrefix = min(unchangedPrefix, range.lowerBound)
        unchangedSuffix = min(unchangedSuffix, length - range.upperBound)
    }

    /// The text as a `String` backed by an immutable `NSString`, copied once per change rather
    /// than per regexp search; regexps read it without converting.
    var string: String {
        if let cachedString { return cachedString as String }
        let copy = text.copy() as! NSString
        cachedString = copy
        return copy as String
    }

    private var cachedString: NSString?
    var length: Int { text.length }

    func character(at offset: Int) -> unichar? {
        offset >= 0 && offset < length ? text.character(at: offset) : nil
    }

    static let newline = unichar(10)

    // MARK: - Markers

    func marker(_ position: Int, advances: Bool = false) -> Marker {
        let marker = Marker(position, advances: advances)
        markers.append(marker)
        return marker
    }

    func release(_ marker: Marker) {
        markers.removeAll { $0 === marker }
    }

    /// Runs `body` and puts point back where it was, following edits as a marker does.
    @discardableResult
    func saveExcursion<T>(_ body: () throws -> T) rethrows -> T {
        let saved = marker(point)
        defer {
            point = saved.position
            release(saved)
        }
        return try body()
    }

    // MARK: - Editing

    /// `insert` at point.
    func insert(_ string: String) {
        let count = (string as NSString).length
        guard count > 0 else { return }
        touched(point..<point)
        text.insert(string, at: point)
        cachedString = nil
        for marker in markers where marker.position > point || (marker.advances && marker.position == point) { marker.position += count }
        point += count
    }

    /// `insert-before-markers` at point: markers at point move past the text too.
    func insertBeforeMarkers(_ string: String) {
        let count = (string as NSString).length
        guard count > 0 else { return }
        touched(point..<point)
        text.insert(string, at: point)
        cachedString = nil
        for marker in markers where marker.position >= point { marker.position += count }
        point += count
    }

    func deleteRegion(_ start: Int, _ end: Int) {
        let (lower, upper) = (min(start, end), max(start, end))
        guard upper > lower else { return }
        touched(lower..<upper)
        text.deleteCharacters(in: NSRange(lower..<upper))
        cachedString = nil
        func map(_ position: Int) -> Int {
            position <= lower ? position : position >= upper ? position - (upper - lower) : lower
        }
        point = map(point)
        for marker in markers { marker.position = map(marker.position) }
    }

    func substring(_ start: Int, _ end: Int) -> String {
        text.substring(with: NSRange(min(start, end)..<max(start, end)))
    }

    /// `replace-match` over `range`: positions strictly inside go to its start, positions at
    /// or after its end shift with the text.
    func replace(_ range: Range<Int>, with replacement: String) {
        let delta = (replacement as NSString).length - range.count
        touched(range)
        text.replaceCharacters(in: NSRange(range), with: replacement)
        cachedString = nil
        func map(_ position: Int) -> Int {
            if position >= range.upperBound, position > range.lowerBound { return position + delta }
            return position > range.lowerBound ? range.lowerBound : position
        }
        point = map(point)
        for marker in markers { marker.position = map(marker.position) }
    }

    // MARK: - Motion

    var bolp: Bool { point == 0 || character(at: point - 1) == Self.newline }
    var eolp: Bool { point == length || character(at: point) == Self.newline }
    var bobp: Bool { point == 0 }
    var eobp: Bool { point == length }

    func lineStart(_ offset: Int) -> Int {
        var at = min(offset, length)
        while at > 0, character(at: at - 1) != Self.newline { at -= 1 }
        return at
    }

    func lineEnd(_ offset: Int) -> Int {
        var at = max(offset, 0)
        while at < length, character(at: at) != Self.newline { at += 1 }
        return at
    }

    func beginningOfLine() { point = lineStart(point) }
    func endOfLine() { point = lineEnd(point) }

    /// `forward-line`: to the start of the line `n` lines away, stopping at the buffer ends.
    @discardableResult
    func forwardLine(_ n: Int) -> Int {
        point = lineStart(point)
        var remaining = n
        while remaining > 0 {
            let end = lineEnd(point)
            if end == length {
                point = length
                return remaining
            }
            point = end + 1
            remaining -= 1
        }
        while remaining < 0 {
            if point == 0 { return remaining }
            point = lineStart(point - 1)
            remaining += 1
        }
        return 0
    }

    func skipForward(_ set: Set<unichar>) {
        while let c = character(at: point), set.contains(c) { point += 1 }
    }

    func skipBackward(_ set: Set<unichar>) {
        while let c = character(at: point - 1), set.contains(c) { point -= 1 }
    }

    static let blanks: Set<unichar> = [32, 9]
    static let whitespace: Set<unichar> = [32, 9, 10, 13]

    var currentColumn: Int { column(of: substring(lineStart(point), point)) }

    /// `move-to-column`: as far as `target` on this line, or the line's end. With `force`, a
    /// tab spanning `target` becomes spaces (`indent-tabs-mode` nil) so point lands on it.
    func moveToColumn(_ target: Int, force: Bool = false) {
        let start = lineStart(point)
        let line = LineBuffer(substring(start, lineEnd(point)), caret: nil)
        point = start + line.offset(ofColumn: target)
        guard force, currentColumn > target, character(at: point - 1) == 9 else { return }
        let tabEnd = currentColumn
        point -= 1
        let tabStart = currentColumn
        deleteRegion(point, point + 1)
        insert(String(repeating: " ", count: tabEnd - tabStart))
        point -= tabEnd - target
    }

    // MARK: - Outline

    /// Stars of a heading line starting at `lineStart`, or nil.
    func headingLevel(atLine lineStart: Int) -> Int? {
        var at = lineStart
        while character(at: at) == 42 { at += 1 }
        return at > lineStart && character(at: at) == 32 ? at - lineStart : nil
    }

    var atHeading: Bool { headingLevel(atLine: lineStart(point)) != nil }

    /// Start of the first heading line after `offset`'s line, or nil.
    func nextHeadingStart(after offset: Int) -> Int? {
        var line = lineEnd(offset)
        while line < length {
            line += 1
            if headingLevel(atLine: line) != nil { return line }
            line = lineEnd(line)
        }
        return nil
    }

    /// Start of the last heading line before `offset`'s line, or nil.
    func previousHeadingStart(before offset: Int) -> Int? {
        var line = lineStart(offset)
        while line > 0 {
            line = lineStart(line - 1)
            if headingLevel(atLine: line) != nil { return line }
        }
        return nil
    }

    /// `org-outline-level`: the level of the heading at or before point's line, or 0.
    var outlineLevel: Int {
        let start = lineStart(point)
        if let level = headingLevel(atLine: start) { return level }
        return previousHeadingStart(before: start).flatMap { headingLevel(atLine: $0) } ?? 0
    }

    var currentLevel: Int? { outlineLevel > 0 ? outlineLevel : nil }

    var beforeFirstHeading: Bool { outlineLevel == 0 }

    /// `org-back-to-heading`.
    @discardableResult
    func backToHeading() throws -> Int {
        let start = lineStart(point)
        if headingLevel(atLine: start) != nil {
            point = start
        } else if let previous = previousHeadingStart(before: start) {
            point = previous
        } else {
            throw UserError(message: "Before first headline at position \(point + 1) in buffer")
        }
        return point
    }

    /// `outline-next-heading`: the next heading line, or the buffer end. True when found.
    @discardableResult
    func outlineNextHeading() -> Bool {
        if bolp, !eobp { point += 1 }
        // A heading line starting at point counts, as `re-search-forward "^\\*+ "` would.
        if bolp, headingLevel(atLine: point) != nil { return true }
        guard let next = nextHeadingStart(after: point) else {
            point = length
            return false
        }
        point = next
        return true
    }

    /// `outline-previous-heading`: the previous heading line, or the buffer start.
    func outlinePreviousHeading() {
        // `re-search-backward` matches must end by point: a heading on this line counts once
        // point is past its stars and space.
        let start = lineStart(point)
        if let level = headingLevel(atLine: start), point >= start + level + 1 {
            point = start
            return
        }
        point = previousHeadingStart(before: point) ?? 0
    }

    /// `org-end-of-subtree`.
    @discardableResult
    func endOfSubtree(toHeading: Bool = false) -> Int {
        if beforeFirstHeading {
            point = length
        } else {
            let start = try! backToHeading()
            let level = headingLevel(atLine: start)!
            var next = nextHeadingStart(after: start)
            while let candidate = next, headingLevel(atLine: candidate)! > level {
                next = nextHeadingStart(after: candidate)
            }
            point = next ?? length
        }
        if !toHeading, let c = character(at: point - 1), c == 10 || c == 13 {
            point -= 1
            skipBackward([10, 13, 9, 32])
        }
        return point
    }

    /// `org-get-next-sibling`.
    func nextSibling() -> Int? {
        let level = outlineLevel
        outlineNextHeading()
        while !eobp, outlineLevel > level { outlineNextHeading() }
        return eobp || outlineLevel < level ? nil : point
    }

    /// `org-get-previous-sibling`.
    func previousSibling() -> Int? {
        let start = point
        let level = outlineLevel
        outlinePreviousHeading()
        guard point != start, atHeading else { return nil }
        while outlineLevel > level, !bobp { outlinePreviousHeading() }
        return outlineLevel < level ? nil : point
    }

    /// `org--line-empty-p -1`.
    var previousLineEmpty: Bool {
        guard !bobp else { return false }
        return saveExcursion {
            forwardLine(-1)
            skipForward(Self.blanks)
            return eolp
        }
    }

    // MARK: - Regular expressions

    static let lookingOptions: NSRegularExpression.MatchingOptions = [.anchored, .withoutAnchoringBounds, .withTransparentBounds]
    static let searchOptions: NSRegularExpression.MatchingOptions = [.withoutAnchoringBounds, .withTransparentBounds]
    nonisolated(unsafe) private static var cache: [String: NSRegularExpression] = [:]
    private static let cacheLock = NSLock()

    /// A compiled Emacs-style pattern: `^` and `$` match at line boundaries, and a leading `^`
    /// also matches at the end of a buffer that ends with a newline, as in Emacs.
    static func regex(_ pattern: String, caseInsensitive: Bool) -> NSRegularExpression {
        let key = (caseInsensitive ? "i" : "c") + pattern
        return cacheLock.withLock {
            if let cached = cache[key] { return cached }
            let source = pattern.hasPrefix("^") ? "(?:(?<=\\n)|(?<![\\s\\S]))" + pattern.dropFirst() : pattern
            let compiled = try! NSRegularExpression(pattern: source, options: caseInsensitive ? [.anchorsMatchLines, .caseInsensitive] : [.anchorsMatchLines])
            cache[key] = compiled
            return compiled
        }
    }

    /// `looking-at`: the groups of `pattern` matched at point (`^` and `$` match at lines),
    /// or nil. Unmatched groups are nil.
    func lookingAt(_ pattern: String) -> [Range<Int>?]? {
        let regex = Self.regex(pattern, caseInsensitive: false)
        guard let match = regex.firstMatch(in: string, options: Self.lookingOptions, range: NSRange(point..<length)) else { return nil }
        lastMatch = (0..<match.numberOfRanges).map { i in
            let range = match.range(at: i)
            return range.location == NSNotFound ? nil : range.location..<NSMaxRange(range)
        }
        return lastMatch
    }

    /// `org-complex-heading-regexp`: 1 stars, 2 keyword, 3 priority, 4 title, 5 tags.
    var complexHeadingPattern: String {
        "^(\\*+)(?: +(\(keywordAlternation)))?(?: +(\\[#(?:[A-Z]|[0-9]|[1-5][0-9]|6[0-4])\\]))?(?: +(.*?))??(?:[ \t]+(:[[:alnum:]_@#%:]+:))?[ \t]*$"
    }

    /// `org-todo-line-regexp`: 1 stars, 2 keyword, 3 title.
    var todoLinePattern: String {
        "^(\\*+)(?: +(\(keywordAlternation)))?(?: +(.*?))?[ \t]*$"
    }

    private var keywordAlternation: String {
        keywordsInOrder.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
    }

    /// `org-todo-keywords-1`.
    var keywordsInOrder: [String] {
        settings.todoSequences.flatMap { ($0.active + $0.done).map(\.name) }
    }

    // MARK: - Tags

    /// `org-align-tags` on the line at `offset`, moving point and markers on the line as the
    /// tag alignment rules say.
    func alignTags(onLineAt offset: Int) {
        let start = lineStart(offset)
        let end = lineEnd(offset)
        let line = substring(start, end)
        var plain = LineBuffer(line, caret: nil)
        OrgCore.alignTags(&plain, tagsColumn: options.tagsColumn)
        guard plain.string != line else { return }
        func map(_ position: Int) -> Int {
            guard position >= start, position <= end else {
                return position > end ? position + (plain.string as NSString).length - (line as NSString).length : position
            }
            var buffer = LineBuffer(line, caret: position - start)
            OrgCore.alignTags(&buffer, tagsColumn: options.tagsColumn)
            return start + buffer.caret!
        }
        let newPoint = map(point)
        let newMarkers = markers.map { map($0.position) }
        touched(start..<end)
        text.replaceCharacters(in: NSRange(start..<end), with: plain.string)
        cachedString = nil
        point = newPoint
        for (marker, position) in zip(markers, newMarkers) { marker.position = position }
    }
}

/// Runs a buffer-editing body against a context and turns the result into one minimal edit
/// and the new caret. A user error becomes `.failed`.
func commitBuffer(_ context: EditContext, _ body: (EmacsBuffer) throws -> Void) -> CommandStep {
    let buffer = EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings, options: context.options)
    do {
        try body(buffer)
    } catch let error as EmacsBuffer.UserError {
        return .failed(error.message)
    } catch {
        return .failed("\(error)")
    }
    // Only the span between the untouched start and end can differ.
    let oldText = context.text.utf16
    let oldCount = oldText.count
    let newCount = buffer.length
    let lower = min(buffer.unchangedPrefix, oldCount, newCount)
    let window = max(0, min(buffer.unchangedSuffix, oldCount - lower, newCount - lower))
    let old = Array(oldText[oldText.index(oldText.startIndex, offsetBy: lower)..<oldText.index(oldText.startIndex, offsetBy: oldCount - window)])
    var newBuffer = [unichar](repeating: 0, count: newCount - window - lower)
    buffer.text.getCharacters(&newBuffer, range: NSRange(lower..<(newCount - window)))
    let new = newBuffer
    var prefix = 0
    let shorter = min(old.count, new.count)
    while prefix < shorter, old[prefix] == new[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < shorter - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
    // Keep surrogate pairs whole.
    while prefix > 0, prefix < old.count, UTF16.isTrailSurrogate(old[prefix]) { prefix -= 1 }
    while suffix > 0, UTF16.isTrailSurrogate(old[old.count - suffix]) { suffix -= 1 }
    let caret = buffer.point
    guard old.count != new.count || prefix != old.count else {
        return .commit(EditResult(baseRevision: context.revision, edits: [], selection: [caret..<caret]))
    }
    let edit = TextEdit(range: (lower + prefix)..<(lower + old.count - suffix), replacement: String(decoding: new[prefix..<(new.count - suffix)], as: UTF16.self))
    return .commit(EditResult(baseRevision: context.revision, edits: [edit], selection: [caret..<caret]))
}
