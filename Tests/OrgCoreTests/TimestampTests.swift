import Testing
@testable import OrgCore

struct TimestampTests {
    @Test func fullTimestamp() throws {
        let stamp = try #require(Timestamp.parse("<2026-10-04 Sun 10:00-11:30 .+1w/2w --2d>"))
        #expect(stamp.active)
        #expect(stamp.start == Timestamp.Point(year: 2026, month: 10, day: 4, hour: 10, minute: 0))
        #expect(stamp.end == Timestamp.Point(year: 2026, month: 10, day: 4, hour: 11, minute: 30))
        #expect(stamp.repeater == Timestamp.Repeater(
            kind: .restart,
            interval: .init(value: 1, unit: .week),
            habitDeadline: .init(value: 2, unit: .week)
        ))
        #expect(stamp.warning == Timestamp.Warning(firstOccurrenceOnly: true, interval: .init(value: 2, unit: .day)))
    }

    @Test func dateOnlyInactive() throws {
        let stamp = try #require(Timestamp.parse("[2026-10-04]"))
        #expect(!stamp.active)
        #expect(stamp.start.hour == nil)
    }

    @Test func dateRange() throws {
        let stamp = try #require(Timestamp.parse("[2026-10-04 Sun]--[2026-10-06 Tue]"))
        #expect(stamp.end?.day == 6)
    }

    @Test func repeaterKinds() {
        #expect(Timestamp.parse("<2026-10-04 +1d>")?.repeater?.kind == .cumulate)
        #expect(Timestamp.parse("<2026-10-04 ++1m>")?.repeater?.kind == .catchUp)
        #expect(Timestamp.parse("<2026-10-04 -3d +1y>")?.repeater?.interval == .init(value: 1, unit: .year))
    }

    @Test func oneDigitHourAndOtherLanguages() {
        #expect(Timestamp.parse("<2026-10-04 9:05>")?.start.hour == 9)
        #expect(Timestamp.parse("<2026-10-04 dim.>") != nil)
    }

    @Test(arguments: ["<2026-10-4>", "<2026-10-04 Sun", "[2026-10-04 Sun]x", "<2026-10-04 Sun +1x>", "<2026-10-04]", "2026-10-04"])
    func rejects(text: String) {
        #expect(Timestamp.parse(text) == nil)
    }
}
