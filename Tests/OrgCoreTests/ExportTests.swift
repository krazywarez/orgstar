import Foundation
import Testing
@testable import OrgCore

/// The org-conformance skeleton reduction (SKELETON.md): element opens and closes and text
/// runs, without `div`/`span` and attributes other than `href` and `src`.
enum Skeleton {
    static let ignored: Set<String> = ["div", "span"]
    static let void: Set<String> = ["br", "hr", "img", "input", "meta", "link", "col", "area", "base", "source", "wbr"]

    static func decode(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semicolon = s[i...].prefix(13).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semicolon])
                var replacement: String?
                switch name {
                case "amp": replacement = "&"
                case "lt": replacement = "<"
                case "gt": replacement = ">"
                case "quot": replacement = "\""
                case "apos": replacement = "'"
                case "nbsp": replacement = " "
                default:
                    if name.hasPrefix("#x") || name.hasPrefix("#X"), let v = UInt32(name.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) {
                        replacement = String(Character(u))
                    } else if name.hasPrefix("#"), let v = UInt32(name.dropFirst()), let u = Unicode.Scalar(v) {
                        replacement = String(Character(u))
                    }
                }
                if let replacement {
                    out += replacement == "\u{a0}" ? " " : replacement
                    i = s.index(after: semicolon)
                    continue
                }
            }
            out.append(s[i] == "\u{a0}" ? " " : s[i])
            i = s.index(after: i)
        }
        return out
    }

    static func reduce(_ html: String) -> String {
        var lines: [String] = []
        var text = ""
        func flush() {
            let collapsed = decode(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !collapsed.isEmpty {
                lines.append("\"" + collapsed.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"")
            }
            text = ""
        }
        var i = html.startIndex
        while i < html.endIndex {
            if html[i] == "<" {
                if html[i...].hasPrefix("<!--") {
                    let end = html[i...].range(of: "-->")?.upperBound ?? html.endIndex
                    i = end
                    continue
                }
                guard let close = html[i...].firstIndex(of: ">") else { text.append(html[i]); i = html.index(after: i); continue }
                let tag = String(html[html.index(after: i)..<close])
                i = html.index(after: close)
                if tag.hasPrefix("!") { continue }
                let closing = tag.hasPrefix("/")
                var body = closing ? String(tag.dropFirst()) : tag
                if body.hasSuffix("/") { body.removeLast() }
                let name = String(body.prefix { !$0.isWhitespace }).lowercased()
                if ignored.contains(name) { continue }
                if closing {
                    if void.contains(name) { continue }
                    flush()
                    lines.append("</\(name)>")
                    continue
                }
                flush()
                var attributes = ""
                for attribute in ["href", "src"] {
                    if let m = body.firstMatch(of: try! Regex("\\s\(attribute)=\"([^\"]*)\"")) {
                        attributes += " \(attribute)=\"\(decode(String(m.output[1].substring!)))\""
                    }
                }
                lines.append("<\(name)\(attributes)>")
            } else {
                text.append(html[i])
                i = html.index(after: i)
            }
        }
        flush()
        return lines.joined(separator: "\n") + "\n"
    }
}

struct ExportTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Conformance")

    @Test(arguments: ["minimal", "core", "elements", "headings", "listblocks", "lists", "table", "blocks", "timestamps", "footnote", "images", "tblfm"])
    func conformance(_ name: String) throws {
        let org = try String(contentsOf: Self.folder.appendingPathComponent("\(name).org"), encoding: .utf8)
        let expected = try String(contentsOf: Self.folder.appendingPathComponent("\(name).skeleton"), encoding: .utf8)
        let html = HTMLExport.body(org)
        let ours = Skeleton.reduce(html)
        #expect(ours == expected, "\(name)\n--- ours\n\(ours)\n--- html\n\(html)")
    }

    @Test func page() {
        let page = HTMLExport.page("#+TITLE: Notes & Things\n#+AUTHOR: Me\n\nHello.\n", fallbackTitle: "x")
        #expect(page.contains("<title>Notes &amp; Things</title>"))
        #expect(page.contains("<h1 class=\"title\">Notes &amp; Things</h1>"))
        #expect(page.contains("<p class=\"byline\">Me</p>"))
        #expect(page.contains("<p>Hello.</p>"))
    }
}

struct MarkdownExportTests {
    @Test func document() {
        let org = """
        #+TITLE: Notes

        Intro with *bold*, /italic/, =code=, a [[https://example.com][link]] and a note.[fn:1]

        * TODO Plans :work:
        - [ ] first
        - [X] second
          1. nested
        - term :: definition

        | a | b |
        |---+---|
        | 1 | 2 |

        #+begin_src swift
        let x = 1
        #+end_src

        #+begin_quote
        Quoted.
        #+end_quote

        [fn:1] The note.
        """
        let expected = """
        # Notes

        Intro with **bold**, *italic*, `code`, a [link](https://example.com) and a note.[^1]

        ## TODO Plans `work`

        - [ ] first
        - [x] second
          1. nested
        - **term**: definition

        | a | b |
        |---|---|
        | 1 | 2 |

        ```swift
        let x = 1
        ```

        > Quoted.

        [^1]: The note.

        """
        let ours = MarkdownExport.document(org)
        #expect(ours == expected)
    }
}

struct ExportCorpusTests {
    /// `ORGSTAR_ORACLE_CORPUS=<folder>`: every file exports to HTML and Markdown.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_ORACLE_CORPUS"] != nil))
    func exportsEveryFile() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORGSTAR_ORACLE_CORPUS"]!)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "org" }
        var slowest = (0.0, "")
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let start = Date()
            let html = HTMLExport.page(text, fallbackTitle: file.lastPathComponent)
            let markdown = MarkdownExport.document(text)
            let elapsed = Date().timeIntervalSince(start)
            if elapsed > slowest.0 { slowest = (elapsed, file.lastPathComponent) }
            #expect(html.contains("</html>") && !markdown.isEmpty, "\(file.path)")
        }
        print("exported \(files.count) files; slowest \(slowest.1) in \(String(format: "%.2f", slowest.0)) s")
    }
}

struct ExportResultsTests {
    @Test func resultsFollowExports() {
        let org = """
        #+begin_src sh
        echo a
        #+end_src

        #+RESULTS:
        : a

        #+begin_src sh :exports both
        echo b
        #+end_src

        #+RESULTS:
        : b

        #+begin_src sh :exports results
        echo c
        #+end_src

        #+RESULTS:
        : c
        """
        let html = HTMLExport.body(org)
        #expect(html.contains("echo a") && !html.contains(">a</pre>"))
        #expect(html.contains("echo b") && html.contains(">b</pre>"))
        #expect(!html.contains("echo c") && html.contains(">c</pre>"))
    }
}
