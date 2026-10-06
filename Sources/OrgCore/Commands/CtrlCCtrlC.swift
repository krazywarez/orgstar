import Foundation

// C-c C-c (`org-ctrl-c-ctrl-c`, Org 9.8.7) for the contexts no more specific binding takes:
// headings set tags, clock lines get their duration again, timestamps their weekday, cookies
// update, items without a checkbox have their list repaired, setup keywords refresh, and
// elsewhere there's nothing to do.

/// `org-ctrl-c-ctrl-c`.
public struct CtrlCCtrlC: OrgCommand {
    public init() {}
    public var id: String { "org.ctrl-c-ctrl-c" }
    public var title: String { "Act at Point (C-c C-c)" }
    public func applies(in context: EditContext) -> Bool { true }

    static let nothing = CommandStep.failed("`C-c C-c' can do nothing useful here")

    public func run(in context: EditContext) -> CommandStep {
        let buffer = EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings, options: context.options)
        if KeyContext.holds("src", in: context) { return ExecuteSrcBlock().run(in: context) }
        if KeyContext.holds("table", in: context) || TableRecalculate.tblfmLine(in: context) != nil {
            // At the table's very start the context is the table itself, which org recalculates.
            let atStart = buffer.saveExcursion { buffer.tableBegin() } == context.caret
            return TableRecalculate.tblfmLine(in: context) != nil || atStart ? TableRecalculate(all: true).run(in: context) : commitBuffer(context) { buffer in
                try buffer.tableMaybeEvalFormula()
                buffer.tableAlign()
            }
        }
        if buffer.footnoteReferenceAtPoint() != nil
            || buffer.footnoteDefinitions().contains(where: { $0.begin <= context.caret && context.caret < ($0.contentsBegin ?? $0.end) }) {
            return FootnoteAction().run(in: context)
        }
        if buffer.lookingAtLine("^[ \\t]*$") { return Self.nothing }
        // On a clock line, changing a timestamp updates the clock too.
        if buffer.lookingAtLine("^[ \\t]*CLOCK:") { return commitBuffer(context) { $0.clockUpdateTime() } }
        if buffer.lookingAtLine(EmacsBuffer.dblockStart) { return UpdateDynamicBlock().run(in: context) }
        if Self.cookieAtCaret(buffer) {
            return commitBuffer(context) { buffer in
                buffer.saveExcursion {
                    buffer.point = buffer.lineStart(buffer.point)
                    buffer.updateStatisticsCookies()
                }
            }
        }
        if buffer.atTimestamp() != nil { return commitBuffer(context) { try $0.changeTimestamp(0, what: .day) } }
        if buffer.atHeading { return SetTags().run(in: context) }
        if buffer.atItem {
            // The item's checkbox toggles, and the whole list is repaired, its cookie updated.
            return commitBuffer(context) { buffer in
                buffer.point = buffer.lineStart(buffer.point)
                let item = buffer.point
                var structure = buffer.listStruct()
                let old = structure
                let box = structure.checkbox(item)
                if let box { structure.set(item) { $0.checkbox = box == "[X]" ? "[ ]" : "[X]" } }
                var repaired = structure
                buffer.writeStruct(&repaired, repaired.parents, old: old)
                if box != nil, repaired == old {
                    throw EmacsBuffer.UserError(message: "Cannot toggle this checkbox: \(box == "[X]" ? "all subitems checked" : "unchecked subitems")")
                }
                buffer.point = item
                buffer.updateCheckboxCount()
            }
        }
        if buffer.lookingAtLine("^[ \\t]*#\\+[A-Za-z_]+:") {
            return .commit(EditResult(baseRevision: context.revision, edits: [], effects: [.message("Local setup has been refreshed")]))
        }
        if buffer.lookingAtLine("^[ \\t]*:[^\\s:]+:") { return .failed("Property actions aren't supported yet") }
        return Self.nothing
    }

    /// A `[n/m]` or `[n%]` cookie holds the caret.
    static func cookieAtCaret(_ buffer: EmacsBuffer) -> Bool {
        let line = buffer.lineStart(buffer.point)..<buffer.lineEnd(buffer.point)
        let text = buffer.substring(line.lowerBound, line.upperBound) as NSString
        let regex = try! NSRegularExpression(pattern: "\\[[0-9]*(?:%|/[0-9]*)\\]")
        return regex.matches(in: text as String, range: NSRange(location: 0, length: text.length)).contains {
            let start = line.lowerBound + $0.range.location
            return start <= buffer.point && buffer.point < start + $0.range.length
        }
    }
}

extension EmacsBuffer {
    /// `org-clock-update-time-maybe` on a finished clock line: both dates' weekdays fixed and
    /// the duration written again.
    func clockUpdateTime() {
        saveExcursion {
            point = lineStart(point)
            skipForward([32, 9])
            guard let match = lookingAt("[ \\t]*CLOCK: *[\\[<]([^\\]>]+)[\\]>](-+[\\[<]([^\\]>]+)[\\]>]([ \\t]*=>.*)?)?"),
                  match[2] != nil, let first = match[1] else { return }
            saveExcursion {
                point = first.lowerBound
                try? changeTimestamp(0, what: .day)
            }
            guard let again = lookingAt("[ \\t]*CLOCK: *[\\[<]([^\\]>]+)[\\]>](-+[\\[<]([^\\]>]+)[\\]>]([ \\t]*=>.*)?)?"), let second = again[3] else { return }
            saveExcursion {
                point = second.lowerBound
                try? changeTimestamp(0, what: .day)
            }
            guard let final = lookingAt("[ \\t]*CLOCK: *[\\[<]([^\\]>]+)[\\]>](-+[\\[<]([^\\]>]+)[\\]>]([ \\t]*=>.*)?)?"),
                  let start = final[1], let end = final[3] else { return }
            if let arrow = final[4] { deleteRegion(arrow.lowerBound, arrow.upperBound) }
            point = lineEnd(point)
            let s = TagsMatcher.seconds(substring(end.lowerBound, end.upperBound), now: now, calendar: calendar)
                - TagsMatcher.seconds(substring(start.lowerBound, start.upperBound), now: now, calendar: calendar)
            let total = abs(Int(s))
            insert(" => " + String(format: s < 0 ? "-%d:%02d" : "%2d:%02d", total / 3600, total % 3600 / 60))
        }
    }
}
