import Foundation

/// C-c C-q: `org-set-tags-command` without fast tag selection. Asks for the tags, then sets
/// them as `org-set-tags` does and realigns.
public struct SetTags: OrgCommand {
    public init() {}
    public var id: String { "org.tags.set" }
    public var title: String { "Set Tags" }
    public func applies(in context: EditContext) -> Bool { entryHeading(at: context.caret, in: context.tree) != nil }

    /// Characters that can't be in a tag separate tags, as org's `org-tag--invalid-char-re`.
    static func tags(from answer: String) -> [String] {
        answer.split { !($0.isLetter || $0.isNumber || "_@#%".contains($0)) }.map(String.init)
    }

    static let tagLine = "^\\*+ (?:.*[ \\t])?(:([[:alnum:]_@#%:]+):)[ \\t]*$"

    public func run(in context: EditContext) -> CommandStep {
        guard let heading = entryHeading(at: context.caret, in: context.tree) else {
            return .failed("Setting file tags is not supported yet")
        }
        guard let answer = context.answers["tags"] else {
            let current = HeadingLine(heading).tags.map { (context.text as NSString).substring(with: NSRange($0.range)) } ?? ""
            return .prompt(Prompt(key: "tags", message: "Tags:", initial: current))
        }
        let tags = Self.tags(from: answer)
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
