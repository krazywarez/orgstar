import Foundation

// Footnotes (`org-footnote.el`, Org 9.8.7) with the defaults: `org-footnote-section`
// "Footnotes", `org-footnote-auto-label` t, `org-footnote-define-inline` and
// `org-footnote-auto-adjust` nil.

extension EmacsBuffer {
    struct FootnoteReference: Equatable {
        /// Nil for anonymous references.
        var label: String?
        var begin: Int
        /// After the closing bracket.
        var end: Int
        /// An inline definition's text.
        var contents: Range<Int>?
        /// The label of the definition the reference sits in.
        var definition: String?
    }

    struct FootnoteDefinition {
        var label: String
        var begin: Int
        var contentsBegin: Int?
        /// The line after its last non-blank line.
        var end: Int
    }

    static let footnoteSection = "Footnotes"

    private func footnoteTree() -> OrgTree { OrgParser.parse(string) }

    /// Definitions in buffer order, ending as `org-element--footnote-separator` ends them.
    func footnoteDefinitions(_ tree: OrgTree? = nil) -> [FootnoteDefinition] {
        let tree = tree ?? footnoteTree()
        return tree.root.descendants().filter { $0.kind == .footnoteDefinition }.compactMap { node in
            saveExcursion {
                point = node.range.lowerBound
                guard let match = lookingAt("\\[fn:([-_\\w]+)\\]") else { return nil }
                let label = substring(match[1]!.lowerBound, match[1]!.upperBound)
                point = lineEnd(point)
                let separator = searchForward("^(?:\\*+ |\\[fn:[-_\\w]+\\]|([ \\t]*\\n){2,})", caseInsensitive: false)
                var raw = length
                if let separator {
                    raw = separator[0]!.lowerBound
                    if separator[1] != nil {
                        point = raw
                        skipForward([32, 13, 9, 10])
                        raw = eobp ? length : lineStart(point)
                    }
                }
                point = match[0]!.upperBound
                skipForward([32, 13, 9, 10])
                let contentsBegin: Int? = point >= raw ? nil : lineStart(point) == node.range.lowerBound ? point : lineStart(point)
                point = raw
                skipBackward([32, 13, 9, 10])
                forwardLine(1)
                return FootnoteDefinition(label: label, begin: node.range.lowerBound, contentsBegin: contentsBegin, end: point)
            }
        }
    }

    /// References in buffer order.
    func footnoteReferences(_ tree: OrgTree? = nil) -> [FootnoteReference] {
        let tree = tree ?? footnoteTree()
        let definitions = footnoteDefinitions(tree)
        return tree.root.descendants().filter { $0.kind == .footnoteReference }.compactMap { node in
            saveExcursion {
                point = node.range.lowerBound
                guard let match = lookingAt("\\[fn:([-_\\w]*)(:)?") else { return nil }
                let label = match[1]!.isEmpty ? nil : substring(match[1]!.lowerBound, match[1]!.upperBound)
                let contents = match[2] != nil ? match[0]!.upperBound..<(node.range.upperBound - 1) : nil
                let holder = definitions.last { $0.begin <= node.range.lowerBound && node.range.lowerBound < $0.end }
                return FootnoteReference(label: label, begin: node.range.lowerBound, end: node.range.upperBound, contents: contents, definition: holder?.label)
            }
        }
    }

    /// `org-footnote-at-reference-p`.
    func footnoteReferenceAtPoint() -> FootnoteReference? {
        footnoteReferences().first { $0.begin <= point && point < $0.end }
    }

    /// `org-footnote-at-definition-p`: anywhere in a definition.
    func footnoteDefinitionAtPoint() -> FootnoteDefinition? {
        footnoteDefinitions().first { $0.begin <= point && point < max($0.end, $0.begin + 1) }
    }

    /// `org-footnote-all-labels`.
    func footnoteLabels() -> [String] {
        let tree = footnoteTree()
        var all: [String] = []
        for label in footnoteReferences(tree).compactMap(\.label) + footnoteDefinitions(tree).map(\.label) where !all.contains(label) {
            all.append(label)
        }
        return all
    }

    /// `org-footnote-unique-label`.
    func footnoteUniqueLabel(_ current: [String]) -> String {
        var count = 1
        while current.contains(String(count)) { count += 1 }
        return String(count)
    }

