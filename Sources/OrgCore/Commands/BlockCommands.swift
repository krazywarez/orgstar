import Foundation

// Blocks (Org 9.8.7): `org-insert-structure-template` (C-c C-,) with
// `org-structure-template-alist`, and `org-edit-special` (C-c ') on src, example and export
// blocks with Doom's `org-src-preserve-indentation` t: the block's lines as they are, commas
// that protect `*` and `#+` lines taken off while editing and put back after.

/// An entry of `org-structure-template-alist`: a key and the block type it inserts.
public struct StructureTemplate: Sendable, Equatable, Codable {
    public var key: String
    public var type: String

    public init(key: String, type: String) {
        self.key = key
        self.type = type
    }

    /// Org's default `org-structure-template-alist`.
    public static let defaults: [StructureTemplate] = [
        .init(key: "a", type: "export ascii"), .init(key: "c", type: "center"), .init(key: "C", type: "comment"),
        .init(key: "e", type: "example"), .init(key: "E", type: "export"), .init(key: "h", type: "export html"),
        .init(key: "l", type: "export latex"), .init(key: "q", type: "quote"), .init(key: "s", type: "src"),
        .init(key: "v", type: "verse"),
    ]

    /// The defaults with `extra` over them: an entry with a default's key takes its place, the
    /// others follow.
    public static func merged(_ extra: [StructureTemplate]) -> [StructureTemplate] {
        defaults.map { entry in extra.first { $0.key == entry.key } ?? entry } + extra.filter { entry in !defaults.contains { $0.key == entry.key } }
    }
}

/// C-c C-,: `org-insert-structure-template`. Asks for a block type by key (Tab to type one),
/// then inserts an empty block, or wraps the selection. Keys of more than one letter take two
/// strokes, as `org--insert-structure-template-mks` makes them: the first letter, then the
/// second (Tab for the one-letter key).
public struct InsertStructureTemplate: OrgCommand {
    public init() {}
    public var id: String { "org.structure-template" }
    public var title: String { "Insert Structure Template" }
    public func applies(in context: EditContext) -> Bool { true }

    /// The templates under each first letter, in the order the letters first appear.
    static func groups(_ templates: [StructureTemplate]) -> [(letter: Character, templates: [StructureTemplate])] {
        var groups: [(letter: Character, templates: [StructureTemplate])] = []
        for template in templates {
            guard let letter = template.key.first else { continue }
            if let index = groups.firstIndex(where: { $0.letter == letter }) {
                groups[index].templates.append(template)
            } else {
                groups.append((letter, [template]))
            }
        }
        return groups
    }

    /// `org--insert-structure-template-unique-keys`: the second stroke of each key, Tab for a
    /// one-letter key; nil when keys can't be told apart.
    static func secondKeys(_ templates: [StructureTemplate]) -> [Character]? {
        var used: [String: Int] = [:]
        for (index, template) in templates.enumerated().sorted(by: { ($0.element.key.count, $0.offset) < ($1.element.key.count, $1.offset) }) {
            let key = Array(template.key)
            let candidate: String? = switch key.count {
            case 1: String(key) + "\t"
            case 2: String(key)
            default: key.dropFirst().map { String(key[0]) + String($0) }.first { used[$0] == nil }
            }
            guard let candidate, used[candidate] == nil else { return nil }
            used[candidate] = index
        }
        let byIndex = Dictionary(uniqueKeysWithValues: used.map { ($1, $0) })
        return templates.indices.map { Array(byIndex[$0]!)[1] }
    }

