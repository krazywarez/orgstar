import Foundation

// Capture (org-capture.el, Org 9.8.7): filling a template and placing the result in its
// target, as `org-capture` followed by `org-capture-finalize` leaves the target file.

public struct CaptureTemplate: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable { case entry, item, checkitem, plain, tableLine = "table-line" }

    /// `:tree-type`: what a date tree groups entries by.
    public enum TreeType: String, Sendable, Equatable { case day, week, month }

    public enum Target: Sendable, Equatable {
        case file(String)
        case headline(file: String, headline: String)
        case outline(file: String, path: [String])
        /// `file+olp+datetree`: today's entry in a date tree, under `path` or at the top.
        case datetree(file: String, path: [String], tree: TreeType)
        /// `(id "…")`: the heading with that ID; the app finds its file.
        case id(String)
        /// `(clock)`: the clocked-in entry; the app turns it into `heading`.
        case clock
        /// The heading starting at `offset` in `file`.
        case heading(file: String, offset: Int)

        /// The target file, or "" for `id` and `clock` until the app resolves them.
        public var file: String {
            switch self {
            case .file(let f), .headline(let f, _), .outline(let f, _), .datetree(let f, _, _), .heading(let f, _): f
            case .id, .clock: ""
            }
        }
    }

    /// Template properties beyond the target (`org-capture-templates`).
    public struct Options: Sendable, Equatable {
        public var prepend = false
        /// `:immediate-finish`: file without showing the text.
        public var immediateFinish = false
        /// `:empty-lines`, `:empty-lines-before`, `:empty-lines-after`.
        public var emptyLines: Int?
        public var emptyLinesBefore: Int?
        public var emptyLinesAfter: Int?
        /// `:jump-to-captured`: show the entry after filing it.
        public var jumpToCaptured = false
        /// `:clock-in`, `:clock-keep`, `:clock-resume`.
        public var clockIn = false
        public var clockKeep = false
        public var clockResume = false
        /// `:table-line-pos`: `II-3` is the third line above the second rule.
        public var tableLinePos: String?

        public init(
            prepend: Bool = false, immediateFinish: Bool = false, emptyLines: Int? = nil, emptyLinesBefore: Int? = nil,
            emptyLinesAfter: Int? = nil, jumpToCaptured: Bool = false, clockIn: Bool = false, clockKeep: Bool = false, clockResume: Bool = false,
            tableLinePos: String? = nil
        ) {
            self.tableLinePos = tableLinePos
            self.prepend = prepend
            self.immediateFinish = immediateFinish
            self.emptyLines = emptyLines
            self.emptyLinesBefore = emptyLinesBefore
            self.emptyLinesAfter = emptyLinesAfter
            self.jumpToCaptured = jumpToCaptured
            self.clockIn = clockIn
            self.clockKeep = clockKeep
            self.clockResume = clockResume
        }

        var before: Int? { emptyLinesBefore ?? emptyLines }
        var after: Int { emptyLinesAfter ?? emptyLines ?? 0 }
    }

    public let key: String
    public let name: String
    public let kind: Kind
    public let target: Target
    public let template: String
    public let options: Options
    public var prepend: Bool { options.prepend }
    public var id: String { key }

    public init(key: String, name: String, kind: Kind = .entry, target: Target, template: String, prepend: Bool = false, options: Options = Options()) {
        self.key = key
        self.name = name
        self.kind = kind
        self.target = target
        self.template = template
        var options = options
        if prepend { options.prepend = true }
        self.options = options
    }

    /// The same template aimed at `target`.
    public func retargeted(_ target: Target) -> CaptureTemplate {
        CaptureTemplate(key: key, name: name, kind: kind, target: target, template: template, options: options)
    }
}

/// What the escapes in a template stand for.
public struct CaptureContext: Sendable {
    public var now: Date
    public var calendar: Calendar
    /// `%i`: the selected text.
    public var initial: String
    /// `%a`: a link to where capture started, `[[target][description]]`, or empty.
    public var annotation: String
    /// `%c` and `%x`: the clipboard.
    public var clipboard: String
    /// `%f` and `%F`: the file capture started from.
    public var file: String
    /// `%n`.
    public var userName: String
    /// `%k` and `%K`: the clocked-in entry's title and a link to it, or empty.
    public var clockHeading: String
    public var clockLink: String
    /// `%^g` and `%^G` offer these: the target file's tags, and every file's.
    public var fileTags: [String]
    public var allTags: [String]
    /// `org-tags-column`, for aligning tags `%^g` adds to a heading.
    public var tagsColumn: Int
    /// `org-store-link-plist` as org-protocol sets it, for `%:link`, `%:description` and others.
    public var linkProperties: [String: String] = [:]

    public init(
        now: Date = Date(), calendar: Calendar = .current, initial: String = "", annotation: String = "", clipboard: String = "",
        file: String = "", userName: String = "", clockHeading: String = "", clockLink: String = "",
        fileTags: [String] = [], allTags: [String] = [], tagsColumn: Int = -77
    ) {
        self.now = now
        self.calendar = calendar
        self.initial = initial
        self.annotation = annotation
        self.clipboard = clipboard
        self.file = file
        self.userName = userName
        self.clockHeading = clockHeading
        self.clockLink = clockLink
        self.fileTags = fileTags
        self.allTags = allTags
        self.tagsColumn = tagsColumn
    }
}