    /// Where `org-footnote-get-definition` finds LABEL: its definition, or an inline reference.
    func footnoteDefinitionStart(_ label: String) -> Int? {
        let tree = footnoteTree()
        let definition = footnoteDefinitions(tree).first { $0.label == label }?.begin
        let inline = footnoteReferences(tree).first { $0.label == label && $0.contents != nil && $0.begin > 0 }?.begin
        return [definition, inline].compactMap { $0 }.min()
    }

    /// `org-footnote--allow-reference-p` for a labeled reference.
    func footnoteReferenceAllowed() -> Bool {
        if bolp { return false }
        let tree = footnoteTree()
        var chain: [SyntaxNode] = []
        var node = tree.root
        while let child = node.child(containing: point) {
            chain.append(child)
            node = child
        }
        if chain.contains(where: { $0.kind == .heading }), let heading = chain.first(where: { $0.kind == .heading }),
           lineStart(point) == heading.range.lowerBound {
            guard let title = heading.firstChild(.title) else { return false }
            let tags = heading.tokens.first { $0.kind == .tags }
            return point >= title.range.lowerBound && tags.map { point < $0.range.lowerBound } ?? true
        }
        let objects: Set<SyntaxKind> = [.bold, .italic, .underline, .strikeThrough, .verbatim, .code, .link, .linkDescription, .timestamp,
                                        .footnoteReference, .statisticsCookie, .target, .macro, .inlineSourceBlock, .latexFragment, .lineBreak, .superscript, .subscript, .entity, .radioTarget,
                                        .citation, .citationReference, .exportSnippet, .inlineBabelCall, .itemTag]
        let containers: Set<SyntaxKind> = [.document, .zerothSection, .section, .plainList, .item, .drawer]
        let element = chain.last { !objects.contains($0.kind) && !containers.contains($0.kind) }
        switch element?.kind {
        case nil, .paragraph, .tableRow, .tableCell:
            break
        case .footnoteDefinition:
            let definition = footnoteDefinitions(tree).first { $0.begin == element!.range.lowerBound }
            if let begin = definition?.contentsBegin, point >= begin { break }
            return character(at: point).map { [32, 9, 10, 13].contains($0) } ?? false
        case .block:
            let block = element!
            let opening = saveExcursion { () -> Bool in
                point = block.range.lowerBound
                return lookingAt("[ \\t]*#\\+begin_verse") != nil
            }
            guard opening, let wrapper = Wrappers.starting(at: block.range.lowerBound, in: tree) else { return false }
            let contentsBegin = lineEnd(block.range.lowerBound) + 1
            return point >= contentsBegin && point < wrapper.closeLine
        default:
            // Blank lines after an element.
            let after = saveExcursion { () -> Int in
                point = element!.range.upperBound
                skipBackward([32, 13, 9, 10])
                forwardLine(1)
                return point
            }
            return point >= after
        }
        guard let object = chain.last(where: { objects.contains($0.kind) }) else { return true }
        if point == object.range.lowerBound { return true }
        if chain.contains(where: { $0.kind == .link }) { return false }
        switch object.kind {
        case .bold, .italic, .underline, .strikeThrough, .superscript, .subscript, .radioTarget:
            return point > object.range.lowerBound && point <= object.range.upperBound - 1
        default:
            return false
        }
    }

    /// `org-back-over-empty-lines`, returning the number of empty lines passed.
    @discardableResult
    func backOverEmptyLinesCount() -> Int {
        let position = point
        backOverEmptyLines()
        return countLines(point, position)
    }

    /// `org-end-of-meta-data` with FULL t.
    func endOfMetaDataFull() {
        endOfMetaData()
        guard !atHeading else { return }
        let end = saveExcursion { () -> Int in outlineNextHeading(); return point }
        while !eobp {
            if lookingAt("[ \\t]*$|^[ \\t]*CLOCK:") != nil {
                forwardLine(1)
            } else if lookingAt("[ \\t]*:[-_\\w]+:[ \\t]*$") != nil {
                guard searchForward("^[ \\t]*:END:[ \\t]*$", bound: end, caseInsensitive: true) != nil else { return }
                forwardLine(1)
            } else {
                return
            }
        }
    }

