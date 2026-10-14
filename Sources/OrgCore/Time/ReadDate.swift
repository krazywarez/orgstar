import Foundation

/// Org's date prompt (`org-read-date-analyze`, Org 9.8.7) and the `parse-time-string` it uses,
/// with `org-read-date-prefer-future` t. `now` and `defaultDate` stand in for the clock.
public enum ReadDate {
    public struct Answer: Sendable, Equatable {
        public var year: Int, month: Int, day: Int, hour: Int, minute: Int
        /// The answer included a time (`org-time-was-given`).
        public var timeGiven: Bool
        /// An end time such as `11:00`, from `10:00-11:00` (`org-end-time-was-given`).
        public var endTime: String?

        /// Normalized like `encode-time` (day 32 becomes the next month).
        public func components(_ calendar: Calendar) -> DateComponents {
            var components = DateComponents(year: year, month: month, day: 1, hour: 0, minute: 0)
            let base = calendar.date(from: components)!
            let date = calendar.date(byAdding: DateComponents(month: 0, day: day - 1, hour: hour, minute: minute), to: base)!
            components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
            return components
        }
    }

    static let weekdays: [(String, Int)] = [
        ("sun", 0), ("mon", 1), ("tue", 2), ("wed", 3), ("thu", 4), ("fri", 5), ("sat", 6),
        ("sunday", 0), ("monday", 1), ("tuesday", 2), ("wednesday", 3), ("thursday", 4), ("friday", 5), ("saturday", 6),
    ]
    static let months: [(String, Int)] = [
        ("jan", 1), ("feb", 2), ("mar", 3), ("apr", 4), ("may", 5), ("jun", 6), ("jul", 7), ("aug", 8), ("sep", 9),
        ("oct", 10), ("nov", 11), ("dec", 12), ("january", 1), ("february", 2), ("march", 3), ("april", 4), ("june", 6),
        ("july", 7), ("august", 8), ("september", 9), ("october", 10), ("november", 11), ("december", 12),
    ]

    enum Token: Equatable {
        case number(Int)
        case word(String)
    }

    /// `parse-time-tokenize` on the downcased string.
    static func tokenize(_ string: String) -> [Token] {
        let chars = Array(string.lowercased().unicodeScalars)
        func kind(_ c: Unicode.Scalar) -> Character? {
            switch c {
            case "a"..."z": "a"
            case "0"..."9": "0"
            case "+", "-", ":": Character(c)
            default: nil
            }
        }
        var tokens: [Token] = []
        var index = 0
        while index < chars.count {
            while index < chars.count, kind(chars[index]) == nil { index += 1 }
            guard index < chars.count else { break }
            let start = index
            var digits = kind(chars[index]) == "0"
            index += 1
            while index < chars.count, let k = kind(chars[index]) {
                digits = digits && k == "0"
                index += 1
            }
            let text = String(String.UnicodeScalarView(chars[start..<index]))
            tokens.append(digits ? .number(Int(text) ?? 0) : .word(text))
        }
        return tokens
    }

    /// `parse-time-string`'s fallback: (sec, min, hour, day, month, year, weekday).
    static func parseTime(_ string: String) -> [Int?] {
        var time: [Int?] = Array(repeating: nil, count: 9)
        func digits(_ text: String, _ range: Range<Int>) -> Int? {
            let chars = Array(text)
            guard range.upperBound <= chars.count else { return nil }
            return Int(String(chars[range]))
        }
        for token in tokenize(string) {
            if time[6] == nil, case .word(let w) = token, let day = weekdays.first(where: { $0.0 == w }) {
                time[6] = day.1
            } else if time[3] == nil, case .number(let n) = token, (1...31).contains(n) {
                time[3] = n
            } else if time[4] == nil, case .word(let w) = token, let month = months.first(where: { $0.0 == w }) {
                time[4] = month.1
            } else if time[5] == nil, case .number(let n) = token, n >= 100 {
                time[5] = n
            } else if time[2] == nil, case .word(let w) = token, w.count == 8, Array(w)[2] == ":", Array(w)[5] == ":" {
                (time[2], time[1], time[0]) = (digits(w, 0..<2), digits(w, 3..<5), digits(w, 6..<8))
            } else if time[5] == nil, case .word(let w) = token, w.count == 10, Array(w)[4] == "-", Array(w)[7] == "-" {
                (time[5], time[4], time[3]) = (digits(w, 0..<4), digits(w, 5..<7), digits(w, 8..<10))
            } else if time[2] == nil, case .word(let w) = token, w.count == 5, Array(w)[2] == ":" {
                (time[2], time[1], time[0]) = (digits(w, 0..<2), digits(w, 3..<5), 0)
            } else if time[2] == nil, case .word(let w) = token, w.count == 4, Array(w)[1] == ":" {
                (time[2], time[1], time[0]) = (digits(w, 0..<1), digits(w, 2..<4), 0)
            } else if time[2] == nil, case .word(let w) = token, w.count == 7, Array(w)[1] == ":" {
                (time[2], time[1], time[0]) = (digits(w, 0..<1), digits(w, 2..<4), digits(w, 5..<7))
            } else if time[5] == nil, case .number(let n) = token, (50...110).contains(n) {
                time[5] = 1900 + n
            } else if time[5] == nil, case .number(let n) = token, (0...49).contains(n) {
                time[5] = 2000 + n
            }
        }
        return time
    }

