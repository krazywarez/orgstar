import Foundation
import AppKit
import ImageIO
import Testing
@testable import OrgCore

/// `content.xml` reduced to what ox-odt and the native export must agree on: headings with
/// their outline level, paragraphs, lists, sections, tables and their rows and cells, links
/// and images with their targets, notes and frames, and the text runs. Spaces written as
/// elements count as spaces; references are numbered in order of appearance, since ox-odt's
/// are random.
enum ODTSkeleton {
    static let kept: Set<String> = [
        "text:h", "text:p", "text:list", "text:list-item", "text:list-header", "text:section", "text:note",
        "table:table", "table:table-header-rows", "table:table-rows", "table:table-row", "table:table-cell", "table:covered-table-cell",
        "text:a", "draw:a", "draw:frame", "draw:image", "draw:text-box", "text:table-of-content", "text:index-body",
    ]

    static func reduce(_ xml: String) -> String {
        guard let start = xml.range(of: "<office:text>"), let end = xml.range(of: "</office:text>") else { return xml }
        let body = xml[start.upperBound..<end.lowerBound]
        var lines: [String] = []
        var text = ""
        var references: [String: Int] = [:]
        func flush() {
            let collapsed = Skeleton.decode(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !collapsed.isEmpty { lines.append("\"" + collapsed + "\"") }
            text = ""
        }
        var i = body.startIndex
        while i < body.endIndex {
            guard body[i] == "<", let close = body[i...].firstIndex(of: ">") else {
                text.append(body[i])
                i = body.index(after: i)
                continue
            }
            let tag = String(body[body.index(after: i)..<close])
            i = body.index(after: close)
            if tag.hasPrefix("!") || tag.hasPrefix("?") { continue }
            let closing = tag.hasPrefix("/")
            let name = String(tag.dropFirst(closing ? 1 : 0).prefix { !$0.isWhitespace && $0 != "/" })
            switch name {
            case "text:s":
                let count = tag.firstMatch(of: /text:c="([0-9]+)"/).flatMap { Int($0.1) } ?? 1
                text += String(repeating: " ", count: count)
                continue
            case "text:tab", "text:line-break":
                text += " "
                continue
            default:
                break
            }
            guard kept.contains(name) else { continue }
            flush()
            if closing {
                lines.append("</\(name)>")
                continue
            }
            var attributes = ""
            if let level = tag.firstMatch(of: /text:outline-level="([0-9]+)"/) { attributes += " level=\(level.1)" }
            if let href = tag.firstMatch(of: /xlink:href="([^"]*)"/) {
                var value = String(href.1)
                if value.hasPrefix("#") {
                    let n = references[value] ?? references.count + 1
                    references[value] = n
                    value = "#ref\(n)"
                }
                attributes += " href=\"\(value)\""
            }
            if let span = tag.firstMatch(of: /table:number-columns-spanned="([0-9]+)"/) { attributes += " span=\(span.1)" }
            lines.append("<\(name)\(attributes)>")
            if tag.hasSuffix("/") { lines.append("</\(name)>") }
        }
        flush()
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Reads a zip's entries, stored or deflated, through `unzip` for the latter.
enum ZipReader {
    struct Entry {
        var name: String
        var method: UInt16
        var extraLength: UInt16
        var data: Data
    }

    /// The local entries in order.
    static func entries(_ data: Data) -> [Entry] {
        var out: [Entry] = []
        var at = 0
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> UInt16 { UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
        while at + 30 <= bytes.count, u32(at) == 0x04034b50 {
            let method = u16(at + 8)
            let size = Int(u32(at + 18))
            let nameLength = Int(u16(at + 26))
            let extra = u16(at + 28)
            let name = String(decoding: bytes[(at + 30)..<(at + 30 + nameLength)], as: UTF8.self)
            let start = at + 30 + nameLength + Int(extra)
            out.append(Entry(name: name, method: method, extraLength: extra, data: Data(bytes[start..<(start + size)])))
            at = start + size
        }
        return out
    }

    /// The names the central directory lists.
    static func directory(_ data: Data) -> [String] {
        let bytes = [UInt8](data)
        var names: [String] = []
        var i = 0
        while i + 46 <= bytes.count {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x01, bytes[i + 3] == 0x02 {
                let length = Int(bytes[i + 28]) | Int(bytes[i + 29]) << 8
                names.append(String(decoding: bytes[(i + 46)..<(i + 46 + length)], as: UTF8.self))
                i += 46 + length
            } else {
                i += 1
            }
        }
        return names
    }
}

struct ODTExportTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil && EmacsOracle.isAvailable