public enum Capture {
    public enum Failure: Error, Equatable {
        case message(String)
    }

    /// A question the template asks before it can be filled: `%^{prompt|default|choice…}`,
    /// or one of `%^g`, `%^G`, `%^t`, `%^T`, `%^u`, `%^U`, `%^C`, `%^L`, `%^{prop}p`.
    public struct Question: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case text
            /// Tags, separated by colons.
            case tags
            /// A date as `org-read-date` reads it (`+2d`, `fri 14:00`); empty is today.
            case date(withTime: Bool, inactive: Bool)
            /// `%^C` and `%^L`: text from the clipboard, inserted as a link with `link`.
            case clipboard(link: Bool)
            /// `%^{NAME}p`: the value of property `NAME`.
            case property
        }

        public let prompt: String
        public let defaultValue: String
        public let choices: [String]
        public let kind: Kind

        public init(prompt: String, defaultValue: String, choices: [String], kind: Kind = .text) {
            self.prompt = prompt
            self.defaultValue = defaultValue
            self.choices = choices
            self.kind = kind
        }
    }

    static let promptPattern = "%\\^(?:\\{([^}]*)\\})?([CgGLptTuU])?"

    /// The questions `template` asks, in order.
    public static func questions(_ template: String, context: CaptureContext = CaptureContext()) -> [Question] {
        guard case .success(let expanded) = expand(template, context) else { return [] }
        return prompts(in: expanded).map { question($0.items, $0.key, context) }
    }

    static func question(_ items: [String]?, _ key: String?, _ context: CaptureContext) -> Question {
        let prompt = items?.first
        let defaultValue = items.map { $0.count > 1 ? $0[1] : "" } ?? ""
        switch key {
        case "g", "G": return Question(prompt: prompt ?? "Tags", defaultValue: "", choices: key == "g" ? context.fileTags : context.allTags, kind: .tags)
        case "t", "T", "u", "U":
            let upper = key == key?.uppercased()
            return Question(prompt: prompt ?? "Date", defaultValue: "", choices: [], kind: .date(withTime: upper, inactive: key == "u" || key == "U"))
        case "C", "L":
            let values = [context.initial, context.clipboard].filter { !$0.isEmpty }
            return Question(prompt: "Clipboard/kill value", defaultValue: context.initial, choices: values, kind: .clipboard(link: key == "L"))
        case "p": return Question(prompt: prompt ?? "", defaultValue: defaultValue, choices: [], kind: .property)
        default: return Question(prompt: prompt ?? "Enter string", defaultValue: defaultValue, choices: items.map { Array($0.dropFirst(2)) } ?? [])
        }
    }

    /// The unescaped `%^` placeholders in `text`.
    static func prompts(in text: String) -> [(range: NSRange, items: [String]?, key: String?)] {
        let regex = try! NSRegularExpression(pattern: promptPattern)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard !escaped(ns, at: m.range.location) else { return nil }
            let items = m.range(at: 1).location == NSNotFound ? nil : ns.substring(with: m.range(at: 1)).components(separatedBy: "|")
            let key = m.range(at: 2).location == NSNotFound ? nil : ns.substring(with: m.range(at: 2))
            return (m.range, items, key)
        }
    }

    /// `org-capture-escaped-%` without its unescaping: an odd run of backslashes before `%`.
    static func escaped(_ ns: NSString, at index: Int) -> Bool {
        var i = index
        while i > 0, ns.character(at: i - 1) == 92 { i -= 1 }
        return (index - i) % 2 == 1
    }

    /// Where `%?` puts the cursor while the template is filled.
    static let cursorMark = "\u{E000}"

    /// `org-capture-fill-template`: the text and where `%?` puts the cursor. `answers` holds
    /// the replies to `questions(template)` in order.
    public static func fill(_ template: String, context: CaptureContext, answers: [String] = []) -> Result<(text: String, cursor: Int), Failure> {
        let expanded: String
        switch expand(template, context) {
        case .failure(let failure): return .failure(failure)
        case .success(let text): expanded = text
        }
        // Prompts, in order, answered in the text as it stands then, as org does.
        var options = EditingOptions.org
        options.tagsColumn = context.tagsColumn
        let buffer = EmacsBuffer(expanded, point: 0, settings: .default, options: options)
        buffer.now = context.now
        buffer.calendar = context.calendar
        var strings: [String] = []
        var all: [String] = []
        var index = 0
        while let match = buffer.searchForward(promptPattern, caseInsensitive: false) {
            let whole = match[0]!
            if unescape(buffer, at: whole.lowerBound) { continue }
            let start = buffer.point - whole.count
            let items = match[1].map { buffer.substring($0.lowerBound, $0.upperBound).components(separatedBy: "|") }
            let key = match[2].map { buffer.substring($0.lowerBound, $0.upperBound) }
            let question = question(items, key, context)
            let answer = index < answers.count ? answers[index] : ""
            index += 1
            buffer.deleteRegion(start, buffer.point)
            buffer.point = start
            switch question.kind {
            case .text:
                let value = answer.isEmpty ? question.defaultValue : answer
                strings.append(value)
                all.append(value)
                buffer.insert(value)
            case .tags:
                let tags = answer.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard !tags.isEmpty else { continue }
                all.append(":" + tags.joined(separator: ":") + ":")
                if buffer.point == 0 || buffer.character(at: buffer.point - 1) != 58 { buffer.insert(":") }
                buffer.insert(tags.joined(separator: ":"))
                if buffer.point >= buffer.length || buffer.character(at: buffer.point) != 58 { buffer.insert(":") }
                if buffer.lookingAtLine("^\\*+ ") { buffer.alignTags(onLineAt: buffer.point) }
            case .date(let withTime, let inactive):
                let result: ReadDate.Answer
                if answer.trimmingCharacters(in: .whitespaces).isEmpty {
                    let c = context.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: context.now)
                    result = ReadDate.Answer(year: c.year!, month: c.month!, day: c.day!, hour: c.hour!, minute: c.minute!, timeGiven: false)
                } else {
                    result = buffer.readDate(answer, default: context.now)
                }
                let stamp = buffer.insertTimestamp(result.components(context.calendar), withTime: result.timeGiven || withTime, inactive: inactive, endTime: result.endTime)
                all.append(stamp)
            case .clipboard(let link):
                let value = answer.isEmpty ? question.defaultValue : answer
                all.append(value)
                buffer.insert(link ? Links.makeString(value, nil) : value)
            case .property:
                let value = answer.isEmpty ? question.defaultValue : answer
                buffer.saveExcursion { buffer.entryPut(question.prompt, value) }
                all.append(value)
            }
        }
        // `%\N`: the Nth `%^{…}` answer; `%\*N`: the Nth answer of any prompt.
        var text = buffer.string
        for (pattern, values) in [("%\\\\\\*([1-9][0-9]*)", all), ("%\\\\([1-9][0-9]*)", strings)] {
            let regex = try! NSRegularExpression(pattern: pattern)
            let ns = text as NSString
            var out = text
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() where !escaped(ns, at: m.range.location) {
                let n = Int(ns.substring(with: m.range(at: 1))) ?? Int.max
                out = (out as NSString).replacingCharacters(in: m.range, with: n <= values.count ? values[n - 1] : "")
            }
            text = out
        }
        // No blank lines before the text; it ends with one newline, or is empty.
        var lines = text.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty, lines.count > 1 { lines.removeFirst() }
        var marked = lines.joined(separator: "\n")
        let trimmed = marked.replacingOccurrences(of: "[ \\t\\n]+$", with: "", options: .regularExpression)
        marked = trimmed.isEmpty ? "" : trimmed + "\n"
        marked = marked.replacingOccurrences(of: "\t", with: "        ")
        guard let range = marked.range(of: cursorMark) else { return .success((marked, marked.utf16.count > 0 ? marked.utf16.count - 1 : 0)) }
        let offset = marked[..<range.lowerBound].utf16.count
        marked.removeSubrange(range)
        return .success((marked, offset))
    }

    /// `org-capture-escaped-%` at the `%` at `index`: drops half the backslashes before it;
    /// true when it was escaped. Point follows the deletion.
    static func unescape(_ buffer: EmacsBuffer, at index: Int) -> Bool {
        var i = index
        while i > 0, buffer.character(at: i - 1) == 92 { i -= 1 }
        let n = index - i
        guard n > 0 else { return false }
        buffer.deleteRegion(i, i + (n + 1) / 2)
        return n % 2 == 1
    }

    /// The escapes that need no answer (`%a`, `%t`, `%<…>`, `%?`…), with `%^` prompts and `%\N`
    /// left in place.
    static func expand(_ template: String, _ context: CaptureContext) -> Result<String, Failure> {
        func stamp(_ active: Bool, _ withTime: Bool) -> String {
            let c = context.calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: context.now)
            let day = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][(c.weekday ?? 1) - 1]
            let body = String(format: "%04d-%02d-%02d %@", c.year!, c.month!, c.day!, day) + (withTime ? String(format: " %02d:%02d", c.hour!, c.minute!) : "")
            return active ? "<\(body)>" : "[\(body)]"
        }
        let link = try! NSRegularExpression(pattern: "\\[\\[(.*?)\\](\\[.*?\\])?\\]")
        func linkForm(_ template: String) -> String {
            let ns = context.annotation as NSString
            guard let m = link.firstMatch(in: context.annotation, range: NSRange(location: 0, length: ns.length)) else { return context.annotation }
            return template.replacingOccurrences(of: "$1", with: ns.substring(with: m.range(at: 1)))
        }
        var text = ""
        let chars = Array(template)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == "%", i + 1 < chars.count else {
                text.append(c)
                i += 1
                continue
            }
            // A `%` after an odd run of backslashes stays, with half of them.
            var slashes = 0
            while slashes < text.count, text.dropLast(slashes).last == "\\" { slashes += 1 }
            let next = chars[i + 1]
            if slashes > 0, "aAcfFikKlLntTuUx:<?".contains(next) {
                text.removeLast((slashes + 1) / 2)
                if slashes % 2 == 1 {
                    text.append(c)
                    i += 1
                    continue
                }
            }
            var consumed = 2
            switch next {
            case "?": text += cursorMark
            case "i":
                // Continuation lines keep the indentation of the line `%i` is on.
                let lead = String(text.split(separator: "\n", omittingEmptySubsequences: false).last ?? "").prefix { $0 == " " || $0 == "\t" }
                text += context.initial.replacingOccurrences(of: "\n", with: "\n" + lead)
            case "a": text += context.annotation == "[[]]" ? "" : context.annotation
            case "A":
                // The link, with its description asked for.
                let ns = context.annotation as NSString
                if let m = link.firstMatch(in: context.annotation, range: NSRange(location: 0, length: ns.length)) {
                    text += ns.replacingCharacters(in: m.range, with: "[[" + ns.substring(with: m.range(at: 1)) + "][%^{Link description}]]")
                } else {
                    text += context.annotation
                }
            case "l": text += linkForm("[[$1]]")
            case "L": text += linkForm("$1")
            case "c", "x": text += context.clipboard
            case "f": text += (context.file as NSString).lastPathComponent
            case "F": text += context.file
            case "n": text += context.userName
            case "k": text += context.clockHeading
            case "K": text += context.clockLink
            case "t": text += stamp(true, false)
            case "T": text += stamp(true, true)
            case "u": text += stamp(false, false)
            case "U": text += stamp(false, true)
            case "<":
                guard let close = chars[(i + 2)...].firstIndex(of: ">"), !chars[(i + 2)..<close].contains("\n") else {
                    text.append(c)
                    consumed = 1
                    break
                }
                text += strftime(String(chars[(i + 2)..<close]), context)
                consumed = close - i + 1
            case ":":
                // A link property (`%:annotation`), from org-protocol or the capture's own.
                var j = i + 2
                while j < chars.count, chars[j].isLetter || chars[j] == "-" { j += 1 }
                guard j > i + 2 else {
                    text.append(c)
                    consumed = 1
                    break
                }
                let name = String(chars[(i + 2)..<j])
                switch name {
                case _ where context.linkProperties[name] != nil: text += context.linkProperties[name]!
                case "annotation": text += context.annotation
                case "initial": text += context.initial
                default: break
                }
                consumed = j - i
            case "(":
                return .failure(.message("Template escapes like %( run Emacs Lisp, which orgstar doesn't."))
            case "[":
                return .failure(.message("Template escapes like %[file] aren't supported yet."))
            default:
                text.append(c)
                consumed = 1
            }
            i += consumed
        }
        return .success(text)
    }

    static func strftime(_ format: String, _ context: CaptureContext) -> String {
        let c = context.calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second], from: context.now)
        let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        var out = ""
        var chars = format.makeIterator()
        while let ch = chars.next() {
            guard ch == "%", let f = chars.next() else {
                out.append(ch)
                continue
            }
            switch f {
            case "Y": out += String(format: "%04d", c.year!)
            case "m": out += String(format: "%02d", c.month!)
            case "d": out += String(format: "%02d", c.day!)
            case "e": out += String(format: "%2d", c.day!)
            case "H": out += String(format: "%02d", c.hour!)
            case "M": out += String(format: "%02d", c.minute!)
            case "S": out += String(format: "%02d", c.second!)
            case "a": out += String(days[c.weekday! - 1].prefix(3))
            case "A": out += days[c.weekday! - 1]
            case "b": out += String(months[c.month! - 1].prefix(3))
            case "B": out += months[c.month! - 1]
            case "F": out += String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
            case "R": out += String(format: "%02d:%02d", c.hour!, c.minute!)
            case "%": out += "%"
            default: out += "%" + String(f)
            }
        }
        return out
    }

    // MARK: - Placing

    /// The target file's text after capturing `text`, as `org-capture-finalize` leaves it.
    /// `now` and `calendar` pick a date tree's day.
    public static func place(
        _ text: String, template: CaptureTemplate, in fileText: String, settings: OrgSettings = .default,
        now: Date = Date(), calendar: Calendar = .current
    ) -> Result<String, Failure> {
        placement(text, template: template, in: fileText, settings: settings, now: now, calendar: calendar).map(\.text)
    }

    /// The new text, and where the captured entry starts in it.
    public static func placement(
        _ text: String, template: CaptureTemplate, in fileText: String, settings: OrgSettings = .default,
        now: Date = Date(), calendar: Calendar = .current
    ) -> Result<(text: String, start: Int), Failure> {
        let buffer = EmacsBuffer(fileText, point: 0, settings: settings)
        let start: Int
        do {
            let entryHeading = try locate(template.target, buffer, date: calendar.dateComponents([.year, .month, .day], from: now))
            let options = template.options
            switch template.kind {
            case .entry: start = try placeEntry(text, options: options, heading: entryHeading, buffer)
            case .plain: start = placePlain(text, options: options, heading: entryHeading, buffer)
            case .item, .checkitem: start = try placeItem(text, checkbox: template.kind == .checkitem, options: options, heading: entryHeading, buffer)
            case .tableLine: start = try placeTableLine(text, options: options, heading: entryHeading, buffer)
            }
        } catch let error as Failure {
            return .failure(error)
        } catch let error as EmacsBuffer.UserError {
            return .failure(.message(error.message))
        } catch {
            return .failure(.message("\(error)"))
        }
        // Saving the target adds a final newline, as `require-final-newline` does in Org.
        var result = buffer.text as String
        if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
        return .success((result, start))
    }

    /// `org-capture-set-target-location`: point at the target heading, or nil for a file.
    static func locate(_ target: CaptureTemplate.Target, _ buffer: EmacsBuffer, date: DateComponents) throws -> Int? {
        switch target {
        case .file:
            return nil
        case .id(let id):
            buffer.point = 0
            guard let match = buffer.searchForward("^[ \\t]*:ID:[ \\t]+" + NSRegularExpression.escapedPattern(for: id) + "[ \\t]*$", caseInsensitive: true) else {
                throw Failure.message("Cannot find target ID \"\(id)\"")
            }
            buffer.point = match[0]!.lowerBound
            buffer.backToHeadingOrPointMin()
            return buffer.beforeFirstHeading ? nil : buffer.point
        case .clock:
            throw Failure.message("No running clock")
        case .heading(_, let offset):
            guard offset <= buffer.length else { throw Failure.message("The clocked entry moved; try again") }
            buffer.point = buffer.lineStart(offset)
            guard atHeading(buffer) else { throw Failure.message("The clocked entry moved; try again") }
            return buffer.point
        case .datetree(_, let path, let tree):
            let parent = path.isEmpty ? nil : try locate(.outline(file: "", path: path), buffer, date: date)
            return Datetree.findCreate(buffer, under: parent, tree: tree, date: date)
        case .headline(_, let headline):
            buffer.point = 0
            let pattern = "^\\*+[ \\t]+(?:[A-Z]+[ \\t]+)?(?:\\[#.\\][ \\t]*)?" + NSRegularExpression.escapedPattern(for: headline) + "(?:[ \\t]+:[\\w@#%:]+:)?[ \\t]*$"
            if let match = buffer.searchForward(pattern, caseInsensitive: false) {
                return buffer.lineStart(match[0]!.lowerBound)
            }
            buffer.point = buffer.length
            if !buffer.bolp { buffer.insert("\n") }
            let start = buffer.point
            buffer.insert("* " + headline + "\n")
            return start
        case .outline(_, let path):
            var start = 0
            var end = buffer.length
            var level = 0
            var found: Int?
            for title in path {
                buffer.point = start
                let pattern = "^(\\*+)[ \\t]+(?:[A-Z]+[ \\t]+)?(?:\\[#.\\][ \\t]*)?" + NSRegularExpression.escapedPattern(for: title) + "(?:[ \\t]+:[\\w@#%:]+:)?[ \\t]*$"
                var hit: Int?
                while let match = buffer.searchForward(pattern, bound: end, caseInsensitive: false) {
                    let stars = buffer.substring(match[1]!.lowerBound, match[1]!.upperBound).count
                    if stars > level, level == 0 || stars == level + 1 || found != nil {
                        hit = buffer.lineStart(match[0]!.lowerBound)
                        level = stars
                        break
                    }
                }
                guard let hit else { throw Failure.message("Heading not found on outline path \(path.joined(separator: "/"))") }
                found = hit
                buffer.point = hit
                start = hit
                end = buffer.saveExcursion { () -> Int in
                    endOfSubtree(buffer, heading: hit)
                    return buffer.point
                }
            }
            return found
        }
    }

    static func headingLevel(_ buffer: EmacsBuffer, at line: Int) -> Int {
        buffer.substring(line, buffer.lineEnd(line)).prefix { $0 == "*" }.count
    }

    static func atHeading(_ buffer: EmacsBuffer) -> Bool {
        buffer.lookingAtLine("^\\*+ ")
    }

    /// `outline-next-heading`.
    static func nextHeading(_ buffer: EmacsBuffer) {
        if let match = buffer.searchForward("\\n\\*+ ", caseInsensitive: false) {
            buffer.point = match[0]!.lowerBound + 1
        } else {
            buffer.point = buffer.length
        }
    }

    /// `org-end-of-subtree t t`: the start of the next heading at the same level or higher.
    static func endOfSubtree(_ buffer: EmacsBuffer, heading: Int) {
        let level = headingLevel(buffer, at: heading)
        buffer.point = heading
        while true {
            guard let match = buffer.searchForward("\\n(\\*+) ", caseInsensitive: false) else {
                buffer.point = buffer.length
                return
            }
            let stars = match[1]!.count
            if stars <= level {
                buffer.point = match[0]!.lowerBound + 1
                return
            }
            buffer.point = match[0]!.upperBound
        }
    }

    static func previousLineEmpty(_ buffer: EmacsBuffer) -> Bool {
        let start = buffer.lineStart(buffer.point)
        guard start > 0 else { return false }
        let previous = buffer.lineStart(start - 1)
        return buffer.substring(previous, start - 1).trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// `org--blank-before-heading-p` with `org-blank-before-new-entry` `(heading . auto)`.
    static func blankBeforeHeading(_ buffer: EmacsBuffer) -> Bool {
        buffer.saveExcursion {
            let before = buffer.searchBackward("^\\*+ ", caseInsensitive: false) == nil && !atHeading(buffer)
            if before {
                nextHeading(buffer)
                if buffer.point >= buffer.length, !atHeading(buffer) { return false }
            }
            // `org-back-to-heading`.
            if !atHeading(buffer) {
                buffer.point = buffer.lineStart(buffer.point)
                if !atHeading(buffer), let match = buffer.searchBackward("^\\*+ ", caseInsensitive: false) {
                    buffer.point = match[0]!.lowerBound
                }
            } else {
                buffer.point = buffer.lineStart(buffer.point)
            }
            if buffer.point > 0 { return previousLineEmpty(buffer) }
            let here = buffer.point
            nextHeading(buffer)
            if buffer.point < buffer.length || atHeading(buffer) { return previousLineEmpty(buffer) }
            buffer.point = here
            return false
        }
    }

    /// `org-back-over-empty-lines`, deleting them.
    static func deleteEmptyLinesBefore(_ buffer: EmacsBuffer) {
        let pos = buffer.point
        var start = pos
        while start > 0 {
            let lineStart = buffer.lineStart(start - 1)
            guard buffer.substring(lineStart, start - 1).trimmingCharacters(in: .whitespaces).isEmpty, start - 1 >= lineStart else { break }
            if lineStart == start - 1 || buffer.substring(lineStart, start).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // A blank line precedes; but keep the newline that ends the previous text line.
                if lineStart == 0 { start = 0; break }
                start = lineStart
            } else {
                break
            }
        }
        if start < pos { buffer.deleteRegion(start, pos) }
        buffer.point = start
    }

    /// `org-capture-empty-lines-after` with no lines: blank lines after point go.
    static func deleteEmptyLinesAfter(_ buffer: EmacsBuffer) {
        deleteEmptyLinesBefore(buffer)
        while buffer.looking("[ \\t]*\\n", caseInsensitive: false, setsMatch: false) != nil {
            let end = buffer.lineEnd(buffer.point) + 1
            buffer.deleteRegion(buffer.point, end)
        }
    }

    /// `org-capture-place-entry`.
    static func placeEntry(_ entry: String, options: CaptureTemplate.Options, heading: Int?, _ buffer: EmacsBuffer) throws -> Int {
        let prepend = options.prepend
        var template = entry
        if template.range(of: "(?m)^\\*+ ", options: .regularExpression) == nil { template = "* " + template }
        // `org-capture-verify-tree`: the first heading has the lowest level.
        let levels = template.components(separatedBy: "\n").compactMap { line -> Int? in
            let stars = line.prefix { $0 == "*" }.count
            return stars > 0 && line.dropFirst(stars).first == " " ? stars : nil
        }
        if let first = levels.first, levels.contains(where: { $0 < first }) || !template.hasPrefix("*") {
            throw Failure.message("Template is not a valid Org entry or tree")
        }
        var level = 1
        if let heading {
            level = headingLevel(buffer, at: heading) + 1
            buffer.point = heading
            if prepend {
                buffer.point = buffer.lineEnd(heading)
                nextHeading(buffer)
            } else {
                endOfSubtree(buffer, heading: heading)
            }
        } else if prepend {
            buffer.point = 0
            if !atHeading(buffer) { nextHeading(buffer) }
        } else {
            buffer.point = buffer.length
        }
        if !buffer.bolp { buffer.insert("\n") }
        let blank = blankBeforeHeading(buffer) && !previousLineEmpty(buffer)
        deleteEmptyLinesBefore(buffer)
        buffer.insert(String(repeating: "\n", count: options.before ?? (blank ? 1 : 0)))
        let start = buffer.point
        // `org-paste-subtree` at `level`.
        let oldLevel = levels.first ?? 1
        let shift = level - oldLevel
        var shifted = template
        if shift != 0 {
            shifted = template.components(separatedBy: "\n").map { line in
                let stars = line.prefix { $0 == "*" }.count
                guard stars > 0, line.dropFirst(stars).first == " " else { return line }
                return String(repeating: "*", count: max(1, stars + shift)) + line.dropFirst(stars)
            }.joined(separator: "\n")
        }
        if !shifted.hasSuffix("\n") { shifted += "\n" }
        buffer.insert(shifted)
        emptyLinesAfter(buffer, options.after)
        return start
    }

    /// `org-capture-empty-lines-after`: exactly `n` blank lines after point, point kept.
    static func emptyLinesAfter(_ buffer: EmacsBuffer, _ n: Int) {
        deleteEmptyLinesAfter(buffer)
        buffer.saveExcursion { buffer.insert(String(repeating: "\n", count: n)) }
    }

    /// `org-capture-place-plain-text`.
    static func placePlain(_ text: String, options: CaptureTemplate.Options, heading: Int?, _ buffer: EmacsBuffer) -> Int {
        let prepend = options.prepend
        if let heading {
            buffer.point = heading
            if prepend {
                buffer.point = buffer.lineEnd(heading)
                if buffer.point < buffer.length { buffer.point += 1 }
                skipMetaData(buffer)
            } else {
                buffer.point = buffer.lineEnd(heading)
                nextHeading(buffer)
            }
        } else {
            buffer.point = prepend ? 0 : buffer.length
        }
        if !buffer.bolp { buffer.insert("\n") }
        deleteEmptyLinesBefore(buffer)
        buffer.insert(String(repeating: "\n", count: options.before ?? 0))
        let start = buffer.point
        buffer.insert(text.hasSuffix("\n") || text.isEmpty ? text : text + "\n")
        emptyLinesAfter(buffer, options.after)
        return start
    }

    /// `org-capture-place-table-line`, then what `org-capture-finalize` does to the table: the
    /// first table in the entry, or the file, gets the line, at its end, after its first rule
    /// with `prepend`, or where `table-line-pos` says; a table is made when there's none.
    static func placeTableLine(_ filled: String, options: CaptureTemplate.Options, heading: Int?, _ buffer: EmacsBuffer) throws -> Int {
        let template = filled.trimmingCharacters(in: .whitespacesAndNewlines)
        // `org-table-border-regexp`: a template that isn't a table line becomes one.
        let text = template.range(of: "^[ \\t]*[^| \\t]", options: .regularExpression) != nil ? "| " + template : template + "\n"
        var begin = 0
        var end = buffer.length
        if let heading {
            begin = min(buffer.length, buffer.lineEnd(heading) + 1)
            buffer.point = buffer.lineEnd(heading)
            nextHeading(buffer)
            end = buffer.point
        }
        var table: Range<Int>?
        buffer.point = begin
        while table == nil, let match = buffer.searchForward("^[ \\t]*\\|[^-]", bound: end, caseInsensitive: false) {
            buffer.point = match[0]!.lowerBound
            if buffer.atTable { table = buffer.tableBegin()..<buffer.tableEnd() } else { buffer.point = match[0]!.upperBound }
        }
        if table == nil {
            buffer.point = end
            if !buffer.bolp { buffer.insert("\n") }
            let origin = buffer.point
            buffer.insert("|   |\n|---|\n")
            table = origin..<buffer.point
        }
        let rows = buffer.substring(table!.lowerBound, table!.upperBound).components(separatedBy: "\n")
        /// The start of the table's line `index`, within the table, as Org narrows to it.
        func lineStart(_ index: Int) -> Int {
            guard index > 0 else { return table!.lowerBound }
            return buffer.saveExcursion {
                buffer.point = table!.lowerBound
                return buffer.forwardLine(index) == 0 ? min(buffer.point, table!.upperBound) : table!.upperBound
            }
        }
        if let pos = options.tableLinePos {
            guard let m = pos.firstMatch(of: /(I+)([-+][0-9]+)/) else { throw Failure.message("Invalid table line specification \"\(pos)\"") }
            let hlines = rows.indices.filter { rows[$0].range(of: "^[ \\t]*\\|-", options: .regularExpression) != nil }
            guard m.1.count <= hlines.count else { throw Failure.message("Invalid table line specification \"\(pos)\"") }
            guard let delta = Int(m.2.replacingOccurrences(of: "+", with: "")), (-999_999...999_999).contains(delta) else {
                throw Failure.message("Invalid table line specification \"\(pos)\"")
            }
            // `forward-line` stops at the table's start, then one more line down.
            buffer.point = lineStart(max(0, hlines[m.1.count - 1] + delta + (delta < 0 ? 0 : -1)) + 1)
        } else if options.prepend {
            if let rule = rows.firstIndex(where: { $0.range(of: "^[ \\t]*\\|-", options: .regularExpression) != nil }) {
                let data = rows.indices.first { $0 > rule && rows[$0].range(of: "^[ \\t]*\\|[^-]", options: .regularExpression) != nil }
                buffer.point = data.map(lineStart) ?? table!.upperBound
            } else {
                buffer.point = table!.lowerBound
            }
        } else {
            buffer.point = table!.upperBound
        }
        if !buffer.bolp { buffer.insert("\n") }
        let start = buffer.point
        let lines = text.filter { $0 == "\n" }.count
        buffer.insert(text)
        // `org-capture-finalize`: align, or fix the formulas' row references and recalculate.
        buffer.point = start
        let row = buffer.substring(0, start).filter { $0 == "\n" }.count
        if buffer.atTable {
            if buffer.firstTblfm(after: buffer.tableEnd()) == nil {
                buffer.tableAlign()
            } else {
                buffer.fixFormulas("@", replace: [:], limit: buffer.tableCurrentDataLine() - 1, delta: lines)
                do {
                    try buffer.tableRecalculate(all: true)
                } catch let unsupported as Calc.Unsupported {
                    throw Failure.message("The table's formulas need Emacs: \(unsupported.reason)")
                }
            }
        }
        buffer.point = 0
        buffer.forwardLine(row)
        return buffer.point
    }

    /// `org-end-of-meta-data t`: past planning, drawers and the property drawer.
    static func skipMetaData(_ buffer: EmacsBuffer) {
        while buffer.point < buffer.length {
            let line = buffer.substring(buffer.point, buffer.lineEnd(buffer.point))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: "^(SCHEDULED|DEADLINE|CLOSED):", options: .regularExpression) != nil {
                buffer.forwardLine(1)
            } else if trimmed.range(of: "^:[\\w-]+:$", options: .regularExpression) != nil {
                while buffer.forwardLine(1) == 0 {
                    if buffer.substring(buffer.point, buffer.lineEnd(buffer.point)).trimmingCharacters(in: .whitespaces).uppercased() == ":END:" {
                        buffer.forwardLine(1)
                        break
                    }
                }
            } else {
                break
            }
        }
    }

    /// `org-capture-place-item`: after the last item of the first list in the entry (the file
    /// for a file target), or at the end of the entry's text.
    static func placeItem(_ text: String, checkbox: Bool, options: CaptureTemplate.Options, heading: Int?, _ buffer: EmacsBuffer) throws -> Int {
        let prepend = options.prepend
        var item = text.trimmingCharacters(in: .newlines)
        if item.range(of: "^[ \\t]*([-+*]|[0-9]+[.)])[ \\t]", options: .regularExpression) == nil {
            let boxed = item.range(of: "^\\[[ X-]\\]", options: .regularExpression) != nil
            item = "- " + (checkbox && !boxed ? "[ ] " : "") + item
        } else if checkbox, item.range(of: "^[ \\t]*([-+*]|[0-9]+[.)])[ \\t]+\\[[ X-]\\]", options: .regularExpression) == nil {
            item = item.replacingOccurrences(of: "^([ \\t]*([-+*]|[0-9]+[.)])[ \\t]+)", with: "$1[ ] ", options: .regularExpression)
        }
        let start: Int
        let end: Int
        if let heading {
            start = min(buffer.length, buffer.lineEnd(heading) + 1)
            buffer.point = buffer.lineEnd(heading)
            nextHeading(buffer)
            end = buffer.point
        } else {
            start = 0
            end = buffer.length
        }
        // The first list's items in the range.
        buffer.point = start
        var items: [(start: Int, end: Int, indent: String)] = []
        while buffer.point < end {
            let line = buffer.substring(buffer.point, buffer.lineEnd(buffer.point))
            // A `*` bullet needs indentation; at the margin it starts a heading.
            if let m = line.firstMatch(of: /^([ \t]*)([-+*]|[0-9]+[.)])[ \t]/), m.2 != "*" || !m.1.isEmpty {
                if let first = items.first, String(m.1) != first.indent {
                    // A nested item belongs to the current one.
                } else {
                    items.append((buffer.point, buffer.point, String(m.1)))
                }
            } else if !items.isEmpty, !line.trimmingCharacters(in: .whitespaces).isEmpty,
                      line.prefix(while: { $0 == " " || $0 == "\t" }).count <= (items.first?.indent.count ?? 0) {
                break
            }
            if buffer.forwardLine(1) != 0 { break }
            if !items.isEmpty { items[items.count - 1].end = buffer.point }
        }
        if let first = items.first {
            let indent = first.indent
            let indented = item.components(separatedBy: "\n").enumerated().map { $0.offset == 0 ? indent + $0.element : indent + $0.element }.joined(separator: "\n")
            if prepend {
                buffer.point = first.start
            } else {
                buffer.point = items.last!.end
                // Before blank lines that end the list.
                while buffer.point > first.start {
                    let previous = buffer.lineStart(buffer.point - 1)
                    guard buffer.substring(previous, buffer.point - 1).trimmingCharacters(in: .whitespaces).isEmpty else { break }
                    buffer.point = previous
                }
            }
            if !buffer.bolp { buffer.insert("\n") }
            // In an existing list, at most one blank line between items.
            if !prepend {
                deleteEmptyLinesBefore(buffer)
                buffer.insert(String(repeating: "\n", count: min(1, options.before ?? 0)))
            }
            let at = buffer.point
            buffer.insert(indented + "\n")
            if prepend { emptyLinesAfter(buffer, min(1, options.after)) }
            return at
        } else {
            buffer.point = prepend ? start : end
            if !buffer.bolp { buffer.insert("\n") }
            deleteEmptyLinesBefore(buffer)
            buffer.insert(String(repeating: "\n", count: options.before ?? 0))
            let at = buffer.point
            buffer.insert(item + "\n")
            emptyLinesAfter(buffer, options.after)
            return at
        }
    }
}
