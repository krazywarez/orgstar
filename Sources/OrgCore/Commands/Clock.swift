import Foundation

// Clocking (org-clock.el, Org 9.8.7) with `org-clock-into-drawer` t (a LOGBOOK drawer),
// `org-log-states-order-reversed` t (newest first), no rounding, no resume, and zero-time
// clocks kept.

extension EmacsBuffer {
    static let clockDrawer = "LOGBOOK"
    static let openClockPattern = "^[ \\t]*CLOCK: \\[([0-9]{4}-[0-9]{2}-[0-9]{2} *[^\\]\\s]+ +[012][0-9]:[0-5][0-9])\\][ \\t]*$"

    /// `org-clock-find-position` without `find-unclosed`.
    func clockFindPosition() throws {
        let beg = try backToHeading()
        let end = saveExcursion { () -> Int in
            _ = outlineNextHeading()
            return point
        }
        let drawerPattern = "^[ \\t]*:" + Self.clockDrawer + ":[ \\t]*$"
        point = beg
        while let match = searchForward(drawerPattern, bound: end, caseInsensitive: false) {
            if element(at: lineStart(match[0]!.lowerBound))?.kind == .drawer {
                point = match[0]!.upperBound
                forwardLine(1)
                return
            }
        }
        point = beg
        var positions: [Int] = []
        saveExcursion {
            while let match = searchForward("^[ \\t]*CLOCK:", bound: end, caseInsensitive: false) {
                if element(at: lineStart(match[0]!.lowerBound))?.kind == .clock { positions.insert(lineStart(match[0]!.lowerBound), at: 0) }
            }
        }
        if positions.isEmpty {
            endOfMetaData()
            if !bolp { insertBeforeMarkers("\n") }
            insertBeforeMarkers(":" + Self.clockDrawer + ":\n:END:\n")
            forwardLine(-1)
            return
        }
        // Clocks outside a drawer move into a new one.
        endOfMetaData()
        let start = point
        var moved: [String] = []
        for position in positions {
            let lineStartOffset = position
            let next = min(length, lineEnd(lineStartOffset) + 1)
            var from = lineStartOffset
            while from > 0, let c = character(at: from - 1), c == 32 || c == 9 || c == 10 || c == 13 { from -= 1 }
            from = min(length, lineEnd(from) + 1)
            if from > lineStartOffset { from = lineStartOffset }
            let text = substring(from, next).trimmingCharacters(in: .whitespacesAndNewlines)
            deleteRegion(from, next)
            moved.append(text)
        }
        point = min(start, length)
        insert(moved.joined(separator: "\n") + "\n:END:\n")
        let endMarker = marker(point)
        defer { release(endMarker) }
        point = start
        saveExcursion { insertBeforeMarkers(":" + Self.clockDrawer + ":\n") }
        forwardLine(1)
    }

    /// `org-clock-in` on the heading at point. Returns the clock's start stamp.
    @discardableResult
    func clockIn() throws -> String {
        let start = point
        let pointMarker = marker(start)
        defer {
            point = pointMarker.position
            release(pointMarker)
        }
        if eobp, !atHeadingLine { point = lineStart(max(0, lineStart(point) - 1)) }
        try clockFindPosition()
        insertBeforeMarkers("\n")
        point -= 1
        if point > 0, saveExcursion({ () -> Int? in
            point = lineStart(point) - 1
            return point >= 0 ? inItem() : nil
        }) != nil {
            beginningOfLine()
            let current = substring(point, lineEnd(point)).prefix { $0 == " " || $0 == "\t" }.count
            indentLineTo(max(0, current - 2))
        }
        insert("CLOCK: ")
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let stamp = insertTimestamp(components, withTime: true, inactive: true)
        // `org-indent-line` puts lines in a drawer at column 0 without adapted indentation.
        let lineText = substring(lineStart(point), lineEnd(point))
        let indent = lineText.prefix { $0 == " " || $0 == "\t" }.count
        if indent > 0 { deleteRegion(lineStart(point), lineStart(point) + indent) }
        return String(stamp.dropFirst().dropLast())
    }

    var atHeadingLine: Bool { lookingAtLine("^\\*+ ") }

    /// The running clock's line: `CLOCK: [start]` with nothing after it.
    func runningClockLine(_ start: String) -> Int? {
        let pattern = "^[ \\t]*CLOCK: \\[" + NSRegularExpression.escapedPattern(for: start) + "\\][ \\t]*$"
        return saveExcursion {
            point = 0
            return searchForward(pattern, caseInsensitive: false).map { lineStart($0[0]!.lowerBound) }
        }
    }

