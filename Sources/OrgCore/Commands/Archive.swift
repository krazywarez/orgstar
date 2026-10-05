import Foundation

// Archiving (`org-archive-subtree`, Org 9.8.7) with the defaults: location "%s_archive::",
// context info time, file, olpath, category, todo and itags, inherited tags added only within
// the same file, no marking DONE, the archive file's header for a new file.

extension EmacsBuffer {
    /// The first value of `#+NAME:` in the buffer, as `org-collect-keywords` with UNIQUE.
    func keyword(_ name: String) -> String? {
        saveExcursion {
            point = 0
            guard let match = searchForward("^[ \\t]*#\\+" + NSRegularExpression.escapedPattern(for: name) + ":[ \\t]*(.*?)[ \\t]*$") else { return nil }
            return substring(match[1]!.lowerBound, match[1]!.upperBound)
        }
    }

    /// `org-back-to-heading-or-point-min`.
    func backToHeadingOrPointMin() {
        if beforeFirstHeading { point = 0 } else { _ = try? backToHeading() }
    }

    static let propertyDrawerPattern = "^[ \\t]*:PROPERTIES:[ \\t]*\\n(?:[ \\t]*:\\S+:(?:[ \\t].*)?[ \\t]*\\n)*?[ \\t]*:END:[ \\t]*$"

    /// `org-insert-property-drawer`.
    func insertPropertyDrawer() {
        saveExcursion {
            backToHeadingOrPointMin()
            if beforeFirstHeading {
                while bolp, lookingAt("^[ \\t]*#[ \\t]") != nil || lookingAt("^[ \\t]*#$") != nil { if forwardLine(1) != 0 { break } }
            } else {
                forwardLine(1)
                if lookingAt(planningPattern) != nil { forwardLine(1) }
            }
            guard looking(Self.propertyDrawerPattern, caseInsensitive: true, setsMatch: false) == nil else { return }
            if bolp, point > 0 { point -= 1 }
            let begin = bobp ? point : point + 1
            if !bobp { insert("\n") }
            insert(":PROPERTIES:\n:END:")
            if eobp || begin == 0 { insert("\n") }
        }
    }

    /// `org-get-property-block` with FORCE: the body range of the entry's property drawer.
    func propertyBlock(_ begin: Int) -> Range<Int> {
        saveExcursion {
            point = begin
            if beforeFirstHeading {
                while bolp, lookingAt("^[ \\t]*#[ \\t]") != nil || lookingAt("^[ \\t]*#$") != nil { if forwardLine(1) != 0 { break } }
            } else {
                forwardLine(1)
                if lookingAt(planningPattern) != nil { forwardLine(1) }
            }
            if let match = looking(Self.propertyDrawerPattern) {
                forwardLine(1)
                return point..<lineStart(match[0]!.upperBound)
            }
            point = begin
            insertPropertyDrawer()
            let match = searchForward(Self.propertyDrawerPattern)!
            let at = lineStart(match[0]!.upperBound)
            return at..<at
        }
    }

    /// `org-entry-put` for an ordinary property, with `org-property-format` "%-10s %s".
    func entryPut(_ name: String, _ value: String) {
        saveExcursion {
            backToHeadingOrPointMin()
            let range = propertyBlock(point)
            point = range.lowerBound
            let end = range.upperBound
            if let match = searchForward("^[ \\t]*:" + NSRegularExpression.escapedPattern(for: name) + ":(?:[ \\t]+.*?)?[ \\t]*$", bound: end) {
                deleteRegion(match[0]!.lowerBound, match[0]!.upperBound)
                point = match[0]!.lowerBound
            } else {
                point = end
                insert("\n")
                point -= 1
            }
            insert(":" + name + ":")
            insert(" " + value)
            alignNodeProperty()
        }
    }

    /// `org--align-node-property`, with the indentation `org-indent-line` gives property lines
    /// when `org-adapt-indentation` is nil.
    func alignNodeProperty() {
        let start = lineStart(point)
        let line = substring(start, lineEnd(point))
        guard let match = line.range(of: "^([ \\t]*)(:\\S+:)(?:[ \\t]+(.*?))?[ \\t]*$", options: .regularExpression) else { return }
        let parts = line[match]
        let regex = try! NSRegularExpression(pattern: "^([ \\t]*)(:\\S+:)(?:[ \\t]+(.*?))?[ \\t]*$")
        let groups = regex.firstMatch(in: String(parts), range: NSRange(location: 0, length: (String(parts) as NSString).length))!
        let ns = String(parts) as NSString
        let key = ns.substring(with: groups.range(at: 2))
        let value = groups.range(at: 3).location == NSNotFound ? "" : ns.substring(with: groups.range(at: 3))
        let padded = key.padding(toLength: max(10, (key as NSString).length), withPad: " ", startingAt: 0)
        let new = (padded + " " + value).trimmingCharacters(in: .whitespaces)
        let end = lineEnd(point)
        let lineStartOffset = start
        point = lineStartOffset
        deleteRegion(lineStartOffset, end)
        insert(new)
    }

