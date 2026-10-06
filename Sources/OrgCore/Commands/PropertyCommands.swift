import Foundation

// Property commands (Org 9.8.7): `org-set-property` with its completion, `org-delete-property`,
// `org-delete-property-globally`, `org-property-action` (C-c C-c in a property drawer) and
// `org-property-next-allowed-value` (S-right and S-left on a property line).

extension EmacsBuffer {
    /// `org-get-property-block` without FORCE: the body of the entry's property drawer.
    func existingPropertyBlock() -> Range<Int>? {
        saveExcursion {
            backToHeadingOrPointMin()
            if beforeFirstHeading {
                while bolp, lookingAt("^[ \\t]*#[ \\t]") != nil || lookingAt("^[ \\t]*#$") != nil { if forwardLine(1) != 0 { break } }
            } else {
                forwardLine(1)
                if lookingAt(planningPattern) != nil { forwardLine(1) }
            }
            guard let match = looking(Self.propertyDrawerPattern) else { return nil }
            forwardLine(1)
            return point..<lineStart(match[0]!.upperBound)
        }
    }

    /// `org-at-property-p`: a property line inside a property drawer; its key.
    func propertyAtPoint() -> String? {
        guard let block = existingPropertyBlock(), block.contains(lineStart(point)) else { return nil }
        let line = substring(lineStart(point), lineEnd(point))
        return line.firstMatch(of: /^[ \t]*:(\S+?)\+?:(?:[ \t]|$)/).map { String($0.1) }
    }

    /// `org-entry-delete`: true when a property was removed.
    @discardableResult
    func entryDelete(_ name: String) -> Bool {
        guard let block = existingPropertyBlock() else { return false }
        let begin = block.lowerBound
        let end = marker(block.upperBound)
        defer { release(end) }
        let origin = block.upperBound
        point = begin
        let pattern = "^[ \\t]*:" + NSRegularExpression.escapedPattern(for: name) + "\\+?:(?:[ \\t].*?)?[ \\t]*$"
        while let match = searchForward(pattern, bound: end.position, caseInsensitive: true) {
            let lineEnd = min(length, self.lineEnd(match[0]!.lowerBound) + 1)
            deleteRegion(match[0]!.lowerBound, lineEnd)
            point = match[0]!.lowerBound
        }
        if begin == end.position {
            point = begin
            let previous = saveExcursion { () -> Int in forwardLine(-1); return point }
            let next = min(length, lineEnd(begin) + 1)
            deleteRegion(previous, next)
        }
        return end.position != origin
    }
}

/// The values a property may take (`org-property-get-allowed-values`): `KEY_ALL` from the
/// entry or above it, TODO keywords, priorities. `unrestricted` when `:ETC` allows others.
public enum PropertyValues {
    static let special: Set<String> = ["ALLTAGS", "BLOCKED", "CLOCKSUM", "CLOCKSUM_T", "CLOSED", "DEADLINE", "FILE", "ITEM", "PRIORITY",
                                       "SCHEDULED", "TAGS", "TIMESTAMP", "TIMESTAMP_IA", "TODO"]
    static let defaults = ["EFFORT", "ARCHIVE", "CATEGORY", "SUMMARY", "DESCRIPTION", "CUSTOM_ID", "LOCATION", "LOGGING", "COLUMNS", "VISIBILITY",
                           "TABLE_EXPORT_FORMAT", "TABLE_EXPORT_FILE", "EXPORT_OPTIONS", "EXPORT_TEXT", "EXPORT_FILE_NAME", "EXPORT_TITLE",
                           "EXPORT_AUTHOR", "EXPORT_DATE", "UNNUMBERED", "ORDERED", "NOBLOCKING", "COOKIE_DATA", "LOG_INTO_DRAWER",
                           "REPEAT_TO_STATE", "CLOCK_MODELINE_TOTAL", "STYLE", "HTML_CONTAINER_CLASS", "ORG-IMAGE-ACTUAL-WIDTH"]

    public static func allowed(_ key: String, at offset: Int, text: String, tree: OrgTree) -> (values: [String], unrestricted: Bool)? {
        let upper = key.uppercased()
        let settings = tree.settings
        if upper == "TODO" {
            return (settings.todoSequences.flatMap { ($0.active + $0.done).map(\.name) } + [""], false)
        }
        if upper == "PRIORITY" {
            guard let high = PriorityChange.value(settings.priorities.highest), let low = PriorityChange.value(settings.priorities.lowest), high <= low else { return nil }
            let numeric = Int(settings.priorities.lowest) != nil
            return ((high...low).map { PriorityChange.label($0, numeric: numeric) }, false)
        }
        if upper == "CATEGORY" || special.contains(upper) { return nil }
        let model = DocumentModel(tree: tree)
        let name = (key + "_ALL").uppercased()
        var raw: String?
        if let index = model.headings.lastIndex(where: { $0.headingRange.lowerBound <= offset }) {
            for h in [index] + model.ancestors(of: index).reversed() {
                if let p = model.headings[h].properties.last(where: { $0.key.uppercased() == name }) {
                    raw = p.value
                    break
                }
            }
        }
        if raw == nil { raw = model.fileProperties.last { $0.key.uppercased() == name }?.value }
        guard let raw, raw.contains(where: { !$0.isWhitespace }) else { return nil }
        var values = readList(raw)
        let unrestricted = values.contains(":ETC")
        values.removeAll { $0 == ":ETC" }
        return values.isEmpty ? nil : (values, unrestricted)
    }

