#if os(macOS)
import AppKit

/// The text as shown, for VoiceOver: without hidden markup (link brackets and targets, hidden
/// emphasis markers and stars), with pretty entities and shrunk table cells as they're drawn.
/// Folded text is still read, so the whole file can be. `model` maps each UTF-16 unit of
/// `string` to the buffer.
struct AccessibleText {
    let string: String
    /// Buffer offset of each unit of `string`, then the buffer's length.
    let model: [Int]

    init(_ storage: NSAttributedString) {
        let ns = storage.string as NSString
        let whole = NSRange(location: 0, length: ns.length)
        // What isn't read: markup drawn at no size. Entities read as drawn.
        var skipped: [Range<Int>] = []
        storage.enumerateAttribute(.font, in: whole) { value, run, _ in
            if let font = value as? NSFont, font.pointSize < 0.1 { skipped.append(run.location..<NSMaxRange(run)) }
        }
        var displays: [(at: Int, text: String)] = []
        storage.enumerateAttribute(.orgEntityDisplay, in: whole) { value, run, _ in
            if let text = value as? String { displays.append((run.location, text)) }
        }
        skipped.sort { $0.lowerBound < $1.lowerBound }
        var units = [unichar](repeating: 0, count: ns.length)
        units.withUnsafeMutableBufferPointer { ns.getCharacters($0.baseAddress!, range: whole) }
        var outUnits: [unichar] = []
        var model: [Int] = []
        outUnits.reserveCapacity(ns.length)
        model.reserveCapacity(ns.length + 1)
        var next = 0
        var display = 0
        func copy(_ from: Int, _ to: Int) {
            var p = from
            while p < to {
                while display < displays.count, displays[display].at < p { display += 1 }
                let stop = display < displays.count ? min(to, displays[display].at) : to
                outUnits.append(contentsOf: units[p..<stop])
                model.append(contentsOf: p..<stop)
                p = stop
                if p < to {
                    for unit in displays[display].text.utf16 {
                        outUnits.append(unit)
                        model.append(p)
                    }
                    p += 1
                    display += 1
                }
            }
        }
        for skip in skipped where skip.upperBound > next {
            if skip.lowerBound > next { copy(next, skip.lowerBound) }
            next = max(next, skip.upperBound)
        }
        copy(next, ns.length)
        model.append(ns.length)
        string = String(utf16CodeUnits: outUnits, count: outUnits.count)
        self.model = model
    }

    var length: Int { model.count - 1 }

    /// The shown offset at or after buffer offset `offset`.
    func visible(_ offset: Int) -> Int {
        var low = 0
        var high = length
        while low < high {
            let mid = (low + high) / 2
            if model[mid] < offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    func visible(_ range: NSRange) -> NSRange {
        let start = visible(range.location)
        return NSRange(location: start, length: max(0, visible(NSMaxRange(range)) - start))
    }

    /// The buffer range a shown range covers.
    func buffer(_ range: NSRange) -> NSRange {
        let start = model[min(max(0, range.location), length)]
        let endIndex = min(max(0, NSMaxRange(range)), length)
        let end = endIndex > range.location && endIndex > 0 ? model[endIndex - 1] + 1 : model[endIndex]
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Shown lines: line `n` is the text between the n-th and (n+1)-th newline.
    func line(for index: Int) -> Int {
        let ns = string as NSString
        var line = 0
        var p = 0
        while p < min(index, ns.length) {
            let next = ns.range(of: "\n", range: NSRange(location: p, length: min(index, ns.length) - p))
            guard next.location != NSNotFound else { break }
            line += 1
            p = next.location + 1
        }
        return line
    }

    func range(forLine line: Int) -> NSRange {
        let ns = string as NSString
        var start = 0
        for _ in 0..<line {
            let next = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
            guard next.location != NSNotFound else { return NSRange(location: ns.length, length: 0) }
            start = next.location + 1
        }
        return ns.lineRange(for: NSRange(location: start, length: 0))
    }
}

extension OrgTextView {
    private var shown: AccessibleText? { accessibleText?() }

    override func accessibilityValue() -> String? {
        shown?.string ?? super.accessibilityValue()
    }

    override func accessibilityNumberOfCharacters() -> Int {
        shown?.length ?? super.accessibilityNumberOfCharacters()
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        guard let shown else { return super.accessibilitySelectedTextRange() }
        return shown.visible(selectedRange())
    }

    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        guard let shown else { return super.setAccessibilitySelectedTextRange(range) }
        setSelectedRange(shown.buffer(range))
    }

    override func accessibilitySelectedText() -> String? {
        guard let shown else { return super.accessibilitySelectedText() }
        return (shown.string as NSString).substring(with: shown.visible(selectedRange()))
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        guard let shown else { return super.accessibilityVisibleCharacterRange() }
        return shown.visible(super.accessibilityVisibleCharacterRange())
    }

    override func accessibilityString(for range: NSRange) -> String? {
        guard let shown else { return super.accessibilityString(for: range) }
        let ns = shown.string as NSString
        guard range.location >= 0, NSMaxRange(range) <= ns.length else { return nil }
        return ns.substring(with: range)
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        accessibilityString(for: range).map { NSAttributedString(string: $0) }
    }

    override func accessibilityLine(for index: Int) -> Int {
        shown?.line(for: index) ?? super.accessibilityLine(for: index)
    }

    override func accessibilityInsertionPointLineNumber() -> Int {
        guard let shown else { return super.accessibilityInsertionPointLineNumber() }
        return shown.line(for: shown.visible(selectedRange().location))
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        shown?.range(forLine: line) ?? super.accessibilityRange(forLine: line)
    }

    override func accessibilityRange(for index: Int) -> NSRange {
        guard let shown else { return super.accessibilityRange(for: index) }
        return (shown.string as NSString).rangeOfComposedCharacterSequence(at: min(index, max(0, shown.length - 1)))
    }

    override func accessibilityStyleRange(for index: Int) -> NSRange {
        accessibilityRange(for: index)
    }

    override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let shown else { return super.accessibilityFrame(for: range) }
        return super.accessibilityFrame(for: shown.buffer(range))
    }

    override func accessibilityRange(for point: NSPoint) -> NSRange {
        guard let shown else { return super.accessibilityRange(for: point) }
        let range = super.accessibilityRange(for: point)
        return shown.visible(range)
    }
}
#endif