    /// The entry's tags, and its inherited tags (file tags and ancestors' tags), in org's order.
    func tags() -> (local: [String], inherited: [String]) {
        saveExcursion {
            guard (try? backToHeading()) != nil else { return ([], []) }
            func lineTags(_ at: Int) -> [String] {
                saveExcursion {
                    point = at
                    guard let match = lookingAt(SetTags.tagLine), let tags = match[2] else { return [] }
                    return substring(tags.lowerBound, tags.upperBound).split(separator: ":").map(String.init)
                }
            }
            let local = lineTags(point)
            var ancestors: [[String]] = []
            while upHeadingSafe() != nil { ancestors.insert(lineTags(point), at: 0) }
            var inherited: [String] = []
            let fileTags = (keyword("FILETAGS") ?? "").split(whereSeparator: { $0 == ":" || $0 == " " || $0 == "\t" }).map(String.init)
            for tag in fileTags + ancestors.flatMap({ $0 }) where !inherited.contains(tag) && !local.contains(tag) { inherited.append(tag) }
            return (local, inherited)
        }
    }

    /// `org-get-outline-path`: ancestors' titles without statistics cookies, links shown as
    /// their descriptions.
    func outlinePath() -> [String] {
        saveExcursion {
            guard (try? backToHeading()) != nil else { return [] }
            var path: [String] = []
            while upHeadingSafe() != nil {
                let title = saveExcursion { () -> String in
                    guard let match = lookingAt(complexHeadingPattern), let title = match[4] else { return "" }
                    var text = substring(title.lowerBound, title.upperBound)
                    text = text.replacingOccurrences(of: "\\[[0-9]+%\\]|\\[[0-9]+/[0-9]+\\]", with: "", options: .regularExpression)
                    text = text.replacingOccurrences(of: "\\[\\[([^\\]]*)\\]\\[([^\\]]*)\\]\\]", with: "$2", options: .regularExpression)
                    text = text.replacingOccurrences(of: "\\[\\[([^\\]]*)\\]\\]", with: "$1", options: .regularExpression)
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                path.insert(title, at: 0)
            }
            return path
        }
    }

    /// `org-update-statistics-cookies` with point on a heading.
    func updateStatisticsCookies() {
        guard atHeading else {
            updateCheckboxCount()
            return
        }
        saveExcursion {
            let start = try! backToHeading()
            let level = outlineLevel
            var childLevel: Int?
            let end = saveExcursion { () -> Int in
                if outlineNextHeading() { childLevel = outlineLevel }
                return point
            }
            let hasBoxes = saveExcursion { searchForward("^[ \\t]*([-+*]|[0-9]+[.)]) \\[[- X]\\]", bound: end) != nil }
            let todoData = saveExcursion { searchForward(":COOKIE_DATA:.*\\btodo\\b", bound: end) != nil }
            if hasBoxes, !todoData {
                updateCheckboxCount()
            } else if let childLevel, childLevel > level {
                point = end
                updateParentTodoStatistics()
            } else {
                point = start
                while let match = searchForward("((\\[[0-9]*%\\])|(\\[[0-9]*/[0-9]*\\]))", bound: lineEnd(point)) {
                    replace(match[1]!, with: match[2] != nil ? "[100%]" : "[0/0]")
                }
            }
        }
    }
}

public enum Archive {
    /// Where the entry at the caret goes: the archive file (the source itself for an in-file
    /// location) and the heading to file it under, if any.
    public struct Destination: Sendable, Equatable {
        public let path: String
        public let heading: String?
        public var isSameFile: Bool
    }

    public static func destination(_ context: EditContext, sourcePath: String) -> Result<Destination, ArchiveError> {
        let buffer = EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings)
        guard !buffer.beforeFirstHeading else { return .failure(.message("Before first headline")) }
        let spec = buffer.inheritedProperty("ARCHIVE")?.value ?? buffer.keyword("ARCHIVE") ?? "%s_archive::"
        guard let separator = spec.range(of: "::") else { return .failure(.message("Invalid archive location: \"\(spec)\"")) }
        let name = (sourcePath as NSString).lastPathComponent
        let fileFormat = String(spec[..<separator.lowerBound])
        let headingFormat = String(spec[separator.upperBound...])
        let path: String
        if fileFormat.contains(where: { !$0.isWhitespace }) {
            let file = fileFormat.replacingOccurrences(of: "%s", with: name)
            let directory = (sourcePath as NSString).deletingLastPathComponent
            path = ((file as NSString).isAbsolutePath ? file : (directory as NSString).appendingPathComponent(file)).replacingOccurrences(of: "~", with: NSHomeDirectory(), options: .anchored)
        } else {
            path = sourcePath
        }
        let heading = headingFormat.replacingOccurrences(of: "%s", with: name)
        return .success(Destination(path: (path as NSString).standardizingPath, heading: heading.isEmpty ? nil : heading, isSameFile: path == sourcePath))
    }

