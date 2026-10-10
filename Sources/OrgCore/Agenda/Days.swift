import Foundation

/// Calendar days as Emacs numbers them (`calendar-absolute-from-gregorian`): 1 is
/// 1 January of year 1, proleptic Gregorian.
public enum Days {
    static let hourRegex = try! NSRegularExpression(pattern: "^( +[^\\]+0-9>\\r\\n -]+)?( +([0-9]{1,2}):([0-9]{2}))")

    /// Out-of-range days and months roll over, as with `encode-time`.
    public static func absolute(year: Int, month: Int, day: Int) -> Int {
        let monthIndex = month - 1
        let y = year + Int((Double(monthIndex) / 12).rounded(.down))
        let m = monthIndex - 12 * Int((Double(monthIndex) / 12).rounded(.down)) + 1
        // Days from civil (Howard Hinnant), with 1970-01-01 = 0.
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468 + 719163 + day - 1
    }

    public static func date(_ absolute: Int) -> (year: Int, month: Int, day: Int) {
        let z = absolute - 719163 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    /// 0 is Sunday, as `calendar-day-of-week`.
    public static func weekday(_ absolute: Int) -> Int {
        ((absolute % 7) + 7) % 7
    }

    /// `org-days-to-iso-week`.
    public static func isoWeek(_ absolute: Int) -> Int {
        let monday = absolute - (weekday(absolute) + 6) % 7
        let thursday = monday + 3
        let year = date(thursday).year
        return (thursday - Days.absolute(year: year, month: 1, day: 1)) / 7 + 1
    }

    /// The day of a `Date` in `calendar`'s time zone.
    public static func absolute(_ date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return absolute(year: c.year!, month: c.month!, day: c.day!)
    }

    static let dateRegex = try! NSRegularExpression(pattern: "([0-9]{4})-([0-9]{2})-([0-9]{2})")
    static let timeRegex = try! NSRegularExpression(pattern: "([0-9]{1,2}):([0-9]{2})")

    /// `time-to-days` of `org-time-string-to-time`: the first date in the string.
    static func absolute(of string: String) -> Int? {
        let ns = string as NSString
        guard let m = dateRegex.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func int(_ i: Int) -> Int { Int(ns.substring(with: m.range(at: i)))! }
        return absolute(year: int(1), month: int(2), day: int(3))
    }

    /// The hour of `org-parse-time-string`, 0 when there is none.
    static func hour(of string: String) -> Int {
        let ns = string as NSString
        guard let date = dateRegex.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)) else { return 0 }
        let rest = NSRange(location: NSMaxRange(date.range), length: ns.length - NSMaxRange(date.range))
        // org-ts-regexp0: a day name may sit between the date and the time.
        let pattern = Self.hourRegex
        guard let m = pattern.firstMatch(in: string, range: rest) else { return 0 }
        return Int(ns.substring(with: m.range(at: 3)))!
    }

    public enum Prefer { case past, future, nearest }

    static let repeatRegex = try! NSRegularExpression(pattern: "\\+([0-9]+)([hdwmy])")

    /// `org-closest-date`: the occurrence of a repeating timestamp `start` closest to `current`.
    /// Timestamps without a repeater give their own day.
    static func closest(_ start: String, to current: Int, prefer: Prefer) -> Int? {
        guard let sday = absolute(of: start) else { return nil }
        let ns = start as NSString
        guard let m = repeatRegex.firstMatch(in: start, range: NSRange(location: 0, length: ns.length)) else { return sday }
        let value = Int(ns.substring(with: m.range(at: 1)))!
        let unit = ns.substring(with: m.range(at: 2))
        if value == 0 { return sday }
        let cday = current
        if cday <= sday { return sday }
        let base = date(sday)
        let target = date(cday)
        var n1: Int
        var n2: Int
        switch unit {
        case "h":
            let missing = mod(24 * (cday - sday) - hour(of: start), value)
            n1 = missing == 0 ? cday : cday - (1 + missing / 24)
            n2 = cday + (value - missing) / 24
        case "d", "w":
            let step = unit == "w" ? 7 * value : value
            n1 = sday + step * ((cday - sday) / step)
            n2 = n1 + step
        case "m":
            func add(_ d: (year: Int, month: Int, day: Int), _ n: Int) -> (year: Int, month: Int, day: Int) {
                (d.year, d.month + n, d.day)
            }
            let months = ((12 * (target.year - base.year) + (target.month - base.month) + (target.day > base.day ? 0 : -1)) / value) * value
            let before = add(base, months)
            n1 = absolute(year: before.year, month: before.month, day: before.day)
            let after = add(before, value)
            n2 = absolute(year: after.year, month: after.month, day: after.day)
        default:
            let later = target.month > base.month || (target.month == base.month && target.day > base.day)
            let years = ((target.year - base.year - (later ? 0 : 1)) / value) * value
            n1 = absolute(year: base.year + years, month: base.month, day: base.day)
            n2 = absolute(year: base.year + years + value, month: base.month, day: base.day)
        }
        switch prefer {
        case .past: return cday == n2 ? n2 : n1
        case .future: return cday == n1 ? n1 : n2
        case .nearest: return abs(cday - n1) > abs(cday - n2) ? n2 : n1
        }
    }

    private static func mod(_ a: Int, _ b: Int) -> Int { ((a % b) + b) % b }

    static let wdaysRegex = try! NSRegularExpression(pattern: "-([0-9]+)([hdwmy])(\\z|>| )")

    /// `org-get-wdays`: the warning days of a deadline, or with `delay` the delay days of a
    /// scheduled timestamp.
    static func warningDays(_ stamp: String, delay: Bool, defaultDays: Int) -> Int {
        let tv = defaultDays
        if (delay && tv < 0) || (!delay && tv <= 0) { return -tv }
        let ns = stamp as NSString
        guard let m = wdaysRegex.firstMatch(in: stamp, range: NSRange(location: 0, length: ns.length)) else { return tv }
        let n = Double(ns.substring(with: m.range(at: 1)))!
        let factor: Double = switch ns.substring(with: m.range(at: 2)) {
        case "d": 1
        case "w": 7
        case "m": 30.4
        case "y": 365.25
        default: 0.041667
        }
        return Int((n * factor).rounded(.down))
    }
}