    /// `org-footnote--clear-footnote-section`.
    func clearFootnoteSection() {
        point = 0
        let pattern = "^\\*+ +" + NSRegularExpression.escapedPattern(for: Self.footnoteSection) + "[ \\t]*$"
        while let match = searchForward(pattern, caseInsensitive: false) {
            point = match[0]!.lowerBound
            let end = endOfSubtree(toHeading: true)
            deleteRegion(match[0]!.lowerBound, end)
            point = match[0]!.lowerBound
        }
        point = length
        skipBackward([32, 13, 9, 10])
        if !bobp {
            forwardLine(1)
            if eolp { insert("\n") }
        }
        deleteRegion(point, length)
        if saveExcursion({ backOverEmptyLinesCount() }) == 0 { insert("\n") }
        insert("* " + Self.footnoteSection + "\n")
    }

    /// `org-footnote-create-definition`: the definition's start.
    func createFootnoteDefinition(_ label: String) -> Int {
        saveExcursion {
            let pattern = "^\\*+[ \\t]+" + NSRegularExpression.escapedPattern(for: Self.footnoteSection) + "[ \\t]*$"
            point = 0
            if let match = searchForward(pattern, caseInsensitive: false) {
                point = match[0]!.upperBound
                endOfMetaDataFull()
                if !bolp { insert("\n") }
            } else {
                clearFootnoteSection()
            }
            if backOverEmptyLinesCount() == 0 { insert("\n") }
            insert("[fn:\(label)] \n")
            forwardLine(-1)
            return point
        }
    }

    /// `org-footnote-goto-definition`.
    func gotoFootnoteDefinition(_ label: String, at start: Int) {
        point = start
        if let match = lookingAt("\\[fn:" + NSRegularExpression.escapedPattern(for: label) + "[]:]") { point = match[0]!.upperBound }
    }

    /// `org-footnote-new`.
    func newFootnote() throws {
        let all = footnoteLabels()
        let label = footnoteUniqueLabel(all)
        guard footnoteReferenceAllowed() else { throw UserError(message: "Cannot insert a footnote here") }
        insert("[fn:\(label)]")
        gotoFootnoteDefinition(label, at: createFootnoteDefinition(label))
    }

    /// `org-footnote-goto-previous-reference`.
    func gotoPreviousFootnoteReference(_ label: String) throws {
        let references = footnoteReferences().filter { $0.label == label }
        let opening = "[fn:\(label)".utf16.count + 1
        guard let reference = references.last(where: { $0.begin + opening <= point }) ?? references.first(where: { $0.begin >= point }) else {
            throw UserError(message: "Cannot find reference of footnote \"\(label)\"")
        }
        point = reference.begin
    }

    /// `org-footnote--set-label`, with point at the reference or definition.
    func setFootnoteLabel(_ label: String) {
        point += 4
        if character(at: point) == 58 {
            insert(label)
        } else if let match = lookingAt("([-_\\w]+)") {
            replace(match[1]!, with: label)
            point = match[1]!.lowerBound + label.utf16.count
        }
    }

    /// `org-footnote--collect-references`, in org's reading order: nested references follow
    /// the definition they sit in.
    func collectFootnoteReferences(anonymous: Bool = false) -> [FootnoteReference] {
        let references = footnoteReferences().filter { anonymous || $0.label != nil }
        var nested: [String: [String?]] = [:]
        for reference in references { if let holder = reference.definition { nested[holder, default: []].append(reference.label) } }
        var ordered: [FootnoteReference] = []
        func add(_ reference: FootnoteReference, allowNested: Bool) {
            guard allowNested || reference.definition == nil else { return }
            ordered.append(reference)
            for label in nested[reference.label ?? ""] ?? [] where reference.label != nil {
                guard let r = references.last(where: { $0.label == label }), !ordered.contains(r) else { continue }
                add(r, allowNested: true)
            }
        }
        for reference in references { add(reference, allowNested: false) }
        return ordered
    }

    /// `org-footnote--collect-definitions`: label and text, last first, as org's alist.
    func collectFootnoteDefinitions(delete: Bool) -> [(label: String, text: String)] {
        var seen: Set<String> = []
        var found: [(label: String, text: String, range: Range<Int>)] = []
        for definition in footnoteDefinitions() where !seen.contains(definition.label) {
            seen.insert(definition.label)
            let begin = saveExcursion { () -> Int in
                point = definition.begin
                skipBackward([32, 13, 9, 10])
                if bobp { return point }
                forwardLine(1)
                return point
            }
            let text = substring(begin, definition.end).trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r"))
            found.append((definition.label, text, begin..<definition.end))
        }
        if delete { for f in found.reversed() { deleteRegion(f.range.lowerBound, f.range.upperBound) } }
        return found.reversed().map { ($0.label, $0.text) }
    }