    public func run(in context: EditContext) -> CommandStep {
        let templates = context.options.structureTemplates ?? StructureTemplate.defaults
        let groups = Self.groups(templates)
        guard let key = context.answers["template"] else {
            let items = groups.map { group -> FastSelection.Item in
                let names = group.templates.map(\.type)
                let name = names.count == 1 ? names[0] : names.prefix(3).joined(separator: ", ") + (names.count > 3 ? ", ..." : "")
                return FastSelection.Item.option(key: group.letter, name: name)
            } + [.option(key: "\t", name: "other (Tab)")]
            return .prompt(Prompt(key: "template", message: "Insert block: [key] or Tab to type one", fast: FastSelection(items: items, multiple: false)))
        }
        let type: String
        if key == "\t" {
            guard let typed = context.answers["type"] else { return .prompt(Prompt(key: "type", message: "Structure type:")) }
            guard !typed.isEmpty else { return .failed("Empty structure type") }
            type = typed
        } else {
            guard let group = groups.first(where: { String($0.letter) == key }) else { return .failed("Quit") }
            if group.templates.count == 1 {
                type = group.templates[0].type
            } else {
                guard let seconds = Self.secondKeys(group.templates) else {
                    return .failed("Could not make unique key for `\(group.templates.last!.key)'")
                }
                guard let second = context.answers["template2"] else {
                    let items = zip(seconds, group.templates).map { FastSelection.Item.option(key: $0, name: $1.type) }
                    return .prompt(Prompt(key: "template2", message: "Insert block: [key]", fast: FastSelection(items: items, multiple: false)))
                }
                guard let index = seconds.firstIndex(where: { String($0) == second }) else { return .failed("Quit") }
                type = group.templates[index].type
            }
        }
        let region = context.selection.first.flatMap { $0.isEmpty ? nil : $0 }
        return commitBuffer(context) { buffer in
            try buffer.insertStructureTemplate(type, region: region)
        }
    }
}

extension EmacsBuffer {
    func insertStructureTemplate(_ type: String, region: Range<Int>?) throws {
        let name = String(type.split(separator: " ").first ?? "")
        let extended = type.range(of: "^(src|export)$", options: [.regularExpression, .caseInsensitive]) != nil
        let verbatim = type.range(of: "^(example|export|src|comment)", options: [.regularExpression, .caseInsensitive]) != nil
        let upcase = name == name.uppercased()
        let regionEnd = region.map { marker($0.upperBound) }
        defer { regionEnd.map(release) }
        if let region { point = region.lowerBound }
        let column = currentIndentation
        let atIndentation = saveExcursion { () -> Bool in
            skipBackward([32, 9])
            return bolp
        }
        if atIndentation { point = lineStart(point) } else { insert("\n") }
        saveExcursion {
            indentTo(column)
            insert("#+\(upcase ? "BEGIN" : "begin")_\(type)\(extended ? " " : "")\n")
            if let regionEnd {
                if verbatim { escapeCode(from: point, to: regionEnd.position) }
                point = regionEnd.position
                // Without the blank lines at the region's end.
                skipBackward([32, 13, 9, 10])
                if !eolp {
                    insert("\n")
                    forwardLine(-1)
                }
                point = lineEnd(point)
            }
            if !bolp { insert("\n") }
            indentTo(column)
            insert("#+\(upcase ? "END" : "end")_\(name)")
            if let blank = lookingAt("[ \\t]*$"), let whole = blank[0] {
                deleteRegion(whole.lowerBound, whole.upperBound)
            } else {
                insert("\n")
            }
            if eobp, !bolp { insert("\n") }
        }
        if extended {
            point = lineEnd(point)
        } else {
            forwardLine(1)
            skipForward([32, 9])
        }
    }

    /// `org-escape-code-in-region`: a comma before lines that would read as headings or
    /// keywords.
    func escapeCode(from start: Int, to end: Int) {
        let limit = marker(end)
        defer { release(limit) }
        point = start
        while point < limit.position, let match = searchForward("^[ \\t]*(,*(?:\\*|#\\+))", bound: limit.position, caseInsensitive: false) {
            point = match[1]!.lowerBound
            insert(",")
            point = lineEnd(point)
        }
    }
}

/// A block's text, as `org-edit-special` hands it to an editing buffer.
public struct BlockEdit: Sendable, Equatable {
    /// The lines between the opening and closing lines.
    public let range: Range<Int>
    /// Those lines as they were, to check nothing changed them meanwhile.
    public let original: String
    /// What to edit: the lines with their protecting commas taken off.
    public let content: String
    /// The src block's language, for highlighting.
    public let language: String?
    /// `src`, `example` or `export`; `formulas` or `field` for a table's.
    public let kind: String
    /// A table field's point and coordinate (`@2$3`).
    public var point: Int?
    public var coordinate: String?

