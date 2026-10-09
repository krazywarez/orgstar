import Foundation

/// The parts of an item's heading text the agenda rows show apart: the title alone, the
/// priority letter and the statistics cookie.
extension AgendaItem {
    static let priorityCookie = try! NSRegularExpression(pattern: "^\\[#([A-Z]|[0-9]+)\\][ \\t]*")
    static let statisticsCookie = try! NSRegularExpression(pattern: "\\[([0-9]*(?:%|/[0-9]*))\\]")
    static let anyTimestamp = try! NSRegularExpression(
        pattern: "<%%\\([^>\\n]*>|<[0-9]{4}-[0-9]{2}-[0-9]{2}[^>\\n]*>(?:--<[0-9]{4}-[0-9]{2}-[0-9]{2}[^>\\n]*>)?|\\[[0-9]{4}-[0-9]{2}-[0-9]{2}[^\\]\\n]*\\](?:--\\[[0-9]{4}-[0-9]{2}-[0-9]{2}[^\\]\\n]*\\])?"
    )

    /// `text` after the TODO keyword.
    private var afterKeyword: String {
        var t = Substring(text.trimmingCharacters(in: .whitespaces))
        if let todo, t.hasPrefix(todo), t.dropFirst(todo.count).first.map({ $0 == " " || $0 == "\t" }) ?? true {
            t = t.dropFirst(todo.count)
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// The heading's title without TODO keyword, priority cookie, statistics cookies,
    /// timestamps or tags, links as their descriptions, runs of spaces made one. The text itself
    /// when nothing is left.
    public var title: String {
        var t = afterKeyword
        t = Self.priorityCookie.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "")
        t = Self.statisticsCookie.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "")
        t = Self.anyTimestamp.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "")
        t = Links.displayFormat(t).replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? text.trimmingCharacters(in: .whitespaces) : t
    }

    /// The letter or number of the priority cookie (`[#A]`), when the heading has one.
    public var priorityLetter: String? {
        let t = afterKeyword
        guard let m = Self.priorityCookie.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) else { return nil }
        return (t as NSString).substring(with: m.range(at: 1))
    }

    /// The first statistics cookie's value: `1/3` or `50%`.
    public var progress: String? {
        let t = afterKeyword
        guard let m = Self.statisticsCookie.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) else { return nil }
        return (t as NSString).substring(with: m.range(at: 1))
    }
}

/// Ages and distances in days, compactly: under 14 days in days (`3d`), under 60 in whole
/// weeks (`2w`), under a year in 30-day months (`4mo`, at most 11), then years of 365 days with
/// any remaining months (`1y`, `1y 4mo`). Values round down; the sign is ignored.
public enum AgendaAge {
    public static func compact(_ days: Int) -> String {
        let d = abs(days)
        if d < 14 { return "\(d)d" }
        if d < 60 { return "\(d / 7)w" }
        if d < 365 { return "\(min(11, d / 30))mo" }
        let months = min(11, (d % 365) / 30)
        return months == 0 ? "\(d / 365)y" : "\(d / 365)y \(months)mo"
    }
}