    /// `org-small-year-to-year`.
    static func smallYear(_ year: Int, currentYear: Int) -> Int {
        guard year < 100 else { return year }
        let century = currentYear / 100
        let offset = year - currentYear % 100
        if offset > 30 { return (century - 1) * 100 + year }
        if offset > -70 { return century * 100 + year }
        return (century + 1) * 100 + year
    }

    /// Replaces the first match of `pattern` in `string`, with `$n` group references.
    private static func replaceFirst(_ string: inout String, _ match: NSTextCheckingResult, _ template: String) {
        let ns = string as NSString
        var result = ""
        var chars = Array(template)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count, let n = chars[i + 1].wholeNumberValue {
                let range = match.range(at: n)
                if range.location != NSNotFound { result += ns.substring(with: range) }
                i += 2
            } else {
                result.append(chars[i])
                i += 1
            }
        }
        chars = []
        string = ns.replacingCharacters(in: match.range, with: result)
    }

    private static func firstMatch(_ pattern: String, _ string: String, caseInsensitive: Bool = false) -> NSTextCheckingResult? {
        let regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        return regex.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length))
    }

    private static func group(_ match: NSTextCheckingResult, _ i: Int, _ string: String) -> String? {
        let range = match.range(at: i)
        return range.location == NSNotFound ? nil : (string as NSString).substring(with: range)
    }

    /// `org-read-date-get-relative`: (shift, unit, relative to the default).
    static func relative(_ string: String, today: DateComponents, default def: DateComponents) -> (Int, String, Bool, NSTextCheckingResult)? {
        let names = weekdays.map(\.0).joined(separator: "|")
        guard let match = firstMatch("^[ \\t]*([-+]{0,2})([0-9]+)?([hdwmy]|(" + names + "))?([ \\t]|$)", string, caseInsensitive: true) else { return nil }
        let sign = group(match, 1, string) ?? ""
        guard !sign.isEmpty || match.range(at: 4).location != NSNotFound else { return nil }
        let direction: Character = sign.last ?? "+"
        let relativeToDefault = sign.count == 2
        let n = group(match, 2, string).flatMap { Int($0) } ?? 1
        let what = group(match, 3, string) ?? "d"
        let date = relativeToDefault ? def : today
        if let target = weekdays.first(where: { $0.0 == what.lowercased() })?.1 {
            let weekday = (date.weekday ?? 1) - 1
            var delta = (7 + target - weekday) % 7
            if delta == 0 { delta = 7 }
            if direction == "-" {
                delta -= 7
                if delta == 0 { delta = -7 }
            }
            if n > 1 { delta += (n - 1) * (direction == "-" ? -7 : 7) }
            return (delta, "d", relativeToDefault, match)
        }
        return (n * (direction == "-" ? -1 : 1), what, relativeToDefault, match)
    }

    /// Words orgstar reads that Org's prompt ignores, and the relative forms they stand for.
    /// Rewritten before analysis, so a time after them still counts (`tomorrow 14:00`).
    static let words: [(String, String)] = [
        ("next week", "+1w"), ("last week", "-1w"), ("today", "+0"), ("tomorrow", "+1"), ("yesterday", "-1"),
    ]

    static func expandWords(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        for (word, form) in words where lower == word || lower.hasPrefix(word + " ") {
            return form + trimmed.dropFirst(word.count)
        }
        return input
    }

    /// `org-read-date`'s reading of a prompt answer: an empty one takes the default date.
    public static func read(_ answer: String, default defaultDate: Date?, now: Date, calendar: Calendar) -> Answer {
        let def = defaultDate ?? now
        var input = expandWords(answer)
        if input.trimmingCharacters(in: .whitespaces).isEmpty {
            let c = calendar.dateComponents([.year, .month, .day], from: def)
            input = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        }
        return analyze(input, default: def, now: now, calendar: calendar)
    }

    /// `org-read-date-analyze` with `org-read-date-prefer-future` t.
    public static func analyze(_ input: String, default defaultDate: Date, now: Date, calendar: Calendar) -> Answer {
        let units: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second, .weekday]
        let def = calendar.dateComponents(units, from: defaultDate)
        let today = calendar.dateComponents(units, from: now)
        let currentYear = today.year!
        var ans = input
        if firstMatch("^[ \\t]*\\.[ \\t]*$", ans) != nil { ans = "+0" }
        var delta: (Int, String, Bool)?
        if let relative = relative(ans, today: today, default: def) {
            delta = (relative.0, relative.1, relative.2)
            ans = (ans as NSString).replacingCharacters(in: relative.3.range, with: "")
        }
        var isoYear: Int?, isoWeekday: Int?, isoWeek: Int?
        if let match = firstMatch("\\b(?:([0-9]+)-)?[wW]([0-9]{1,2})(?:-([0-6]))?([ \\t]|$)", ans) {
            isoYear = group(match, 1, ans).flatMap { Int($0) }.map { smallYear($0, currentYear: currentYear) }
            isoWeekday = group(match, 3, ans).flatMap { Int($0) }
            isoWeek = group(match, 2, ans).flatMap { Int($0) }
            ans = (ans as NSString).replacingCharacters(in: match.range, with: "")
        }
        var killYear = false
        if let match = firstMatch("^ *(([0-9]+)-)?([0-1]?[0-9])-([0-3]?[0-9])([^-0-9]|$)", ans) {
            var year = group(match, 2, ans).flatMap { Int($0) } ?? { killYear = true; return currentYear }()
            year = smallYear(year, currentYear: currentYear)
            let month = Int(group(match, 3, ans)!)!, day = Int(group(match, 4, ans)!)!
            replaceFirst(&ans, match, String(format: "%04d-%02d-%02d", year, month, day) + "\\5")
        }
        if let match = firstMatch("^ *(3[01]|0?[1-9]|[12][0-9])\\. ?(0?[1-9]|1[012])\\.( ?[1-9][0-9]{3})?", ans) {
            let year = group(match, 3, ans).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? { killYear = true; return currentYear }()
            let day = Int(group(match, 1, ans)!)!, month = Int(group(match, 2, ans)!)!
            replaceFirst(&ans, match, String(format: "%04d-%02d-%02d", year, month, day))
        }
        if let match = firstMatch("^ *(0?[1-9]|1[012])/(0?[1-9]|[12][0-9]|3[01])(/([0-9]+))?([^/0-9]|$)", ans) {
            var year = group(match, 4, ans).flatMap { Int($0) } ?? { killYear = true; return currentYear }()
            year = smallYear(year, currentYear: currentYear)
            let month = Int(group(match, 1, ans)!)!, day = Int(group(match, 2, ans)!)!
            replaceFirst(&ans, match, String(format: "%04d-%02d-%02d", year, month, day) + "\\5")
        }
        let plainTime = "(^|[^+])[012]?[0-9]:[0-9][0-9]([ \\t\\n]|$)"
        for _ in 0..<2 where firstMatch(plainTime, ans) == nil {
            guard let match = firstMatch("([012]?[0-9])(:([0-5][0-9]))?(am|AM|pm|PM)\\b", ans) else { break }
            var hour = Int(group(match, 1, ans)!)!
            let minute = group(match, 3, ans).flatMap { Int($0) } ?? 0
            let pm = group(match, 4, ans)!.lowercased() == "pm"
            if hour == 12, !pm { hour = 0 } else if pm, hour < 12 { hour += 12 }
            ans = (ans as NSString).replacingCharacters(in: match.range, with: String(format: "%02d:%02d", hour, minute))
        }
        for _ in 0..<2 where firstMatch(plainTime, ans) == nil {
            guard let match = firstMatch("(?:([012]?[0-9])?h([0-5][0-9]))|(?:([012]?[0-9])h([0-5][0-9])?)\\b", ans) else { break }
            let hour = (group(match, 1, ans) ?? group(match, 3, ans)).flatMap { Int($0) } ?? 0
            let minute = (group(match, 2, ans) ?? group(match, 4, ans)).flatMap { Int($0) } ?? 0
            ans = (ans as NSString).replacingCharacters(in: match.range, with: String(format: "%02d:%02d", hour, minute))
        }
        if let match = firstMatch("([012]?[0-9]):([0-6][0-9])\\+([012]?[0-9])(:([0-5][0-9]))?", ans) {
            let hour = Int(group(match, 1, ans)!)!, minute = Int(group(match, 2, ans)!)!
            var h2 = hour + Int(group(match, 3, ans)!)!
            var m2 = minute + (group(match, 5, ans).flatMap { Int($0) } ?? 0)
            if m2 >= 60 { h2 += 1; m2 -= 60 }
            ans = (ans as NSString).replacingCharacters(in: match.range, with: String(format: "%02d:%02d-%02d:%02d", hour, minute, h2, m2))
        }
        var timeGiven = false
        var endTime: String?
        let timeOfDay = "(\\b[012]?[0-9]((:([0-5][0-9]([AaPp][Mm])?))|([AaPp][Mm]))\\b)(--?(\\b[012]?[0-9]((:([0-5][0-9]([AaPp][Mm])?))|([AaPp][Mm]))\\b))?"
        if let match = firstMatch(timeOfDay, ans), let end = group(match, 8, ans) {
            endTime = end
            let range = match.range(at: 7)
            ans = (ans as NSString).replacingCharacters(in: range, with: "")
        }
        let tl = parseTime(ans)
        var futurep = false
        var day = tl[3] ?? def.day!
        let month: Int
        if let m = tl[4] {
            month = m
        } else if tl[3] != nil {
            futurep = true
            month = day < today.day! ? today.month! + 1 : today.month!
        } else {
            month = def.month!
        }
        var year: Int
        if !killYear, let y = tl[5] {
            year = y
        } else if futurep {
            year = (month > today.month! || day >= today.day!) ? today.year! : today.year! + 1
        } else if tl[4] != nil {
            futurep = true
            if month > today.month! { year = today.year! } else if month < today.month! { year = today.year! + 1 } else if day < today.day! { year = today.year! + 1 } else { year = today.year! }
        } else {
            year = def.year!
        }
        var month2 = month
        var hour = tl[2] ?? def.hour!
        let minute = tl[1] ?? def.minute!
        var wday = tl[6]
        if let isoWeek {
            let isoYearValue = isoYear ?? year
            let weekday = isoWeekday ?? wday ?? 1
            wday = nil
            var iso = Calendar(identifier: .iso8601)
            iso.timeZone = calendar.timeZone
            let isoComponents = DateComponents(weekday: weekday == 0 ? 1 : weekday + 1, weekOfYear: isoWeek, yearForWeekOfYear: isoYearValue)
            if let date = iso.date(from: isoComponents) {
                let c = iso.dateComponents([.year, .month, .day], from: date)
                (year, month2, day) = (c.year!, c.month!, c.day!)
            }
        } else if let (n, unit, relativeToDefault) = delta {
            if !relativeToDefault { (day, month2, year) = (today.day!, today.month!, today.year!) }
            switch unit.lowercased() {
            case "h", "":
                timeGiven = true
                hour += n
            case "d": day += n
            case "w": day += 7 * n
            case "m": month2 += n
            case "y": year += n
            default: break
            }
        } else if let target = wday, tl[3] == nil {
            let base = calendar.date(from: DateComponents(year: year, month: month2, day: 1))!
            let date = calendar.date(byAdding: .day, value: day - 1, to: base)!
            let current = calendar.component(.weekday, from: date) - 1
            if target != current { day += ((target - current + 7) % 7 + 7) % 7 }
        }
        if tl[2] != nil { timeGiven = true }
        if year < 100 { year += 2000 }
        _ = futurep
        return Answer(year: year, month: month2, day: day, hour: hour, minute: minute, timeGiven: timeGiven, endTime: endTime)
    }
}
