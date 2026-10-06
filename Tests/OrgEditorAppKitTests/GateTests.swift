import AppKit
import Foundation
import OrgDocument
import Testing
@testable import OrgEditorAppKit

/// The phase 1 performance gates (design, "Phases"). Skipped unless `ORGSTAR_GATES` is set;
/// run in a release build on the reference machine:
///
///     ORGSTAR_GATES=1 swift test -c release --filter GateTests
///
/// `ORGSTAR_GATE_FILE` adds a real file to the synthetic ones. Memory limits follow the design:
/// 10x the file size for typical documents, 45x for the synthetic worst cases.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_GATES"] != nil))
struct GateTests {
    /// About 1 MB of body text under a single top-level heading.
    /// Entries with property and LOGBOOK drawers, all folded when the file opens.
    static let drawers: String = {
        var text = ""
        for n in 0..<3_000 {
            text += "* TODO Entry \(n) :tag:\n:PROPERTIES:\n:ID:       \(n)-uuid\n:CREATED:  [2026-10-04 Sun]\n:END:\n"
            text += ":LOGBOOK:\n- State \"DONE\"       from \"TODO\"       [2026-10-04 Sun 10:00]\nCLOCK: [2026-10-04 Sun 09:00]--[2026-10-04 Sun 10:00] =>  1:00\n:END:\n"
            text += "Body of entry \(n), a paragraph of text.\n\n"
        }
        return text
    }()

    static let singleSection: String = {
        var text = "* One big section\n"
        var n = 0
        while text.utf8.count < 1_000_000 {
            text += "Paragraph \(n) with *bold*, /italic/, a [[https://example.com/\(n)][link]] and <2026-10-04 Sun>.\n"
            text += "It continues on a second line with =code= and ~more~.\n\n"
            text += "- item \(n)\n  - nested [ ] task\n\n"
            n += 1
        }
        return text
    }()

    /// A 5,000-row table.
    static let bigTable: String = {
        var text = "* Table\n| id | name | note |\n|----+------+------|\n"
        for n in 0..<5_000 { text += "| \(n) | row \(n) | *bold* and [[https://example.com][link]] |\n" }
        return text
    }()

    struct Result: CustomStringConvertible {
        var name: String
        var bytes: Int
        var open: Duration
        var typingP95: Duration
        var newlineP95: Duration
        var memoryRatio: Double

        var description: String {
            "\(name) (\(bytes / 1000) kB): open \(open), typing p95 \(typingP95), blank line p95 \(newlineP95), memory \(String(format: "%.1f", memoryRatio))x"
        }
    }

    /// Heap bytes in use, which unlike resident size isn't hidden by memory freed earlier.
    static func heapBytes() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    func measure(_ name: String, _ text: String) -> Result {
        let clock = ContinuousClock()
        let bytes = Array(text.utf8)
        let before = Self.heapBytes()
        var harness: Harness!
        let open = clock.measure {
            harness = Harness(DocumentState(bytes: bytes), layout: false)
        }
        harness.drainStyling()
        let memoryRatio = Double(Self.heapBytes() - before) / Double(bytes.count)

        var timings: [Duration] = []
        harness.editor.onEditTiming = { timings.append($0) }
        let paragraphs = harness.editor.document.tree.root.descendants().filter { $0.kind == .paragraph || $0.kind == .tableCell }
        harness.caret(at: paragraphs[paragraphs.count / 2].range.lowerBound + 1)
        for _ in 0..<100 { harness.textView.insertText("x", replacementRange: harness.textView.selectedRange()) }
        let typing = timings.sorted()[95]

        timings = []
        for _ in 0..<20 {
            harness.textView.insertNewline(nil)
            harness.textView.insertNewline(nil)
            harness.textView.deleteBackward(nil)
            harness.textView.deleteBackward(nil)
        }
        let sorted = timings.sorted()
        return Result(name: name, bytes: bytes.count, open: open, typingP95: typing, newlineP95: sorted[sorted.count * 95 / 100], memoryRatio: memoryRatio)
    }

    @Test func gates() throws {
        // The first text view, and the first text loaded into one, set up the text system once
        // per process; an app pays that at launch, not per file.
        NSTextView(usingTextLayoutManager: true).textStorage?.setAttributedString(NSAttributedString(string: "warm up"))
        // Memory limits: worst-case dense markup for the synthetic files, typical for real ones.
        var inputs = [("single 1 MB section", Self.singleSection, 45.0), ("5,000-row table", Self.bigTable, 45.0), ("3,000 entries with drawers", Self.drawers, 45.0)]
        if let path = ProcessInfo.processInfo.environment["ORGSTAR_GATE_FILE"] {
            inputs.append((URL(fileURLWithPath: path).lastPathComponent, try String(contentsOfFile: path, encoding: .utf8), 10.0))
        }
        for (name, text, memoryLimit) in inputs {
            let result = measure(name, text)
            print("GATE \(result)")
            let perMegabyte = Double(result.bytes) / 1_000_000
            #expect(result.open < .milliseconds(100) * max(1, perMegabyte), "\(name): open")
            #expect(result.typingP95 < .milliseconds(16), "\(name): typing")
            #expect(result.newlineP95 < .milliseconds(16), "\(name): blank line")
            #expect(result.memoryRatio < memoryLimit, "\(name): memory")
        }
    }
}