    public enum ArchiveError: Error, Equatable {
        case message(String)
    }

    public struct Edits: Sendable, Equatable {
        /// For the source; for an in-file archive, everything happens here.
        public let source: EditResult
        /// For the archive file, against its text (empty when it doesn't exist yet).
        public let archive: TextEdit?
    }

    /// `~/` for paths in the home folder, as `abbreviate-file-name`.
    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Archives the subtree at the caret. `archiveText` is the archive file's text, or nil
    /// when it doesn't exist; it's ignored for an in-file destination.
    public static func run(
        _ context: EditContext, sourcePath: String, destination: Destination, archiveText: String?
    ) -> Result<Edits, ArchiveError> {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = context.calendar
        formatter.timeZone = context.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd EEE HH:mm"
        let time = formatter.string(from: context.now)
        let archive = destination.isSameFile ? nil : EmacsBuffer(archiveText ?? "", point: 0, settings: context.tree.settings, options: context.options)
        var archiveEdit: TextEdit?
        let step = commitBuffer(context) { source in
            let target = archive ?? source
            let level: Int
            let headingText: String?
            if let heading = destination.heading, let stars = heading.range(of: "^\\*+", options: .regularExpression) {
                level = heading[stars].count
                headingText = heading
            } else {
                level = 0
                headingText = nil
            }
            let origin = source.marker(source.point)
            defer { source.release(origin) }
            try source.backToHeading()
            let (local, inherited) = source.tags()
            let category = source.inheritedProperty("CATEGORY")?.value ?? source.keyword("CATEGORY")
                ?? ((sourcePath as NSString).lastPathComponent as NSString).deletingPathExtension
            let todo = source.lookingAt(source.todoLinePattern)?[2].map { source.substring($0.lowerBound, $0.upperBound) }
            let context: [(String, String)] = [
                ("TIME", time), ("FILE", abbreviate(sourcePath)), ("OLPATH", source.outlinePath().joined(separator: "/")),
                ("CATEGORY", category), ("TODO", todo ?? ""), ("ITAGS", inherited.joined(separator: " ")),
            ]
            let tree = try source.copySubtree()
            try target.saveExcursion {
                if !destination.isSameFile, archiveText == nil {
                    target.point = target.length
                    target.insert("\nArchived entries from file \(sourcePath)\n\n")
                }
                target.point = 0
                if let headingText {
                    let pattern = "^" + NSRegularExpression.escapedPattern(for: headingText) + "([ \\t]+:([[:alnum:]_@#%]+:)+)?[ \\t]*$"
                    if let match = target.searchForward(pattern) {
                        target.point = match[0]!.upperBound
                    } else {
                        target.point = target.length
                        if !target.bolp { target.insert("\n") }
                        target.insert("\n" + headingText + "\n")
                        target.forwardLine(-1)
                        target.endOfLine()
                    }
                    target.endOfSubtree()
                    target.skipBackward(EmacsBuffer.whitespace)
                    let blanks = target.looking("[ \\t\\r\\n]*")!
                    target.replace(blanks[0]!, with: "\n\n")
                    target.point = blanks[0]!.lowerBound + 2
                } else {
                    target.point = target.length
                    target.insert("\n")
                }
                try target.pasteSubtree(level: max(1, level + (headingText == nil ? 0 : 1)), tree: tree)
                if !inherited.isEmpty, destination.isSameFile {
                    let all = inherited + local
                    target.saveExcursion {
                        let line = target.saveExcursion { target.lookingAt(SetTags.tagLine) }
                        if let tags = line?[1] {
                            target.point = tags.lowerBound
                            target.skipBackward(EmacsBuffer.blanks)
                            target.deleteRegion(target.point, target.lineEnd(target.point))
                        } else {
                            target.endOfLine()
                        }
                        target.saveExcursion { target.insert(" :" + all.joined(separator: ":") + ":") }
                    }
                    target.alignTags(onLineAt: target.point)
                }
                for (key, value) in context where value.contains(where: { !$0.isWhitespace }) {
                    target.entryPut("ARCHIVE_" + key, value)
                }
            }
            source.point = origin.position
            let range = try source.subtreeRange()
            source.deleteRegion(range.lowerBound, range.upperBound)
            source.saveExcursion {
                source.upHeadingSafe()
                source.updateStatisticsCookies()
            }
            if source.looking("^[ \\t]*$", setsMatch: false) != nil {
                source.endOfLine()
                source.point = source.nextHeadingStart(after: source.point) ?? source.length
            }
        }
        if let archive {
            let original = archiveText ?? ""
            if case .commit(let result) = commitBuffer(EditContext(revision: 0, text: original, tree: OrgParser.parse(original), selection: [0..<0]), { $0.replace(0..<$0.length, with: archive.string) }) {
                archiveEdit = result.edits.first
            }
        }
        switch step {
        case .commit(let result): return .success(Edits(source: result, archive: archiveEdit))
        case .failed(let message): return .failure(.message(message))
        case .prompt: return .failure(.message("unexpected prompt"))
        }
    }
}
