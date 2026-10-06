import Foundation

/// Narrowed table columns (`org-table-shrink`, `org-table-toggle-column-width`, Org 9.8.7):
/// where org puts its overlays, as ranges of text shown as other text. The editor hides each
/// range and draws its display instead.
public enum TableShrink {
    public struct Segment: Sendable, Equatable {
        public let range: Range<Int>
        /// What shows instead of the range's text.
        public let display: String
    }

    static let indicator = "…"

    /// The table holding `offset`: its start and end.
    public static func table(at offset: Int, in text: String) -> Range<Int>? {
        let buffer = EmacsBuffer(text, point: offset)
        guard buffer.atTable else { return nil }
        return buffer.tableBegin()..<buffer.tableEnd()
    }

    /// The column at `offset`, or nil before the first or after the last.
    public static func column(at offset: Int, in text: String) -> Int? {
        let buffer = EmacsBuffer(text, point: offset)
        let outside = buffer.saveExcursion { () -> Bool in
            buffer.skipBackwardNot([124, 10])
            return buffer.bolp || buffer.looking("[ \\t]*$", caseInsensitive: false, setsMatch: false) != nil
        }
        return outside ? nil : buffer.tableCurrentColumn()
    }

    /// The columns with a width cookie, as `org-table-shrink` finds them.
    public static func cookieColumns(_ table: Range<Int>, in text: String) -> [Int] {
        let buffer = EmacsBuffer(text, point: table.lowerBound)
        var columns: [Int] = []
        while let match = buffer.searchForward("\\|[ \\t]*<[lrc]?[0-9]+>[ \\t]*(\\||$)", bound: table.upperBound, caseInsensitive: false) {
            buffer.point = match[1]!.lowerBound
            let column = buffer.tableCurrentColumn()
            if !columns.contains(column) { columns.append(column) }
        }
        return columns.sorted()
    }

    /// `org-table--read-column-selection`.
    public static func columns(_ selection: String, max: Int) -> [Int] {
        var result: Set<Int> = []
        for part in selection.split(whereSeparator: \.isWhitespace) {
            if let m = part.wholeMatch(of: /([0-9]+)?-([0-9]+)?/) {
                let low = m.1.flatMap { Int($0) } ?? 1
                let high = m.2.flatMap { Int($0) } ?? max
                if low <= high { result.formUnion(low...high) }
            } else if let n = Int(part) {
                result.insert(n)
            }
        }
        return result.sorted()
    }

    /// `org-table--shrink-columns` for one column.
    public static func segments(_ table: Range<Int>, column c: Int, in text: String) -> [Segment] {
        let buffer = EmacsBuffer(text, point: table.lowerBound)
        var align: String?
        var width: Int?
        var fields: [(start: Int, end: Int, contents: String?)] = []
        while buffer.point < table.upperBound {
            let lineEnd = buffer.lineEnd(buffer.point)
            let hline = buffer.lookingAt("[ \\t]*\\|-") != nil
            let separator: unichar = hline ? 43 : 124
            var ok = buffer.searchForward("\\|", bound: lineEnd, caseInsensitive: false) != nil
            var remaining = c - 1
            while ok, remaining > 0 {
                guard let next = (buffer.point..<lineEnd).first(where: { buffer.character(at: $0) == separator }) else { ok = false; break }
                buffer.point = next + 1
                remaining -= 1
            }
            if ok {
                let start = buffer.point
                var end = start
                while end < lineEnd, let ch = buffer.character(at: end), ch != 124, ch != separator { end += 1 }
                let contents: String? = hline ? nil : buffer.substring(start, end).trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r"))
                fields.append((start, end, contents))
                if let contents, let m = contents.wholeMatch(of: /<([lrc])?([0-9]+)>/) {
                    if align == nil { align = m.1.map(String.init) }
                    if width == nil { width = Int(m.2) }
                }
            }
            if buffer.forwardLine(1) != 0 { break }
        }
        return fields.flatMap { shrinkField(width: width ?? 0, align: align ?? "l", start: $0.start, end: $0.end, contents: $0.contents, buffer: buffer) }
    }

    /// `org-table--shrink-field`; nil contents for a rule.
    static func shrinkField(width: Int, align: String, start: Int, end: Int, contents: String?, buffer: EmacsBuffer) -> [Segment] {
        func overlay(_ s: Int, _ e: Int, _ display: String, pre: Bool = false) -> Segment {
            Segment(range: s..<e, display: pre ? " " + display : display + indicator)
        }
        func stringWidth(_ s: Int, _ e: Int) -> Int { buffer.cellWidth(buffer.substring(s, e)) }
        guard start != end else { return [] }
        if width == 0 { return [overlay(start, end, "")] }
        guard let contents else { return [overlay(start, end, String(repeating: "-", count: width + 1))] }
        if contents.isEmpty {
            let w = stringWidth(start, end)
            let full = width + 2
            return w <= full ? [overlay(end - 1, end, String(repeating: " ", count: full - w))] : [overlay(end - (w - full) - 1, end, "")]
        }
        var lead = 0
        while start + lead < end, buffer.character(at: start + lead) == 32 { lead += 1 }
        var trail = 0
        while end - trail > start + lead, buffer.character(at: end - trail - 1) == 32 { trail += 1 }
        let contentsWidth = stringWidth(start + lead, end - trail)
        if width <= contentsWidth {
            let pre = lead > 0 ? overlay(start, start + lead, "", pre: true) : nil
            let begin = start + lead
            var lower = begin
            var upper = end - 1
            let target = lead == 0 ? width + 1 : width
            var cut = upper
            while upper - lower > 1 {
                let mean = (lower >> 1) + (upper >> 1) + (lower & upper & 1)
                let w = stringWidth(begin, mean)
                if w == target {
                    cut = mean
                    break
                } else if w > target {
                    upper = mean
                } else {
                    lower = mean
                }
                cut = upper
            }
            return [pre, overlay(cut, end, "")].compactMap { $0 }
        }
        let required = width - contentsWidth
        let before: Int = lead == 0 ? -1 : align == "r" ? required : align == "c" ? required / 2 : 0
        let after = required - before
        var result: [Segment] = []
        if lead != 0, lead - 1 != before {
            if lead - 1 > before {
                result.append(overlay(start, start + (lead - before), "", pre: true))
            } else {
                result.append(overlay(start, start + 1, String(repeating: " ", count: before - (lead - 1)), pre: true))
            }
        }
        if trail - 1 == after {
            result.append(overlay(end - 1, end, ""))
        } else if trail - 1 > after {
            result.append(overlay(after + (end - trail), end, ""))
        } else {
            result.append(overlay(end - 1, end, String(repeating: " ", count: after - (trail - 1))))
        }
        return result
    }
}
