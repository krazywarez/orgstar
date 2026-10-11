import AppKit
import OrgCore
import OrgDocument
import OrgPresentation
import Testing
@testable import OrgEditorAppKit

/// A long file with lines of very different lengths, as real notes have: TextKit's height
/// estimates for text it hasn't laid out are far off for such a file, so laying the whole
/// document out again moves what the window shows.
@MainActor
struct ScrollStabilityTests {
    static func longDocument(headings: Int) -> String {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(truncatingIfNeeded: seed >> 33)
        }
        let words = ["meeting", "todo", "the", "a", "deadline", "note", "project", "review", "call", "later", "important", "x"]
        var text = "#+STARTUP: indent\n"
        for n in 0..<headings {
            text += "\(n % 3 == 0 ? "**" : "*") Heading \(n)\n"
            for _ in 0..<(1 + next() % 4) {
                let count: Int
                switch next() % 5 {
                case 0: count = 60 + next() % 120
                case 1: count = 1 + next() % 4
                default: count = 3 + next() % 12
                }
                text += (0..<count).map { _ in words[next() % words.count] }.joined(separator: " ") + "\n"
            }
        }
        return text
    }

    /// The window on screen, with layout left to the view, as a user's window is.
    static func shownHarness(_ text: String) -> Harness {
        NSApplication.shared.setActivationPolicy(.regular)
        let h = Harness(DocumentState(bytes: Array(text.utf8)), layout: false)
        h.window.makeKeyAndOrderFront(nil)
        pump(h)
        h.drainStyling()
        pump(h)
        return h
    }

    static func pump(_ h: Harness) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        h.window.displayIfNeeded()
    }

    /// The number of the line at the top of the window.
    static func topLine(_ h: Harness) -> Int {
        let layout = h.editor.textLayoutManager
        let content = layout.textContentManager!
        let y = h.textView.enclosingScrollView!.documentVisibleRect.minY - h.textView.textContainerOrigin.y
        guard let fragment = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, y))) else { return -1 }
        let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        return (h.string as NSString).substring(to: offset).filter { $0 == "\n" }.count
    }

    @Test func foldingNearTheEndKeepsTheWindowWhereItWas() {
        let h = Self.shownHarness(Self.longDocument(headings: 1500))
        let heading = h.offset(of: "* Heading 1480\n")
        h.editor.setCaret(heading)
        h.textView.scrollRangeToVisible(NSRange(location: heading, length: 0))
        Self.pump(h)
        let before = Self.topLine(h)
        #expect(before > 5000)

        var state = h.editor.foldState
        state.folds.insert(heading)
        h.editor.setFolds(state)
        Self.pump(h)
        let after = Self.topLine(h)
        #expect(abs(after - before) <= 2, "top line moved from \(before) to \(after)")
    }

    @Test func aThemeChangeNearTheEndKeepsTheWindowWhereItWas() {
        let h = Self.shownHarness(Self.longDocument(headings: 1500))
        let heading = h.offset(of: "* Heading 1480\n")
        h.editor.setCaret(heading)
        h.textView.scrollRangeToVisible(NSRange(location: heading, length: 0))
        Self.pump(h)
        let before = Self.topLine(h)
        #expect(before > 5000)

        var spec = ThemeSpec.default
        spec.light["heading-1"] = RGBA(hex: "#ff0000")
        h.editor.themeSpec = spec
        Self.pump(h)
        h.drainStyling()
        Self.pump(h)
        let after = Self.topLine(h)
        #expect(abs(after - before) <= 2, "top line moved from \(before) to \(after)")
    }
}
