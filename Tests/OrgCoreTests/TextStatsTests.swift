import Foundation
import Testing
@testable import OrgCore

struct TextStatsTests {
    static let samples = [
        "don't stop", "foo_bar baz", "x-y", "café au lait", "日本語 text", "*bold* /it/ =code=", "2026-10-05 Mon",
        "https://example.com/a-b?c=1", "[[file:x.org][Desc here]]", "* TODO Heading :tag:work:", "a.b,c;d",
        "it's 3.14 or 1e5", "naïve—dash", "emoji 😀 ok", "über_cool", "«quoted» “smart” ‘single’", "a\u{00A0}b",
        "\tindented\ttext", "- [X] item\n  - sub 2\n", "x × y ÷ z → w", "€5 £3 ©2026 °C ™ ¶ § •", "✓ done ★ star", "¶ § · µ ¬ ¨ ■ ♥ ⌘ ✂ ➜ 🎉", "line one\r\nline two\r\n", "Sony α7 III", "漢字かなカナ ひらがなカタカナ", "e\u{0301}te résumé", "Привет мир", "a\u{0080}\u{0098}b", "",
    ]

    /// `count-words`, `count-lines` and `current-column` at the end of each sample in an org buffer.
    static func emacs(_ samples: [String]) throws -> [String] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-stats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("in.json")
        let output = folder.appendingPathComponent("out.json")
        let script = folder.appendingPathComponent("stats.el")
        try JSONEncoder().encode(samples).write(to: input)
        try """
        ;;; -*- lexical-binding: t -*-
        (require 'org)
        (require 'json)
        (let ((samples (append (json-read-file (getenv "ORACLE_INPUT")) nil)) result)
          (dolist (s samples)
            (with-temp-buffer
              (org-mode)
              (insert s)
              (push (format "%d words %d lines %d chars, %d:%d"
                            (count-words (point-min) (point-max))
                            (count-lines (point-min) (point-max))
                            (- (point-max) (point-min))
                            (line-number-at-pos) (current-column))
                    result)))
          (let ((coding-system-for-write 'utf-8-unix))
            (with-temp-file (getenv "ORACLE_OUTPUT")
              (insert (json-encode (vconcat (nreverse result)))))))
        """.write(to: script, atomically: true, encoding: .utf8)
        let log = try EmacsOracle.run(["-Q", "--batch", "-l", script.path], environment: ["ORACLE_INPUT": input.path, "ORACLE_OUTPUT": output.path])
        guard let data = try? Data(contentsOf: output) else { throw AgendaOracle.OracleError(log: log) }
        return try JSONDecoder().decode([String].self, from: data)
    }

    static func ours(_ s: String) -> String {
        let region = TextStats.region(s)
        let position = TextStats.position(in: s, at: s.utf16.count)
        return "\(region.words) words \(region.lines) lines \(region.characters) chars, \(position.line):\(position.column)"
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func matchesEmacs() throws {
        let emacs = try Self.emacs(Self.samples)
        for (sample, expected) in zip(Self.samples, emacs) {
            #expect(Self.ours(sample) == expected, "\(sample)")
        }
    }

    /// `ORGSTAR_ORACLE_CORPUS=<folder>`: every org file under the folder.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_ORACLE_CORPUS"] != nil))
    func corpusMatchesEmacs() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORGSTAR_ORACLE_CORPUS"]!)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "org" }
        let texts = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        let emacs = try Self.emacs(texts)
        for (text, expected) in zip(texts, emacs) {
            #expect(Self.ours(text) == expected, "\(text.prefix(60))")
        }
    }

    @Test func positionMidLine() {
        let text = "* Heading\n\tab日本\n"
        let offset = (text as NSString).range(of: "本").location
        #expect(TextStats.position(in: text, at: offset) == (2, 12))
        #expect(TextStats.position(in: text, at: 0) == (1, 0))
    }
}
