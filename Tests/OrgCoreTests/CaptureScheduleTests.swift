import Testing
@testable import OrgCore

struct CaptureScheduleTests {
    static let day = Days.absolute(year: 2026, month: 10, day: 9)

    @Test func addsPlanningLineAfterHeading() {
        let text = "* TODO \n  body"
        let result = Capture.scheduling(text, cursor: 7, on: Self.day)
        #expect(result.text == "* TODO \nSCHEDULED: <2026-10-09 Fri>\n  body")
        #expect(result.cursor == 7)
    }

    @Test func headingAlone() {
        let result = Capture.scheduling("* TODO ", cursor: 7, on: Self.day)
        #expect(result.text == "* TODO \nSCHEDULED: <2026-10-09 Fri>")
        #expect(result.cursor == 7)
    }

    @Test func cursorInBodyMoves() {
        let text = "* TODO x\n"
        let result = Capture.scheduling(text, cursor: 9, on: Self.day)
        #expect(result.text == "* TODO x\nSCHEDULED: <2026-10-09 Fri>\n")
        #expect(result.cursor == 9 + 28)
    }

    @Test func joinsExistingPlanningLine() {
        let result = Capture.scheduling("* DONE x\nCLOSED: [2026-10-01 Thu]\n", cursor: 0, on: Self.day)
        #expect(result.text == "* DONE x\nCLOSED: [2026-10-01 Thu] SCHEDULED: <2026-10-09 Fri>\n")
    }

    @Test func leavesDatedAndNonEntries() {
        #expect(Capture.scheduling("* TODO x\n<2026-10-09 Fri>", cursor: 0, on: Self.day).text == "* TODO x\n<2026-10-09 Fri>")
        #expect(Capture.scheduling("- [ ] item", cursor: 0, on: Self.day).text == "- [ ] item")
    }
}
