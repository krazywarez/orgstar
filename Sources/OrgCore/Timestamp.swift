public struct Timestamp: Sendable, Equatable {
    public enum Unit: Character, Sendable {
        case hour = "h", day = "d", week = "w", month = "m", year = "y"
    }

    public struct Interval: Sendable, Equatable {
        public var value: Int
        public var unit: Unit
    }

    public enum RepeaterKind: String, Sendable {
        case cumulate = "+", catchUp = "++", restart = ".+"
    }

    public struct Repeater: Sendable, Equatable {
        public var kind: RepeaterKind
        public var interval: Interval
        /// The habit deadline from `.+2d/3d`.
        public var habitDeadline: Interval?
    }

    public struct Warning: Sendable, Equatable {
        /// `--` warns only for the first occurrence of a repeated timestamp.
        public var firstOccurrenceOnly: Bool
        public var interval: Interval
    }

    public struct Point: Sendable, Equatable {
        public var year: Int
        public var month: Int
        public var day: Int
        public var hour: Int?
        public var minute: Int?
    }

    public var active: Bool
    public var start: Point
    /// End of a same-day time range or of a `--` date range.
    public var end: Point?
    public var repeater: Repeater?
    public var warning: Warning?

    /// Parses exactly one timestamp or range, with nothing before or after it.
    public static func parse(_ text: some StringProtocol) -> Timestamp? {
        let chars = Array(text.unicodeScalars)
        guard let result = scanTimestamp(chars, at: 0, limit: chars.count), result.end == chars.count else { return nil }
        return result.stamp
    }
}

/// A timestamp or `--` range starting at `start`, and the index after it.
func scanTimestamp(_ chars: [Unicode.Scalar], at start: Int, limit: Int) -> (stamp: Timestamp, end: Int)? {
    guard let first = scanSingleTimestamp(chars, at: start, limit: limit) else { return nil }
    if first.stamp.end == nil, first.end + 2 < limit, chars[first.end] == "-", chars[first.end + 1] == "-",
       let second = scanSingleTimestamp(chars, at: first.end + 2, limit: limit),
       second.stamp.active == first.stamp.active, second.stamp.end == nil {
        var range = first.stamp
        range.end = second.stamp.start
        return (range, second.end)
    }
    return first
}

/// The end of the timestamp object at `start`. Org reads anything matching
/// `org-ts-regexp-both` as one, `<2026-10-07 Wed 9am>` included, so a timestamp `parse` rejects
/// is still an object.
func timestampEnd(_ chars: [Unicode.Scalar], at start: Int, limit: Int) -> Int? {
    if let strict = scanTimestamp(chars, at: start, limit: limit) { return strict.end }
    guard let first = lenientTimestampEnd(chars, at: start, limit: limit) else { return nil }
    if first + 2 < limit, chars[first] == "-", chars[first + 1] == "-",
       let second = lenientTimestampEnd(chars, at: first + 2, limit: limit) {
        return second
    }
    return first
}

/// `[[<]YYYY-MM-DD( .*?)?[]>]`.
private func lenientTimestampEnd(_ chars: [Unicode.Scalar], at start: Int, limit: Int) -> Int? {
    guard start + 11 < limit, chars[start] == "<" || chars[start] == "[" else { return nil }
    for (k, c) in "dddd-dd-dd".unicodeScalars.enumerated() {
        let actual = chars[start + 1 + k]
        guard c == "d" ? isASCIIDigit(actual) : actual == c else { return nil }
    }
    var j = start + 11
    if chars[j] == "]" || chars[j] == ">" { return j + 1 }
    guard chars[j] == " " else { return nil }
    j += 1
    while j < limit, chars[j] != "\n" {
        if chars[j] == "]" || chars[j] == ">" { return j + 1 }
        j += 1
    }
    return nil
}

