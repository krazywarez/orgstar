import Foundation

// Date trees (org-datetree.el, Org 9.8.7): `org-datetree-find-create-entry` with the groupings
// capture uses, and `org-datetree-add-timestamp` nil. Each level is found or created inside
// the one above it, as org does while narrowed to it.
enum Datetree {
    static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

    /// Each level's heading title, and the pattern whose first group orders siblings.
    static func levels(_ tree: CaptureTemplate.TreeType, date: DateComponents) -> [(title: String, pattern: String)] {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC")!
        let day = gregorian.date(from: DateComponents(year: date.year, month: date.month, day: date.day))!
        let weekday = weekdays[gregorian.component(.weekday, from: day) - 1]
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = gregorian.timeZone
        let isoYear = iso.component(.yearForWeekOfYear, from: day)
        let week = iso.component(.weekOfYear, from: day)
        let year = (title: String(date.year!), pattern: "([12][0-9]{3})")
        let dayLevel = (title: String(format: "%04d-%02d-%02d ", date.year!, date.month!, date.day!) + weekday,
                        pattern: "([12][0-9]{3}-[01][0-9]-[0123][0-9]) \\w+")
        switch tree {
        case .day, .month:
            let month = (title: String(format: "%04d-%02d ", date.year!, date.month!) + months[date.month! - 1],
                         pattern: "([12][0-9]{3}-[01][0-9]) \\w+")
            return tree == .day ? [year, month, dayLevel] : [year, month]
        case .week:
            return [(String(isoYear), year.pattern), (String(format: "%04d-W%02d", isoYear, week), "([12][0-9]{3}-W[0-5][0-9])"), dayLevel]
        }
    }

    /// Point at the date's entry, created where missing, under the heading at `parent` or at
    /// the top of the file. Returns the entry's start.
    static func findCreate(_ buffer: EmacsBuffer, under parent: Int?, tree: CaptureTemplate.TreeType, date: DateComponents) -> Int {
        let low = buffer.marker(parent ?? 0)
        let high = buffer.marker(parent.map { narrowEnd(buffer, $0, limit: buffer.length) } ?? buffer.length, advances: true)
        defer {
            buffer.release(low)
            buffer.release(high)
        }
        var level = parent.map { Capture.headingLevel(buffer, at: $0) + 1 } ?? 1
        for (title, pattern) in levels(tree, date: date) {
            subheading(buffer, title: title, pattern: pattern, level: level, low: low, high: high)
            level += 1
        }
        return low.position
    }

    /// `org-datetree--find-create-subheading`: leaves the region narrowed to the subheading.
    static func subheading(_ buffer: EmacsBuffer, title: String, pattern: String, level: Int, low: EmacsBuffer.Marker, high: EmacsBuffer.Marker) {
        func compare(_ sibling: String) -> Int? {
            guard let a = firstGroup(pattern, sibling), let b = firstGroup(pattern, title) else { return nil }
            return a < b ? -1 : a > b ? 1 : 0
        }
        var sibling: (start: Int, order: Int)?
        buffer.point = low.position
        while let match = buffer.searchForward("^(\\*+) ", bound: high.position, caseInsensitive: false) {
            let start = match[0]!.lowerBound
            buffer.point = buffer.lineEnd(start)
            guard match[1]!.count == level else { continue }
            if let order = compare(rawTitle(buffer, start)), order >= 0 {
                sibling = (start, order)
                break
            }
        }
        if let sibling {
            buffer.point = sibling.start
        } else {
            buffer.point = high.position
            if !buffer.bolp { buffer.insert("\n") }
        }
        if let sibling, sibling.order == 0 {
            narrow(buffer, to: sibling.start, low: low, high: high)
            return
        }
        let end = buffer.point
        while buffer.point > low.position, let c = buffer.character(at: buffer.point - 1), c == 32 || c == 9 || c == 10 { buffer.point -= 1 }
        buffer.deleteRegion(buffer.point, end)
        if blankBeforeHeading(buffer, low: low.position, high: high.position) { buffer.insert("\n") }
        buffer.insert("\n" + String(repeating: "*", count: level) + " " + title + "\n")
        buffer.forwardLine(-1)
        narrow(buffer, to: buffer.point, low: low, high: high)
    }

    static func firstGroup(_ pattern: String, _ s: String) -> String? {
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// A heading's `:raw-value`: its title without keyword, priority or tags.
    static func rawTitle(_ buffer: EmacsBuffer, _ start: Int) -> String {
        buffer.saveExcursion {
            buffer.point = start
            guard let match = buffer.lookingAt(buffer.complexHeadingPattern), let title = match[4] else { return "" }
            return buffer.substring(title.lowerBound, title.upperBound)
        }
    }

    /// `org-narrow-to-subtree` inside the current region.
    static func narrow(_ buffer: EmacsBuffer, to heading: Int, low: EmacsBuffer.Marker, high: EmacsBuffer.Marker) {
        low.position = heading
        high.position = narrowEnd(buffer, heading, limit: high.position)
        buffer.point = heading
    }

    /// The subtree's end, before the newline that precedes the next heading, within `limit`.
    static func narrowEnd(_ buffer: EmacsBuffer, _ heading: Int, limit: Int) -> Int {
        let end = buffer.saveExcursion { () -> Int in
            Capture.endOfSubtree(buffer, heading: heading)
            return buffer.point
        }
        return min(limit, end == buffer.length ? end : end - 1)
    }

    /// `org--blank-before-heading-p` with `org-blank-before-new-entry` `(heading . auto)`,
    /// in the region `low..<high`.
    static func blankBeforeHeading(_ buffer: EmacsBuffer, low: Int, high: Int) -> Bool {
        buffer.saveExcursion {
            func headingStart(before limit: Int) -> Int? {
                buffer.saveExcursion {
                    buffer.point = buffer.lineEnd(limit)
                    return buffer.searchBackward("^\\*+ ", bound: low, caseInsensitive: false)?[0]?.lowerBound
                }
            }
            /// `outline-next-heading` bounded by `high`.
            func nextHeading() -> Bool {
                if let match = buffer.searchForward("\\n\\*+ ", bound: high, caseInsensitive: false) {
                    buffer.point = match[0]!.lowerBound + 1
                    return true
                }
                buffer.point = high
                return false
            }
            func previousLineEmpty() -> Bool {
                guard buffer.point > low else { return false }
                let start = buffer.lineStart(buffer.point)
                guard start > low else { return false }
                let previous = max(low, buffer.lineStart(start - 1))
                return buffer.substring(previous, start - 1).allSatisfy { $0 == " " || $0 == "\t" }
            }
            if headingStart(before: buffer.point) == nil {
                guard nextHeading() else { return false }
            }
            guard let heading = headingStart(before: buffer.point) else { return false }
            buffer.point = heading
            if buffer.point != low { return previousLineEmpty() }
            if nextHeading() { return previousLineEmpty() }
            while buffer.point > low, let c = buffer.character(at: buffer.point - 1), c == 32 || c == 9 { buffer.point -= 1 }
            return buffer.bolp ? previousLineEmpty() : false
        }
    }
}
