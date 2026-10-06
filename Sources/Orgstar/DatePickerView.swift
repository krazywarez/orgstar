import OrgCore
import SwiftUI

/// What `org-read-date` shows beside its prompt: the date the answer reads as, and a month
/// calendar to pick one by clicking.
struct DatePickerView: View {
    let answer: String
    let read: Prompt.DateRead
    let pick: (String) -> Void
    @State private var month: Date?
    private let calendar = Calendar.current

    var body: some View {
        let result = Self.result(answer, read)
        let selected = calendar.date(from: result.components(calendar))!
        let shown = month ?? selected
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { month = calendar.date(byAdding: .month, value: -1, to: shown) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous month")
                Text(shown.formatted(.dateTime.month(.wide).year())).frame(minWidth: 140)
                Button { month = calendar.date(byAdding: .month, value: 1, to: shown) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next month")
                Spacer()
                Text("=> " + Self.stamp(result, calendar)).font(.system(.callout, design: .monospaced))
            }
            .buttonStyle(.plain)
            Grid(horizontalSpacing: 4, verticalSpacing: 2) {
                GridRow {
                    ForEach(weekdaySymbols.indices, id: \.self) { Text(weekdaySymbols[$0]).foregroundStyle(.secondary) }
                }
                ForEach(weeks(of: shown), id: \.self) { week in
                    GridRow {
                        ForEach(week.indices, id: \.self) { i in
                            if let day = week[i] {
                                dayButton(day, selected: calendar.isDate(day, inSameDayAs: selected), result: result)
                            } else {
                                Color.clear.frame(width: 1, height: 1)
                            }
                        }
                    }
                }
            }
            .font(.system(.callout, design: .monospaced))
        }
        .padding(10)
        .onChange(of: selected) { month = nil }
    }

    private func dayButton(_ day: Date, selected: Bool, result: ReadDate.Answer) -> some View {
        Button {
            pick(Self.answer(for: day, keeping: result, calendar))
        } label: {
            Text("\(calendar.component(.day, from: day))")
                .frame(width: 26, height: 20)
                .background(selected ? Color.accentColor.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .overlay {
                    if calendar.isDateInToday(day) { RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// The month's days in weeks, nil before the first and after the last.
    private func weeks(of date: Date) -> [[Date?]] {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
        let count = calendar.range(of: .day, in: .month, for: start)!.count
        let lead = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        var days: [Date?] = Array(repeating: nil, count: lead)
        days += (0..<count).map { calendar.date(byAdding: .day, value: $0, to: start) }
        days += Array(repeating: nil, count: (7 - days.count % 7) % 7)
        return stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<$0 + 7]) }
    }

    static func result(_ answer: String, _ read: Prompt.DateRead) -> ReadDate.Answer {
        ReadDate.read(answer, default: read.defaultDate, now: Date(), calendar: .current)
    }

    /// The answer for `day`, with the time `result` had.
    static func answer(for day: Date, keeping result: ReadDate.Answer, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        var text = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        if result.timeGiven {
            text += String(format: " %02d:%02d", result.hour, result.minute)
            if let end = result.endTime { text += "-" + end }
        }
        return text
    }

    /// The answer moved by `days`, as S-arrows move `org-read-date`'s calendar.
    static func shifted(_ answer: String, _ read: Prompt.DateRead, by days: Int) -> String {
        let calendar = Calendar.current
        let result = result(answer, read)
        let day = calendar.date(byAdding: .day, value: days, to: calendar.date(from: result.components(calendar))!)!
        return Self.answer(for: day, keeping: result, calendar)
    }

    static func stamp(_ result: ReadDate.Answer, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = result.timeGiven ? "yyyy-MM-dd EEE HH:mm" : "yyyy-MM-dd EEE"
        let end = result.timeGiven ? result.endTime.map { "-" + $0 } ?? "" : ""
        return "<" + formatter.string(from: calendar.date(from: result.components(calendar))!) + end + ">"
    }
}