/// `<YYYY-MM-DD DAY HH:MM-HH:MM REPEATER WARNING>`, or the same in `[...]` for inactive.
private func scanSingleTimestamp(_ chars: [Unicode.Scalar], at start: Int, limit: Int) -> (stamp: Timestamp, end: Int)? {
    guard start < limit, chars[start] == "<" || chars[start] == "[" else { return nil }
    let active = chars[start] == "<"
    let close: Unicode.Scalar = active ? ">" : "]"
    var j = start + 1

    func number(_ minDigits: Int, _ maxDigits: Int) -> Int? {
        var k = j
        while k < limit, k - j < maxDigits, isASCIIDigit(chars[k]) { k += 1 }
        guard k - j >= minDigits else { return nil }
        var value = 0
        for digit in chars[j..<k] { value = value * 10 + Int(digit.value - 48) }
        j = k
        return value
    }

    func take(_ c: Unicode.Scalar) -> Bool {
        guard j < limit, chars[j] == c else { return false }
        j += 1
        return true
    }

    func interval() -> Timestamp.Interval? {
        let before = j
        guard let value = number(1, 9), j < limit, let unit = Timestamp.Unit(rawValue: Character(chars[j])) else {
            j = before
            return nil
        }
        j += 1
        return Timestamp.Interval(value: value, unit: unit)
    }

    func repeater() -> Timestamp.Repeater? {
        let before = j
        let kind: Timestamp.RepeaterKind
        if j + 1 < limit, chars[j] == ".", chars[j + 1] == "+" {
            kind = .restart
            j += 2
        } else if j + 1 < limit, chars[j] == "+", chars[j + 1] == "+" {
            kind = .catchUp
            j += 2
        } else if take("+") {
            kind = .cumulate
        } else {
            return nil
        }
        guard let value = interval() else {
            j = before
            return nil
        }
        var deadline: Timestamp.Interval?
        if take("/") {
            deadline = interval()
            if deadline == nil {
                j = before
                return nil
            }
        }
        return Timestamp.Repeater(kind: kind, interval: value, habitDeadline: deadline)
    }

    func warning() -> Timestamp.Warning? {
        let before = j
        guard take("-") else { return nil }
        let firstOnly = take("-")
        guard let value = interval() else {
            j = before
            return nil
        }
        return Timestamp.Warning(firstOccurrenceOnly: firstOnly, interval: value)
    }

    guard let year = number(4, 4), take("-"), let month = number(2, 2), take("-"), let day = number(2, 2) else {
        return nil
    }
    var stamp = Timestamp(
        active: active,
        start: Timestamp.Point(year: year, month: month, day: day, hour: nil, minute: nil),
        end: nil, repeater: nil, warning: nil
    )

    // Day name: anything but digits, whitespace, `+`, `-`, `]` and `>`, in any language.
    if j < limit, chars[j] == " " {
        var k = j + 1
        while k < limit, !(isDigit(chars[k]) || chars[k].properties.isWhitespace || "+-]>".unicodeScalars.contains(chars[k])) { k += 1 }
        if k > j + 1 { j = k }
    }

    let beforeTime = j
    if take(" "), let hour = number(1, 2), take(":"), let minute = number(2, 2) {
        stamp.start.hour = hour
        stamp.start.minute = minute
        let beforeEnd = j
        if take("-"), let endHour = number(1, 2), take(":"), let endMinute = number(2, 2) {
            stamp.end = Timestamp.Point(year: year, month: month, day: day, hour: endHour, minute: endMinute)
        } else {
            j = beforeEnd
        }
    } else {
        j = beforeTime
    }

    while j < limit, chars[j] == " " {
        let beforeModifier = j
        j += 1
        if let value = repeater() {
            stamp.repeater = value
        } else if let value = warning() {
            stamp.warning = value
        } else {
            j = beforeModifier
            break
        }
    }

    guard take(close) else { return nil }
    return (stamp, j)
}

func isASCIIDigit(_ c: Unicode.Scalar) -> Bool {
    c.value >= 48 && c.value <= 57
}

/// Any numeric character, as `Character.isNumber` would see it in a day name.
func isDigit(_ c: Unicode.Scalar) -> Bool {
    c.properties.numericType != nil
}