    /// `(read-from-string (concat "(" vals ")"))` as strings: quoted strings, numbers, symbols.
    static func readList(_ s: String) -> [String] {
        var values: [String] = []
        for m in s.matches(of: /"((?:[^"\\]|\\.)*)"|(\S+)/) {
            if let quoted = m.1 {
                values.append(String(quoted).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\"))
            } else if let token = m.2 {
                let t = String(token)
                values.append(Int(t).map(String.init) ?? t)
            }
        }
        return values
    }

    /// `org-buffer-property-keys` with DEFAULTS and COLUMNS.
    public static func keys(in text: String) -> [String] {
        var keys = defaults
        for m in text.matches(of: #/(?mi)^[ \t]*#\+PROPERTY:[ \t]+(\S+)/#) { keys.append(String(m.1)) }
        for m in text.matches(of: #/(?m)^[ \t]*:([^\s:]+?)\+?:[ \t]/#) where String(m.1).uppercased() != "END" && String(m.1).uppercased() != "PROPERTIES" {
            keys.append(String(m.1))
        }
        for m in text.matches(of: #/(?mi)^[ \t]*(?:#\+|:)COLUMNS:(.*)$/#) {
            for c in String(m.1).matches(of: /%[0-9]*([A-Za-z0-9_-]+)(?:\([^)]+\))?(?:\{[^}]+\})?/) { keys.append(String(c.1)) }
        }
        var seen: Set<String> = []
        return keys.filter { seen.insert($0).inserted }.sorted { $0.lowercased() < $1.lowercased() }
    }
}

/// C-c C-x p: `org-set-property`, asking for the property (the one at point by default) and its
/// value, offering the allowed values or those in use.
public struct ReadAndSetProperty: OrgCommand {
    public init() {}
    public var id: String { "org.property.read-and-set" }
    public var title: String { "Set Property…" }
    public func applies(in context: EditContext) -> Bool { true }

    public func run(in context: EditContext) -> CommandStep {
        let buffer = EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings, options: context.options)
        let atPoint = buffer.propertyAtPoint()
        guard let typed = context.answers["property"] else {
            return .prompt(Prompt(key: "property", message: "Property" + (atPoint.map { " [\($0)]" } ?? "") + ":",
                                  choices: PropertyValues.keys(in: context.text), requireMatch: false))
        }
        let key = typed.trimmingCharacters(in: .whitespaces).isEmpty ? atPoint ?? "" : typed.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.range(of: "^[^\\s]+$", options: .regularExpression) != nil else { return .failed("Invalid property name: \"\(key)\"") }
        let current = buffer.saveExcursion { () -> String? in
            buffer.backToHeadingOrPointMin()
            guard let block = buffer.existingPropertyBlock() else { return nil }
            buffer.point = block.lowerBound
            guard let m = buffer.searchForward("^[ \\t]*:" + NSRegularExpression.escapedPattern(for: key) + ":[ \\t]*(.*?)[ \\t]*$", bound: block.upperBound) else { return nil }
            return buffer.substring(m[1]!.lowerBound, m[1]!.upperBound)
        }
        guard let answer = context.answers["value"] else {
            let allowed = PropertyValues.allowed(key, at: context.caret, text: context.text, tree: context.tree)
            let message = "\(key) value" + (current.map { $0.isEmpty ? "" : " [\($0)]" } ?? "") + ":"
            if let allowed {
                return .prompt(Prompt(key: "value", message: message, choices: allowed.values, requireMatch: !allowed.unrestricted))
            }
            return .prompt(Prompt(key: "value", message: message, choices: SparseTreeCommand.propertyValues(key, in: context.text), requireMatch: false))
        }
        let allowed = PropertyValues.allowed(key, at: context.caret, text: context.text, tree: context.tree)
        var value = answer.trimmingCharacters(in: .whitespaces)
        if value.isEmpty, allowed == nil { value = current ?? "" }
        guard current != value else { return .commit(EditResult(baseRevision: context.revision, edits: [])) }
        return SetProperty(key: key, value: value).run(in: context)
    }
}

/// `org-delete-property` and `org-delete-property-globally`.
public struct DeleteProperty: OrgCommand {
    let globally: Bool
    public init(globally: Bool = false) { self.globally = globally }
    public var id: String { globally ? "org.property.delete-globally" : "org.property.delete" }
    public var title: String { globally ? "Delete Property Everywhere…" : "Delete Property…" }
    public func applies(in context: EditContext) -> Bool { true }