    /// A PNG of `width` by `height` pixels.
    static func png(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static let corpus = ["minimal", "core", "headings", "listblocks", "lists", "table", "blocks", "timestamps", "footnote", "tblfm"]

    /// Documents for what the corpus doesn't cover. `PIC` is replaced by an image's path.
    static let snippets: [String: String] = [
        "images": """
            #+TITLE: Images

            [[file:PIC]]

            #+CAPTION: A captioned picture
            #+NAME: fig:one
            [[file:PIC]]

            Inline [[file:PIC]] in text and a [[file:PIC][described]] link.

            #+ATTR_ODT: :width 3
            [[file:PIC]]

            See [[fig:one]] and [[fig:one][the figure]].

            [[https://example.com][file:PIC]]
            """,
        "tables": """
            #+TITLE: Tables
            #+OPTIONS: toc:nil

            * One
            #+CAPTION: Scores
            #+NAME: tbl:scores
            | Name  | <r>   |
            | Name  | Score |
            |-------+-------|
            | alpha | 10    |
            |-------+-------|
            | beta  | x     |
            | gamma |       |

            Refer to [[tbl:scores]].

            | / | <> |   |
            | # | a  | b |
            | ! | x  | y |
            | # | 1  | 2 |

            | <5> | b |
            | 1   | 2 |

            #+ATTR_ODT: :rel-width 50
            | c | d |
            """,
        "list-tables": """
            #+OPTIONS: toc:nil

            1. first
               - nested
                 | a | b |
                 | 1 | 2 |
                 after the table
               - next nested
            2. second
               | x |
               | y |
               then text
               | z |

            - term :: definition
              | t |
            """,
        "footnotes": """
            #+OPTIONS: toc:nil

            One[fn:a][fn:b] and again[fn:a], anonymous[fn:: inline /note/].

            [fn:a] First note.

              With a second paragraph.
            [fn:b] Second note.
            """,
        "low-levels": """
            #+OPTIONS: H:2

            * Top
            ** Second
            *** Third
            Text under third.
            **** Fourth
            | cell |
            *** Third again
            * Other
            """,
        "links": """
            #+TITLE: Links

            * Alpha
            :PROPERTIES:
            :CUSTOM_ID: alpha-id
            :ID: 1234-abcd
            :END:
            Go to [[*Beta]], [[Beta][the beta]], [[#alpha-id][custom]], [[#alpha-id]], [[id:1234-abcd]] and <<here>>.
            * Beta
            A <<<radio word>>> and later the radio word again. [[here][back]].
            Mail [[mailto:a@b.c][me]], a file [[file:notes.txt]], ./rel.txt and [[./dir/x.org][rel]].
            #+begin_src emacs-lisp -n -r
            (setq x 1) (ref:one)
            (setq y 2)
            #+end_src
            Line [[(one)]] and [[(one)][line %s]].
            * Gamma :noexport:
            Excluded.
            * COMMENT Delta
            Commented.
            """,
        "inline": """
            #+TITLE: Inline /markup/
            #+SUBTITLE: The subtitle
            #+AUTHOR: Someone
            #+DATE: <2024-03-01 Fri>
            #+OPTIONS: num:nil pri:t

            * TODO [#B] Heading with =code= :tag:
            Text with *bold*, /italic/, _under_, +strike+, ~code   spaced~, =verb=.
            Math \\(a+b\\) and $x$ and \\alpha and H_2O and x^{2} and e^x.
            Dashes -- and --- and ... and a\\-b.
            Line one\\\\
            line two.
            @@odt:<text:span>raw</text:span>@@ and @@html:<b>no</b>@@ and [2/3] cookie.
            #+ODT: <text:p>raw paragraph</text:p>

            -----

            \\begin{equation}
            E = mc^2
            \\end{equation}

            :NOTES:
            Drawer contents.
            :END:

            #+begin_verse
              Indented first
            second   line
            #+end_verse

            #+begin_example -n
            one
            two
            #+end_example

            #+CAPTION: A listing
            #+begin_src python
            print("x")
            #+end_src

            : fixed width
            : lines

            #+begin_center
            Centered *text*.
            #+end_center

            #+TOC: headlines 1
            """,
        "more": """
            #+OPTIONS: toc:nil

            * Heading
            #+begin_src python

            x = 1

            y = 2

            #+end_src

            #+begin_example
            ex


            #+end_example

            3. [@3] third
            4. fourth
               - [X] term :: def
               - [ ] other :: more

            #+begin_quote
            - a quoted item
            #+end_quote

            [2024-01-01 Mon]--[2024-01-02 Tue] and <2024-01-01 Mon 10:00>

            #+TOC: headlines local

            ** Sub
            Text \\alpha{} \\beta and \\nbsp{}.

            #+begin_textbox
            Boxed.
            #+end_textbox

            #+begin_annotation
            Noted.
            #+end_annotation
            """,
        "options": """
            #+OPTIONS: toc:1 num:1 todo:nil tags:nil author:nil date:nil title:nil -:nil ^:{} tex:nil

            * DONE First :x:
            ** Sub
            Text -- here a_b and a_{b} and \\(x\\).
            * Second
            """,
    ]

    /// Exports each document with ox-odt in one Emacs: its `content.xml`, or `ERROR: ` and the
    /// message.
    static func emacs(_ files: [URL]) throws -> [String] {
        let folder = files[0].deletingLastPathComponent()
        let output = folder.appendingPathComponent("out.json")
        let script = folder.appendingPathComponent("odt.el")
        try """
            ;;; -*- lexical-binding: t -*-
            (require 'ox-odt)
            (require 'json)
            (setq user-full-name "Tester")
            (let (results)
              (dolist (file (split-string (getenv "ODT_FILES") "\\n" t))
                (push (condition-case err
                          (with-current-buffer (find-file-noselect file)
                            (let ((odt (org-odt-export-to-odt)))
                              (with-temp-buffer
                                (let ((coding-system-for-read 'utf-8))
                                  (call-process "unzip" nil t nil "-p" odt "content.xml"))
                                (buffer-string))))
                        (error (concat "ERROR: " (error-message-string err))))
                      results))
              (let ((coding-system-for-write 'utf-8))
                (with-temp-file (getenv "ODT_OUTPUT")
                  (insert (json-encode (vconcat (nreverse results)))))))
            """.write(to: script, atomically: true, encoding: .utf8)
        try EmacsOracle.run(["-Q", "--batch", "-l", script.path], environment: [
            "ODT_FILES": files.map(\.path).joined(separator: "\n"), "ODT_OUTPUT": output.path, "TZ": "UTC",
        ])
        return try JSONDecoder().decode([String].self, from: Data(contentsOf: output))
    }

    static func content(_ text: String, path: String) throws -> String {
        let parts = try ODTExport.parts(text, path: path, author: "Tester")
        return String(decoding: parts.first { $0.name == "content.xml" }!.data, as: UTF8.self)
    }

    @Test(.enabled(if: oracle))
    func matchesOxODT() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-odt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let picture = folder.appendingPathComponent("pic.png")
        try Self.png(width: 64, height: 48).write(to: picture)
        var documents: [(name: String, text: String)] = []
        for name in Self.corpus {
            documents.append((name, try String(contentsOf: ExportTests.folder.appendingPathComponent("\(name).org"), encoding: .utf8)))
        }
        for (name, text) in Self.snippets.sorted(by: { $0.key < $1.key }) {
            documents.append((name, text.replacingOccurrences(of: "PIC", with: picture.path) + "\n"))
        }
        let files = documents.map { folder.appendingPathComponent($0.name + ".org") }
        for (document, file) in zip(documents, files) { try document.text.write(to: file, atomically: true, encoding: .utf8) }
        let expected = try Self.emacs(files)
        for (index, document) in documents.enumerated() {
            let theirs = ODTSkeleton.reduce(expected[index])
            let ours = ODTSkeleton.reduce(try Self.content(document.text, path: files[index].path))
            #expect(ours == theirs, "\(document.name)\n--- ours\n\(ours)\n--- ox-odt\n\(theirs)")
        }
    }