    /// What the editor is editing, for its title.
    public var title: String {
        switch kind {
        case Self.formulasKind: "Editing table formulas"
        case Self.fieldKind: "Editing field \(coordinate ?? "")"
        default: "Editing \(language.map { "\($0) " } ?? "")\(kind) block"
        }
    }

    /// `org-unescape-code-in-string`.
    public static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "(?m)^([ \\t]*),(,*(?:\\*|#\\+))", with: "$1$2", options: .regularExpression)
    }

    /// `org-escape-code-in-string`.
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "(?m)^([ \\t]*)(,*(?:\\*|#\\+))", with: "$1,$2", options: .regularExpression)
    }

    /// The block's lines for edited `content`: escaped again, ending in a newline.
    public func lines(for content: String) -> String {
        guard !content.isEmpty else { return "" }
        let escaped = Self.escape(content)
        return escaped.hasSuffix("\n") ? escaped : escaped + "\n"
    }

    /// The src, example or export block whose lines hold `offset`, opening and closing
    /// lines included.
    public static func at(_ offset: Int, text: String, tree: OrgTree) -> BlockEdit? {
        var node = tree.root
        var found: SyntaxNode?
        while let child = node.child(containing: offset) {
            if child.kind == .block { found = child }
            node = child
        }
        guard let block = found else { return nil }
        let ns = text as NSString
        let first = ns.lineRange(for: NSRange(location: block.range.lowerBound, length: 0))
        let opening = ns.substring(with: first)
        guard let header = opening.firstMatch(of: /(?i)^[ \t]*#\+begin_(src|example|export)(?:[ \t]+([^ \t\n]+))?/) else { return nil }
        guard let wrapper = Wrappers.starting(at: block.range.lowerBound, in: tree) else { return nil }
        let start = NSMaxRange(first)
        let end = wrapper.closeLine
        guard start <= end else { return nil }
        let original = ns.substring(with: NSRange(location: start, length: end - start))
        let kind = header.1.lowercased()
        return BlockEdit(range: start..<end, original: original, content: unescape(original),
                         language: kind == "src" ? header.2.map(String.init) : nil, kind: kind)
    }
}

/// C-c ': `org-edit-special` on a src, example or export block: the app edits its text apart,
/// then `ReplaceBlockLines` puts it back.
public struct EditSpecial: OrgCommand {
    public init() {}
    public var id: String { "org.edit-special" }
    public var title: String { "Edit Block" }
    public func applies(in context: EditContext) -> Bool { edit(context) != nil }

    private func edit(_ context: EditContext) -> BlockEdit? {
        BlockEdit.at(context.caret, text: context.text, tree: context.tree) ?? BlockEdit.formulas(at: context.caret, text: context.text)
    }

    public func run(in context: EditContext) -> CommandStep {
        guard let edit = edit(context) else {
            return .failed("No special environment to edit here")
        }
        return .external(.editBlock(edit))
    }
}

/// Writes an edited block back, unless its lines changed meanwhile.
public struct ReplaceBlockLines: OrgCommand {
    public let edit: BlockEdit
    public let content: String
    public init(edit: BlockEdit, content: String) {
        self.edit = edit
        self.content = content
    }
    public var id: String { "internal.replace-block" }
    public var title: String { "Replace Block" }
    public func applies(in context: EditContext) -> Bool { true }
    public func run(in context: EditContext) -> CommandStep {
        let ns = context.text as NSString
        guard edit.range.upperBound <= ns.length, ns.substring(with: NSRange(edit.range)) == edit.original else {
            return .failed("The block changed while you edited it; its edit wasn't saved.")
        }
        if edit.kind == BlockEdit.formulasKind { return edit.installFormulas(content, in: context) }
        if edit.kind == BlockEdit.fieldKind { return edit.installField(content, in: context) }
        let lines = edit.lines(for: content)
        return .commit(EditResult(baseRevision: context.revision, edits: [TextEdit(range: edit.range, replacement: lines)]))
    }
}