    public func run(in context: EditContext) -> CommandStep {
        let buffer = EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings, options: context.options)
        if globally {
            guard let key = context.answers["property"] else {
                return .prompt(Prompt(key: "property", message: "Globally remove property:", choices: PropertyValues.keys(in: context.text), requireMatch: false))
            }
            var count = 0
            let step = commitBuffer(context) { buffer in
                buffer.point = 0
                let pattern = "^[ \\t]*:" + NSRegularExpression.escapedPattern(for: key) + "\\+?:(?:[ \\t].*?)?[ \\t]*$"
                while let match = buffer.searchForward(pattern, caseInsensitive: true) {
                    buffer.point = match[0]!.upperBound
                    let resume = buffer.marker(buffer.lineStart(buffer.point))
                    if buffer.saveExcursion({ buffer.entryDelete(key) }) { count += 1 }
                    buffer.point = resume.position
                    buffer.release(resume)
                    if buffer.lookingAt(pattern) == nil, buffer.forwardLine(1) != 0 { break }
                }
            }
            return with(step, message: "Property \"\(key)\" removed from \(count) entries")
        }
        let keys = buffer.saveExcursion { () -> [String] in
            guard let block = buffer.existingPropertyBlock() else { return [] }
            return buffer.substring(block.lowerBound, block.upperBound).matches(of: #/(?m)^[ \t]*:([^\s:]+?)\+?:/#).map { String($0.1) }
        }
        let key: String
        if keys.count > 1 {
            guard let answer = context.answers["property"] else {
                return .prompt(Prompt(key: "property", message: "Property:", choices: keys))
            }
            key = answer
        } else if let only = keys.first {
            key = only
        } else {
            return .commit(EditResult(baseRevision: context.revision, edits: [], effects: [.message("No property to delete in this entry")]))
        }
        return with(commitBuffer(context) { buffer in buffer.saveExcursion { buffer.entryDelete(key) } }, message: "Property \"\(key)\" deleted")
    }

    private func with(_ step: CommandStep, message: String) -> CommandStep {
        guard case .commit(let result) = step else { return step }
        return .commit(EditResult(baseRevision: result.baseRevision, edits: result.edits, selection: result.selection, effects: result.effects + [.message(message)]))
    }
}

/// C-c C-c in a property drawer: `org-property-action`.
public struct PropertyAction: OrgCommand {
    public init() {}
    public var id: String { "org.property.action" }
    public var title: String { "Property Action…" }
    public func applies(in context: EditContext) -> Bool { true }

    static let menu = FastSelection(items: [
        .option(key: "s", name: "set"), .option(key: "d", name: "delete"), .option(key: "D", name: "delete globally"),
    ], multiple: false)

    public func run(in context: EditContext) -> CommandStep {
        guard let key = context.answers["action"] else {
            return .prompt(Prompt(key: "action", message: "Property Action:  [s]et  [d]elete  [D]elete globally", fast: Self.menu))
        }
        switch key {
        case "s": return ReadAndSetProperty().run(in: context)
        case "d": return DeleteProperty().run(in: context)
        case "D": return DeleteProperty(globally: true).run(in: context)
        default: return .failed("No such property action \(key)")
        }
    }
}

/// S-right and S-left on a property line: `org-property-next-allowed-value`.
public struct NextAllowedValue: OrgCommand {
    let previous: Bool
    public init(previous: Bool) { self.previous = previous }
    public var id: String { previous ? "org.property.previous-value" : "org.property.next-value" }
    public var title: String { previous ? "Previous Allowed Value" : "Next Allowed Value" }
    public func applies(in context: EditContext) -> Bool { EmacsBuffer(context.text, point: context.caret).propertyAtPoint() != nil }

    public func run(in context: EditContext) -> CommandStep {
        let buffer = EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings, options: context.options)
        guard let key = buffer.propertyAtPoint() else { return .failed("Not at a property") }
        let line = buffer.substring(buffer.lineStart(context.caret), buffer.lineEnd(context.caret))
        let value = line.firstMatch(of: /^[ \t]*:\S+?:(?:[ \t]+(.*?))?[ \t]*$/)?.1.map(String.init) ?? ""
        let allowed = PropertyValues.allowed(key, at: context.caret, text: context.text, tree: context.tree)?.values
            ?? (["[ ]", "[-]", "[X]"].contains(value) ? ["[ ]", "[X]"] : nil)
        guard var values = allowed else { return .failed("Allowed values for this property have not been defined") }
        if previous { values.reverse() }
        var next = values.firstIndex(of: value).flatMap { $0 + 1 < values.count ? values[$0 + 1] : nil }
        next = next ?? values.first
        guard let new = next, new != value else { return .failed("Only one allowed value for this property") }
        return commitBuffer(context) { buffer in
            let start = buffer.lineStart(context.caret)
            buffer.replace(start..<buffer.lineEnd(context.caret), with: " :\(key): \(new)")
            buffer.point = start
            buffer.alignNodeProperty()
            buffer.point = buffer.lineStart(start)
            buffer.skipForward([32, 9])
        }
    }
}