    /// `org-clock-out` for the clock that started at `start`.
    func clockOut(_ start: String) throws {
        guard let line = runningClockLine(start) else { throw UserError(message: "Clock start time is gone") }
        point = line
        guard let match = looking("[ \\t]*CLOCK: \\[([^\\]]+)\\]", caseInsensitive: false) else { throw UserError(message: "Clock start time is gone") }
        point = match[0]!.upperBound
        deleteRegion(point, lineEnd(point))
        insert("--")
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let end = insertTimestamp(components, withTime: true, inactive: true)
        guard let startTime = Self.parseTimeString(start), let endTime = Self.parseTimeString(String(end.dropFirst().dropLast())),
              let a = calendar.date(from: startTime), let b = calendar.date(from: endTime) else { throw UserError(message: "Clock start time is gone") }
        let seconds = Int(b.timeIntervalSince(a))
        let hours = Int((Double(seconds) / 3600).rounded(.down))
        let minutes = Int((Double(seconds - hours * 3600) / 60).rounded(.down))
        insert(" => " + String(format: "%2d:%02d", hours, minutes))
        removeEmptyClockDrawer()
    }

    /// `org-clock-cancel`: the running clock's line goes, and the drawer if it empties.
    func clockCancel(_ start: String) throws {
        guard let line = runningClockLine(start) else { throw UserError(message: "No active clock") }
        point = lineEnd(line)
        let from = max(0, line - 1)
        deleteRegion(from, lineEnd(line))
        point = from
        removeEmptyDrawer(at: point)
    }

    /// `org-clock-remove-empty-clock-drawer` for the subtree at point.
    func removeEmptyClockDrawer() {
        saveExcursion {
            guard let heading = try? backToHeading() else { return }
            let end = saveExcursion { () -> Int in
                point = heading
                return endOfSubtree()
            }
            point = heading
            let pattern = "(?i)^[ \\t]*:" + Self.clockDrawer + ":[ \\t]*$"
            while let match = searchForward(pattern, bound: end, caseInsensitive: true) {
                removeEmptyDrawer(at: match[0]!.upperBound)
            }
        }
    }

    /// `org-remove-empty-drawer-at`.
    func removeEmptyDrawer(at position: Int) {
        let lineStartOffset = lineStart(min(position, length))
        let line = substring(lineStartOffset, lineEnd(lineStartOffset))
        guard line.trimmingCharacters(in: .whitespaces).range(of: "^:[\\w-]+:$", options: .regularExpression) != nil,
              line.trimmingCharacters(in: .whitespaces).uppercased() != ":END:" else { return }
        let next = min(length, lineEnd(lineStartOffset) + 1)
        let following = substring(next, lineEnd(next))
        guard following.trimmingCharacters(in: .whitespaces).uppercased() == ":END:" else { return }
        deleteRegion(lineStartOffset, min(length, lineEnd(next) + 1))
    }
}

/// C-c C-x C-i: `org-clock-in` at the heading at the caret.
public struct ClockIn: OrgCommand {
    public init() {}
    public var id: String { "org.clock.in" }
    public var title: String { "Clock In" }
    public func applies(in context: EditContext) -> Bool { entryHeading(at: context.caret, in: context.tree) != nil }
    public func run(in context: EditContext) -> CommandStep {
        guard entryHeading(at: context.caret, in: context.tree) != nil else { return .failed("Before first headline") }
        return commitBuffer(context) { try $0.clockIn() }
    }

    /// The start of the clock `ClockIn` left running in the entry at `offset`.
    public static func runningStart(in text: String, near offset: Int) -> String? {
        let buffer = EmacsBuffer(text, point: offset)
        guard let heading = try? buffer.backToHeading() else { return nil }
        let end = buffer.saveExcursion { () -> Int in
            _ = buffer.outlineNextHeading()
            return buffer.point
        }
        buffer.point = heading
        guard let match = buffer.searchForward(EmacsBuffer.openClockPattern, bound: end, caseInsensitive: false) else { return nil }
        return buffer.substring(match[1]!.lowerBound, match[1]!.upperBound)
    }
}

/// C-c C-x C-o and C-c C-x C-q for the clock that started at `start`.
public struct ClockOut: OrgCommand {
    public let start: String
    public let cancel: Bool
    public init(start: String, cancel: Bool = false) {
        self.start = start
        self.cancel = cancel
    }
    public var id: String { cancel ? "org.clock.cancel" : "org.clock.out" }
    public var title: String { cancel ? "Cancel Clock" : "Clock Out" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep {
        commitBuffer(context) { buffer in
            try buffer.saveExcursion {
                if cancel { try buffer.clockCancel(start) } else { try buffer.clockOut(start) }
            }
        }
    }
}