    /// `org-footnote-renumber-fn:N`.
    func renumberFootnotes() {
        var c = 0
        let references = collectFootnoteReferences().filter { $0.label!.range(of: "^[0-9]+$", options: .regularExpression) != nil }
        var alist: [String: String] = [:]
        for label in references.map({ $0.label! }) where alist[label] == nil {
            c += 1
            alist[label] = String(c)
        }
        let markers = references.map { marker($0.begin) }
        for (reference, m) in zip(references, markers) {
            point = m.position
            setFootnoteLabel(alist[reference.label!]!)
        }
        markers.forEach(release)
        point = 0
        while let match = searchForward("^\\[fn:([0-9]+)\\]", caseInsensitive: false) {
            let old = substring(match[1]!.lowerBound, match[1]!.upperBound)
            let new = alist[old] ?? { c += 1; return String(c) }()
            replace(match[1]!, with: new)
            point = match[1]!.lowerBound + new.utf16.count + 1
        }
    }

    /// `org-footnote-sort`.
    func sortFootnotes() {
        let references = collectFootnoteReferences()
        let definitions = collectFootnoteDefinitions(delete: true)
        clearFootnoteSection()
        var inserted: [String] = []
        for reference in references where !inserted.contains(reference.label!) && reference.contents == nil {
            inserted.append(reference.label!)
            insert("\n" + (definitions.first { $0.label == reference.label }?.text ?? "[fn:\(reference.label!)] DEFINITION NOT FOUND.") + "\n")
        }
        for definition in definitions where !inserted.contains(definition.label) {
            insert("\n" + definition.text + "\n")
        }
    }

    /// `org-footnote-normalize`.
    func normalizeFootnotes() {
        enum Key: Equatable {
            case label(String)
            case anonymous(Int)
        }
        var n = 0
        var translations: [String: String] = [:]
        var definitions: [(key: Key, text: String)] = []
        let collected = collectFootnoteReferences(anonymous: true)
        let markers = collected.map { marker($0.begin) }
        var keys: [Key] = []
        for (reference, m) in zip(collected, markers) {
            let new: String
            let key: Key
            if let label = reference.label {
                if let known = translations[label] {
                    new = known
                } else {
                    n += 1
                    new = String(n)
                    translations[label] = new
                }
                key = .label(label)
            } else {
                n += 1
                new = String(n)
                key = .anonymous(n)
            }
            keys.append(key)
            point = m.position
            setFootnoteLabel(new)
            if let contents = reference.contents {
                let size = contents.count
                let removed = substring(point, point + size + 1)
                deleteRegion(point, point + size + 1)
                let text = "[fn:\(new)] " + String(removed.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r"))
                definitions.insert((key, text), at: 0)
            }
        }
        markers.forEach(release)
        definitions += collectFootnoteDefinitions(delete: true).map { (Key.label($0.label), $0.text) }
        clearFootnoteSection()
        var inserted: [Key] = []
        for key in keys where !inserted.contains(key) {
            inserted.append(key)
            let stored = definitions.first { $0.key == key }?.text
            let text: String
            switch key {
            case .anonymous(let number):
                text = stored ?? "[fn:\(number)] DEFINITION NOT FOUND."
            case .label(let label):
                let new = translations[label]!
                if let stored, let match = stored.firstMatch(of: /^\[fn:(.*?)\]/) {
                    text = stored.replacingCharacters(in: match.1.startIndex..<match.1.endIndex, with: new)
                } else {
                    text = stored ?? "[fn:\(new)] DEFINITION NOT FOUND."
                }
            }
            insert("\n" + text + "\n")
        }
        for definition in definitions where !inserted.contains(definition.key) {
            n += 1
            let number = n
            let text = definition.text.replacingOccurrences(of: "(?m)^\\[fn:[-_\\w]+\\]", with: "[fn:\(number)]", options: .regularExpression)
            insert("\n" + text + "\n")
        }
    }

    /// `org-footnote-delete`: the message to show.
    func deleteFootnote() throws -> String {
        let label: String
        if let reference = footnoteReferenceAtPoint() {
            guard let l = reference.label else {
                deleteRegion(reference.begin, reference.end)
                return "Anonymous footnote removed"
            }
            label = l
        } else if let definition = footnoteDefinitionAtPoint() {
            label = definition.label
        } else {
            throw UserError(message: "Don't know which footnote to remove")
        }
        var references = 0
        while let reference = footnoteReferences().first(where: { $0.label == label }) {
            deleteRegion(reference.begin, reference.end)
            references += 1
        }
        var definitions = 0
        while let definition = footnoteDefinitions().first(where: { $0.label == label }) {
            let begin = saveExcursion { () -> Int in
                point = definition.begin
                skipBackward([32, 13, 9, 10])
                if bobp { return point }
                forwardLine(1)
                return point
            }
            deleteRegion(begin, definition.end)
            definitions += 1
        }
        return "\(definitions) definition(s) of and \(references) reference(s) of footnote \(label) removed"
    }
}

/// C-c C-x f: `org-footnote-action`. On a reference, goes to its definition; on a definition's
/// label, back to a reference; elsewhere inserts a new footnote, or where one can't go, offers
/// the footnote menu.
public struct FootnoteAction: OrgCommand {
    let special: Bool
    public init(special: Bool = false) { self.special = special }
    public var id: String { special ? "org.footnote.menu" : "org.footnote.action" }
    public var title: String { special ? "Footnote Menu" : "Footnote Action" }
    public func applies(in context: EditContext) -> Bool { true }