    /// Where ox-odt stops, the export stops with its message.
    @Test(.enabled(if: oracle))
    func failsLikeOxODT() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-odt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let documents = [
            "broken": "See [[nowhere]].\n",
            "missing": "[[file:missing.png]]\n",
            "elements": try String(contentsOf: ExportTests.folder.appendingPathComponent("elements.org"), encoding: .utf8),
        ].sorted { $0.key < $1.key }
        let files = documents.map { folder.appendingPathComponent($0.key + ".org") }
        for (document, file) in zip(documents, files) { try document.value.write(to: file, atomically: true, encoding: .utf8) }
        let expected = try Self.emacs(files)
        for (index, document) in documents.enumerated() {
            #expect(expected[index].hasPrefix("ERROR: "), "\(document.key)")
            #expect(throws: ODTExport.Failure.self) { try Self.content(document.value, path: files[index].path) }
            do {
                _ = try Self.content(document.value, path: files[index].path)
            } catch let failure as ODTExport.Failure {
                #expect(expected[index].contains(failure.message), "\(document.key): \(failure.message) / \(expected[index])")
            }
        }
    }

    /// `mimetype` first and stored, with no extra field; the manifest lists every part; each
    /// XML part parses.
    @Test func package() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-odt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.png(width: 10, height: 10).write(to: folder.appendingPathComponent("a.png"))
        let path = folder.appendingPathComponent("doc.org").path
        let data = try ODTExport.document("#+TITLE: T & U\n\n* Heading\n[[./a.png]]\n\n| x | y |\n", path: path)
        let entries = ZipReader.entries(data)
        #expect(entries.first?.name == "mimetype")
        #expect(entries.first?.method == 0)
        #expect(entries.first?.extraLength == 0)
        #expect(entries.first.map { String(decoding: $0.data, as: UTF8.self) } == "application/vnd.oasis.opendocument.text")
        #expect(ZipReader.directory(data) == entries.map(\.name))
        #expect(entries.map(\.name) == ["mimetype", "content.xml", "styles.xml", "meta.xml", "Images/0001.png", "META-INF/manifest.xml"])
        let manifest = try XMLDocument(data: entries.last!.data)
        let listed = try manifest.nodes(forXPath: "//*[local-name()='file-entry']/@*[local-name()='full-path']").compactMap(\.stringValue)
        for entry in entries where !["mimetype", "META-INF/manifest.xml"].contains(entry.name) {
            #expect(listed.contains(entry.name), "\(entry.name)")
        }
        #expect(listed.contains("/"))
        for entry in entries where entry.name.hasSuffix(".xml") {
            #expect(throws: Never.self) { try XMLDocument(data: entry.data) }
        }
        let content = try XMLDocument(data: entries[1].data)
        #expect(try content.nodes(forXPath: "//*[local-name()='h']").count == 1)
        #expect(try content.nodes(forXPath: "//*[local-name()='image']/@*[local-name()='href']").compactMap(\.stringValue) == ["Images/0001.png"])
        #expect(try content.nodes(forXPath: "//*[local-name()='table-cell']").count == 2)
        let meta = try XMLDocument(data: entries[3].data)
        #expect(try meta.nodes(forXPath: "//*[local-name()='title']").first?.stringValue == "T & U")
    }

    /// The text system reads the file: headings, list items, table cells and notes.
    @Test func opensInTextKit() throws {
        let text = "#+TITLE: Opened\n\n* Heading\n- item one\n- item two\n\n| a | b |\n|---+---|\n| 1 | 2 |\n\nA note.[fn:1]\n\n[fn:1] Noted.\n"
        let data = try ODTExport.document(text, path: "/tmp/doc.org")
        let string = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.openDocument], documentAttributes: nil).string
        for word in ["Opened", "Heading", "item one", "item two", "a", "2", "A note."] {
            #expect(string.contains(word), "\(word) in \(string)")
        }
    }

    /// What the native export can't write the way ox-odt does stops the export instead.
    @Test(arguments: [
        "*************** Task\nBody.\n*************** END\n",
        "Here <<there>> and [[there]].\n",
        "#+begin_src emacs-lisp\n(x) (ref:a)\n#+end_src\n[[(a)]]\n",
        "#+ATTR_ODT: :style TableWithHeaderRowAndColumn\n| a |\n",
        "Code src_python[:exports code]{1 + 1} here.\n",
        "#+DATE: 2024\n#+begin_annotation\nNote.\n#+end_annotation\n",
    ])
    func refuses(_ text: String) {
        #expect(throws: ODTExport.Failure.self) { try ODTExport.document(text, path: "/tmp/doc.org") }
    }

    @Test func imageFiles() {
        let files = ODTExport.imageFiles("[[file:a.png]] [[./b.jpg][desc]] [[https://x/c.png]] [[/abs/d.svg]]\n", path: "/doc/notes.org")
        #expect(files == ["/doc/a.png", "/abs/d.svg"])
    }
}
