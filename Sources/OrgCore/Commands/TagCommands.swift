import Foundation

/// C-c C-q: `org-set-tags-command`. With keys in `#+TAGS`, fast tag selection; otherwise asks
/// for the tags, completing from the file's tags and the workspace's. Sets them as
/// `org-set-tags` does and realigns.
public struct SetTags: OrgCommand {
    public init() {}
    public var id: String { "org.tags.set" }
    public var title: String { "Set Tags" }
    public func applies(in context: EditContext) -> Bool { entryHeading(at: context.caret, in: context.tree) != nil }

    /// Characters that can't be in a tag separate tags, as org's `org-tag--invalid-char-re`.
    static func tags(from answer: String) -> [String] {
        answer.split { !($0.isLetter || $0.isNumber || "_@#%".contains($0)) }.map(String.init)
    }

    /// `org-get-buffer-tags`: every heading's tags, then `#+FILETAGS`.
    static func bufferTags(_ context: EditContext) -> [String] {
        var names: [String] = []
        let model = DocumentModel(tree: context.tree)
        for heading in model.headings { for tag in heading.localTags where !names.contains(tag) { names.append(tag) } }
        let buffer = EmacsBuffer(context.text, point: 0, settings: context.tree.settings)
        let fileTags = (buffer.keyword("FILETAGS") ?? "").split(whereSeparator: { $0 == ":" || $0 == " " || $0 == "\t" }).map(String.init)
        for tag in fileTags where !names.contains(tag) { names.append(tag) }
        return names
    }

    func inheritedTags(_ context: EditContext) -> [String] {
        EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings).tags().inherited
    }

    static let tagLine = "^\\*+ (?:.*[ \\t])?(:([[:alnum:]_@#%:]+):)[ \\t]*$"

    public func run(in context: EditContext) -> CommandStep {
        guard let heading = entryHeading(at: context.caret, in: context.tree) else {
            return .failed("Setting file tags is not supported yet")
        }
        let currentText = HeadingLine(heading).tags.map { (context.text as NSString).substring(with: NSRange($0.range)) } ?? ""
        let current = currentText.split(separator: ":").map(String.init)
        let table = FastSelection.tagTable(context.text) ?? Self.bufferTags(context).map { .option(key: "\0", name: $0) }
        let tags: [String]
        if let fast = FastSelection.tags(table: table, current: current, inherited: inheritedTags(context)) {
            guard let answer = context.answers["tags"] else {
                return .prompt(Prompt(key: "tags", message: "Tags: [a-z..]:toggle [SPC]:clear [RET]:accept [TAB]:edit [!] groups", fast: fast))
            }
            guard let selected = fast.tags(after: FastSelection.decode(answer)) else { return .failed("Quit") }
            tags = Self.tags(from: selected.joined(separator: ":"))
        } else {
            guard let answer = context.answers["tags"] else {
                var names: [String] = []
                for case .option(_, let name) in table where !names.contains(name) { names.append(name) }
                for name in context.knownTags() where !names.contains(name) { names.append(name) }
                return .prompt(Prompt(key: "tags", message: "Tags:", initial: currentText, choices: names, requireMatch: false, completionSeparator: ":"))
            }
            tags = Self.tags(from: answer)
        }
        return commitBuffer(context) { buffer in
            try buffer.saveExcursion {
                try buffer.backToHeading()
                try buffer.saveExcursion {
                    let line = buffer.saveExcursion { buffer.lookingAt(Self.tagLine) }
                    let old = line.flatMap { $0[2] }.map { buffer.substring($0.lowerBound, $0.upperBound).split(separator: ":").map(String.init) } ?? []
                    if tags != old {
                        buffer.point = line?[1]?.lowerBound ?? buffer.lineEnd(buffer.point)
                        buffer.skipBackward(EmacsBuffer.blanks)
                        buffer.deleteRegion(buffer.point, buffer.lineEnd(buffer.point))
                        if !buffer.atHeading { buffer.insert(" ") }
                        if !tags.isEmpty { buffer.saveExcursion { buffer.insert(" :" + tags.joined(separator: ":") + ":") } }
                    }
                    // Org realigns whenever there are tags, changed or not.
                    if !tags.isEmpty { buffer.alignTags(onLineAt: buffer.point) }
                }
            }
            let afterStars = buffer.saveExcursion { () -> Bool in
                buffer.skipBackward([42])
                return buffer.bolp
            }
            if afterStars, buffer.character(at: buffer.point) == 32 { buffer.point += 1 }
        }
    }
}