    static let menu = FastSelection(items: [
        .option(key: "s", name: "sort"), .option(key: "r", name: "renumber fn:N"), .option(key: "S", name: "renumber and sort"),
        .option(key: "n", name: "normalize"), .option(key: "d", name: "delete"),
    ], multiple: false)

    public func run(in context: EditContext) -> CommandStep {
        let buffer = EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings, options: context.options)
        if !special {
            if let reference = buffer.footnoteReferenceAtPoint() {
                guard let label = reference.label else { return move(context, to: reference.contents!.lowerBound) }
                if let start = buffer.footnoteDefinitionStart(label) {
                    buffer.gotoFootnoteDefinition(label, at: start)
                    return move(context, to: buffer.point, message: Self.definitionMessage)
                }
                guard let answer = context.answers["create"] else {
                    return .prompt(Prompt(key: "create", message: "No definition for \(label).  Create one?", choices: ["yes", "no"]))
                }
                guard answer == "yes" else { return .failed("Quit") }
                return commitBuffer(context) { buffer in
                    buffer.gotoFootnoteDefinition(label, at: buffer.createFootnoteDefinition(label))
                }
            }
            if let definition = buffer.footnoteDefinitions().first(where: { $0.begin <= context.caret && context.caret < ($0.contentsBegin ?? $0.end) }) {
                return commitBuffer(context) { try $0.gotoPreviousFootnoteReference(definition.label) }
            }
            if buffer.footnoteReferenceAllowed() { return commitBuffer(context) { try $0.newFootnote() } }
        }
        guard let key = context.answers["footnote"] else {
            return .prompt(Prompt(key: "footnote", message: "Footnotes: [s]ort | [r]enumber fn:N | [S]=r+s | [n]ormalize | [d]elete", fast: Self.menu))
        }
        var message: String?
        let step = commitBuffer(context) { buffer in
            let caret = buffer.marker(buffer.point)
            defer {
                buffer.point = caret.position
                buffer.release(caret)
            }
            switch key {
            case "s": buffer.sortFootnotes()
            case "r": buffer.renumberFootnotes()
            case "S":
                buffer.renumberFootnotes()
                buffer.sortFootnotes()
            case "n": buffer.normalizeFootnotes()
            case "d": message = try buffer.deleteFootnote()
            default: throw EmacsBuffer.UserError(message: "No such footnote command \(key)")
            }
        }
        guard case .commit(let result) = step, let message else { return step }
        return .commit(EditResult(baseRevision: result.baseRevision, edits: result.edits, selection: result.selection, effects: result.effects + [.message(message)]))
    }

    static let definitionMessage = "Edit definition and go back with `C-c &' or, if unique, with `C-c C-c'."

    private func move(_ context: EditContext, to offset: Int, message: String? = nil) -> CommandStep {
        .commit(EditResult(baseRevision: context.revision, edits: [], selection: [offset..<offset], effects: message.map { [.message($0)] } ?? []))
    }
}
