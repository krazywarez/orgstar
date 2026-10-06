import Foundation

/// Markdown export, GitHub-flavored: ATX headings, fenced code, pipe tables, task lists and
/// `[^n]` footnotes. The title, when there is one, becomes the top heading.
public enum MarkdownExport {
    public static func document(_ text: String, settings: OrgSettings = .default) -> String {
        let renderer = MarkdownRenderer(settings: settings)
        var out = ""
        if let title = HTMLExport.metadata(text, settings: settings).title { out = "# " + renderer.inlineString(title) + "\n\n" }
        out += renderer.document(text)
        return out.trimmingCharacters(in: .newlines) + "\n"
    }
}

final class MarkdownRenderer {
    let settings: OrgSettings
    private var definitions: [String: String] = [:]
    private var numbers: [String: Int] = [:]
    private var notes: [(Int, String)] = []
    private var anonymous = 0

    init(settings: OrgSettings) {
        self.settings = settings
    }

    func document(_ text: String) -> String {
        let tree = OrgParser.parse(text, defaults: settings)
        for node in tree.root.descendants() where node.kind == .footnoteDefinition {
            if let m = node.text.firstMatch(of: /^\[fn:([^\]]+)\][ \t]*/) {
                definitions[String(m.1)] = String(node.text[m.range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        var out = blocks(tree.root)
        if !notes.isEmpty {
            out += notes.map { "[^\($0.0)]: " + $0.1 }.joined(separator: "\n") + "\n"
        }
        return out
    }

    func inlineString(_ text: String) -> String {
        let tree = OrgParser.parse(text, defaults: settings)
        guard let paragraph = tree.root.descendants().first(where: { $0.kind == .paragraph }) else { return text }
        return inline(paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var lastExports = "code"
    private var results = false

    private func blocks(_ node: SyntaxNode, indent: String = "") -> String {
        let parts = node.children.map { child -> String in
            // Results show for `:exports results` and `both`, as in the HTML export.
            if child.kind == .affiliatedKeyword {
                if child.text.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("#+RESULTS") { results = true }
                return ""
            }
            defer { results = false }
            if results {
                defer { lastExports = "code" }
                if lastExports != "results", lastExports != "both" { return "" }
            }
            if child.kind == .block, let exports = HTMLRenderer.srcExports(child) {
                lastExports = exports
                if exports == "results" || exports == "none" { return "" }
            }
            return element(child, indent: indent)
        }.filter { !$0.isEmpty }
        return parts.isEmpty ? "" : parts.joined(separator: "\n\n") + "\n\n"
    }

    private func blocks(text: String) -> String {
        blocks(OrgParser.parse(text, defaults: settings).root)
    }

    private func element(_ node: SyntaxNode, indent: String) -> String {
        switch node.kind {
        case .zerothSection, .section:
            return blocks(node, indent: indent).trimmingCharacters(in: .newlines)
        case .heading:
            let level = node.tokens.first { $0.kind == .stars }?.text.count ?? 1
            var parts: [String] = []
            if let todo = node.tokens.first(where: { $0.kind == .todoKeyword })?.text { parts.append(todo) }
            if let priority = node.tokens.first(where: { $0.kind == .priority })?.text { parts.append(priority) }
            if let title = node.firstChild(.title) { parts.append(inline(title).trimmingCharacters(in: .whitespaces)) }
            if let tags = node.tokens.first(where: { $0.kind == .tags })?.text {
                parts.append(tags.split(separator: ":").map { "`\($0)`" }.joined(separator: " "))
            }
            return String(repeating: "#", count: min(level + 1, 6)) + " " + parts.filter { !$0.isEmpty }.joined(separator: " ")
        case .paragraph:
            return indent + inline(node).trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n" + indent)
        case .plainList:
            return list(node, indent: indent)
        case .table:
            return table(node, indent: indent)
        case .block:
            return block(node, indent: indent)
        case .horizontalRule:
            return indent + "---"
        case .fixedWidth:
            let lines = node.text.split(separator: "\n").map { line -> String in
                let trimmed = line.drop { $0 == " " || $0 == "\t" }
                return trimmed.hasPrefix(": ") ? String(trimmed.dropFirst(2)) : String(trimmed.dropFirst(trimmed.hasPrefix(":") ? 1 : 0))
            }
            return fence(lines, language: "", indent: indent)
        default:
            return ""
        }
    }

    private func fence(_ lines: [String], language: String, indent: String) -> String {
        let longest = lines.map { $0.prefix { $0 == "`" }.count }.max() ?? 0
        let ticks = String(repeating: "`", count: max(3, longest + 1))
        return ([indent + ticks + language] + lines.map { indent + $0 } + [indent + ticks]).joined(separator: "\n")
    }

    private func list(_ node: SyntaxNode, indent: String) -> String {
        var out: [String] = []
        var number = 0
        for item in node.children where item.kind == .item {
            let bullet = item.tokens.first { $0.kind == .bullet }?.text ?? "-"
            let ordered = bullet.first.map { $0.isNumber || $0.isLetter } ?? false
            number += 1
            var marker = ordered ? "\(number)." : "-"
            if let box = item.tokens.first(where: { $0.kind == .checkbox })?.text {
                marker += box == "[X]" || box == "[x]" ? " [x]" : " [ ]"
            }
            let childIndent = indent + String(repeating: " ", count: (ordered ? "\(number). " : "- ").count)
            var parts: [String] = []
            for (index, child) in item.children.enumerated() {
                if index == 0, child.kind == .paragraph {
                    var text = inline(child).trimmingCharacters(in: .whitespacesAndNewlines)
                        .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n" + childIndent)
                    if let separator = text.range(of: " :: ") {
                        text = "**" + text[..<separator.lowerBound] + "**: " + text[separator.upperBound...]
                    }
                    parts.append(text)
                } else {
                    parts.append(element(child, indent: childIndent))
                }
            }
            let body = parts.isEmpty ? "" : parts[0].trimmingCharacters(in: .whitespaces) + parts.dropFirst().map { "\n" + $0 }.joined()
            out.append(indent + marker + " " + body)
        }
        return out.joined(separator: "\n")
    }

    private func table(_ node: SyntaxNode, indent: String) -> String {
        var rows: [[String]] = []
        var ruleAfter: Int?
        for row in node.children where row.kind == .tableRow {
            let cells = row.children.filter { $0.kind == .tableCell }
            if cells.isEmpty {
                if ruleAfter == nil, !rows.isEmpty { ruleAfter = rows.count }
                continue
            }
            rows.append(cells.map { inline($0).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "|", with: "\\|") })
        }
        guard !rows.isEmpty else { return "" }
        let columns = rows.map(\.count).max() ?? 0
        rows = rows.map { $0 + Array(repeating: "", count: columns - $0.count) }
        var header: [String]
        var body: [[String]]
        if ruleAfter == 1 {
            header = rows[0]
            body = Array(rows.dropFirst())
        } else {
            header = Array(repeating: "", count: columns)
            body = rows
        }
        func line(_ cells: [String]) -> String { indent + "| " + cells.joined(separator: " | ") + " |" }
        return ([line(header), indent + "|" + Array(repeating: "---", count: columns).joined(separator: "|") + "|"] + body.map(line)).joined(separator: "\n")
    }

    private func block(_ node: SyntaxNode, indent: String) -> String {
        var lines = node.text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard let first = lines.first, let m = first.firstMatch(of: /^[ \t]*#\+(?i:begin)_(\S+)[ \t]*(.*)$/) else { return "" }
        let type = m.1.lowercased()
        let parameters = String(m.2)
        var body = Array(lines.dropFirst().dropLast()).map {
            $0.replacingOccurrences(of: "^([ \\t]*),([,*]|#\\+)", with: "$1$2", options: .regularExpression)
        }
        let common = body.filter { $0.contains(where: { !$0.isWhitespace }) }.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        body = body.map { String($0.dropFirst(min(common, $0.prefix { $0 == " " }.count))) }
        switch type {
        case "src":
            return fence(body, language: parameters.split(separator: " ").first.map(String.init) ?? "", indent: indent)
        case "example":
            return fence(body, language: "", indent: indent)
        case "quote":
            return blocks(text: body.joined(separator: "\n")).trimmingCharacters(in: .newlines)
                .components(separatedBy: "\n").map { indent + ($0.isEmpty ? ">" : "> " + $0) }.joined(separator: "\n")
        case "verse":
            return body.map { indent + inlineString($0) + "  " }.joined(separator: "\n")
        case "export":
            let backend = parameters.lowercased()
            return backend.hasPrefix("markdown") || backend.hasPrefix("md") || backend.hasPrefix("html") ? body.joined(separator: "\n") : ""
        case "comment":
            return ""
        default:
            return blocks(text: body.joined(separator: "\n")).trimmingCharacters(in: .newlines)
        }
    }

    func inline(_ node: SyntaxNode) -> String {
        var out = ""
        for element in node.elements {
            switch element {
            case .token(let token):
                switch token.kind {
                case .marker, .stars, .bullet, .checkbox, .tags, .todoKeyword, .priority: continue
                default: out += token.text
                }
            case .node(let child):
                out += object(child)
            }
        }
        return out
    }

    private func code(_ text: String) -> String {
        let ticks = text.contains("`") ? "``" : "`"
        return ticks + (ticks == "``" ? " " + text + " " : text) + ticks
    }

    private func object(_ node: SyntaxNode) -> String {
        switch node.kind {
        case .bold: return "**\(inline(node))**"
        case .italic: return "*\(inline(node))*"
        case .underline: return "<u>\(inline(node))</u>"
        case .strikeThrough: return "~~\(inline(node))~~"
        case .verbatim, .code: return code(inline(node))
        case .link: return link(node)
        case .linkDescription: return inline(node)
        case .timestamp:
            guard let stamp = Timestamp.parse(node.text) else { return node.text }
            func show(_ p: Timestamp.Point) -> String {
                String(format: "%04d-%02d-%02d", p.year, p.month, p.day) + (p.hour.map { String(format: " %02d:%02d", $0, p.minute ?? 0) } ?? "")
            }
            return show(stamp.start) + (stamp.end.map { "–" + show($0) } ?? "")
        case .footnoteReference: return footnote(node.text)
        case .entity:
            let name = node.text.dropFirst().replacingOccurrences(of: "{}", with: "")
            return OrgEntities.display[name] ?? node.text
        case .radioTarget:
            return String(node.text.dropFirst(3).dropLast(3))
        case .superscript, .subscript:
            let body = node.text.dropFirst()
            let inner = body.hasPrefix("{") && body.hasSuffix("}") ? String(body.dropFirst().dropLast()) : String(body)
            return node.text.hasPrefix("_") ? "<sub>\(inner)</sub>" : "<sup>\(inner)</sup>"
        case .lineBreak: return "  \n"
        case .target, .macro: return ""
        default: return inline(node)
        }
    }

    private func link(_ node: SyntaxNode) -> String {
        guard let path = node.tokens.first(where: { $0.kind == .linkPath })?.text else {
            // A radio link is its text.
            if !node.text.hasPrefix("<"), !node.text.contains(":") { return node.text }
            var target = node.text
            if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
            return "<\(target)>"
        }
        var href = path
        if path.hasPrefix("file:") { href = String(path.dropFirst(5)) }
        if path.hasPrefix("id:") { href = "#" + path.dropFirst(3) }
        if !path.contains(":"), href.lowercased().hasSuffix(".org") { href = String(href.dropLast(4)) + ".md" }
        if let description = node.firstChild(.linkDescription) { return "[\(inline(description))](\(href))" }
        let ext = href.split(separator: ".").last.map { $0.lowercased() } ?? ""
        if HTMLRenderer.imageExtensions.contains(ext) { return "![](\(href))" }
        return path.contains("://") ? "<\(href)>" : "[\(href)](\(href))"
    }

    private func footnote(_ text: String) -> String {
        guard let m = text.firstMatch(of: /^\[fn:([^:\]]*)(?::(.*))?\]$/) else { return text }
        var label = String(m.1)
        if label.isEmpty {
            anonymous += 1
            label = "anonymous-\(anonymous)"
        }
        if let n = numbers[label] { return "[^\(n)]" }
        guard let content = m.2.map(String.init) ?? definitions[label] else { return text }
        let n = notes.count + 1
        numbers[label] = n
        notes.append((n, inlineString(content.replacingOccurrences(of: "\n", with: " "))))
        return "[^\(n)]"
    }
}
