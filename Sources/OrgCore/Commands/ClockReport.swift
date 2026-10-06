import Foundation

/// Time spent per day and heading, from finished `CLOCK:` lines.
public enum ClockReport {
    public struct Entry: Sendable, Equatable {
        /// `YYYY-MM-DD` of the clock's start.
        public let date: String
        /// The heading's title, without keyword, priority, tags or COMMENT.
        public let heading: String
        public let minutes: Int
        /// Where the heading starts.
        public let start: Int
    }

    static let clockLine = try! NSRegularExpression(pattern:
        "CLOCK: \\[([0-9]{4}-[0-9]{2}-[0-9]{2}) [A-Za-z]{3} [0-9:]{5}\\]--\\[([0-9]{4}-[0-9]{2}-[0-9]{2}) [A-Za-z]{3} ([0-9:]{5})\\] => +([0-9]+):([0-9]+)"
    )

    /// The finished clocks in `text`, in order.
    public static func entries(_ text: String, settings: OrgSettings = .default) -> [Entry] {
        let tree = OrgParser.parse(text, defaults: settings)
        let model = DocumentModel(tree: tree)
        let starts = model.headings.map(\.headingRange.lowerBound)
        let ns = text as NSString
        var result: [Entry] = []
        for m in clockLine.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var low = 0
            var high = starts.count
            while low < high {
                let mid = (low + high) / 2
                if starts[mid] <= m.range.location { low = mid + 1 } else { high = mid }
            }
            guard low > 0 else { continue }
            var title = model.headings[low - 1].title.trimmingCharacters(in: .whitespaces)
            if title == "COMMENT" { title = "" } else if title.hasPrefix("COMMENT ") { title = String(title.dropFirst(8)) }
            let minutes = Int(ns.substring(with: m.range(at: 4)))! * 60 + Int(ns.substring(with: m.range(at: 5)))!
            result.append(Entry(date: ns.substring(with: m.range(at: 1)), heading: title, minutes: minutes, start: starts[low - 1]))
        }
        return result
    }

    /// Minutes per heading between `from` and `to` (inclusive, `YYYY-MM-DD`), in file order.
    public static func byHeading(_ entries: [Entry], from: String? = nil, to: String? = nil) -> [(start: Int, heading: String, minutes: Int)] {
        var totals: [Int: (heading: String, minutes: Int)] = [:]
        for entry in entries {
            if let from, entry.date < from { continue }
            if let to, entry.date > to { continue }
            totals[entry.start, default: (entry.heading, 0)].minutes += entry.minutes
        }
        return totals.keys.sorted().map { (start: $0, heading: totals[$0]!.heading, minutes: totals[$0]!.minutes) }
    }

    public static func hours(_ minutes: Int) -> String { String(format: "%d:%02d", minutes / 60, minutes % 60) }

    /// Emacs `format "%-Ns"` pads by characters.
    static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    static func padLeft(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
    }

    /// `%Y-W%V`.
    static func isoWeek(_ date: String) -> String {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return date }
        let day = Days.absolute(year: parts[0], month: parts[1], day: parts[2])
        let thursday = day - (Days.weekday(day) + 6) % 7 + 3
        return String(format: "%04d-W%02d", Days.date(thursday).year, Days.isoWeek(day))
    }

    /// The time report your Doom configuration writes (`tr/generate-report`): minutes per
    /// date and heading between `start` and `end` (inclusive, `YYYY-MM-DD`), with a total
    /// after each ISO week.
    public static func timeReport(_ entries: [Entry], start: String? = nil, end: String? = nil) -> String {
        var totals: [String: [String: Int]] = [:]
        for entry in entries {
            if let start, entry.date < start { continue }
            if let end, entry.date > end { continue }
            totals[entry.date, default: [:]][entry.heading, default: 0] += entry.minutes
        }
        var keys: [(date: String, heading: String)] = []
        for (date, headings) in totals {
            for heading in headings.keys { keys.append((date, heading)) }
        }
        keys.sort { a, b in a.date != b.date ? a.date < b.date : a.heading < b.heading }
        let dashes14 = String(repeating: "-", count: 14)
        let dashes47 = String(repeating: "-", count: 47)
        let dashes7 = String(repeating: "-", count: 7)
        let rule: String = "|" + dashes14 + "+" + dashes47 + "+" + dashes7 + "|\n"
        func row(_ a: String, _ b: String, _ c: String) -> String { "| \(pad(a, 12)) | \(pad(b, 45)) | \(padLeft(c, 5)) |\n" }
        var out = "#+title: Time Report\n\n" + row("Date", "Code", "Hours") + rule
        var currentWeek: String?
        var weekMinutes = 0
        for (date, heading) in keys {
            let minutes = totals[date]![heading]!
            let week = isoWeek(date)
            if let current = currentWeek, week != current {
                out += rule + row(current, "WEEK TOTAL", hours(weekMinutes)) + rule
                weekMinutes = 0
            }
            if week != currentWeek {
                currentWeek = week
                weekMinutes = 0
            }
            weekMinutes += minutes
            out += row(date, heading, hours(minutes))
        }
        if let current = currentWeek {
            out += rule + row(current, "WEEK TOTAL", hours(weekMinutes))
        }
        return out + "\n"
    }
}
