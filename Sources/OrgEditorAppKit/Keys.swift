#if os(macOS)
import AppKit
import OrgCore

/// Which Option keys act as Meta. The others type characters, as usual on a Mac.
public struct OptionAsMeta: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let left = OptionAsMeta(rawValue: 1)
    public static let right = OptionAsMeta(rawValue: 2)
}

/// A text view that offers key presses to the editor's keymap before the text system.
final class OrgTextView: NSTextView {
    /// Returns true when the key was handled.
    var keyHandler: ((NSEvent) -> Bool)?
    var onMouseDown: (() -> Void)?
    /// Each editor keeps its own undo history, not the window's.
    private let ownUndoManager = UndoManager()
    override var undoManager: UndoManager? { ownUndoManager }
    var lineNumberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    var lineNumberColor = NSColor.tertiaryLabelColor
    var currentLineNumberColor = NSColor.labelColor
    var showsLineNumbers = false {
        didSet { if showsLineNumbers != oldValue { updateGutter() } }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawLineNumbers(in: rect)
    }

    /// Redraws the line number margin, as when the caret changes line.
    func redrawLineNumbers() {
        guard showsLineNumbers else { return }
        setNeedsDisplay(NSRect(x: 0, y: visibleRect.minY, width: textContainerInset.width, height: visibleRect.height))
    }
    /// Draw the caret as a block over the next character, for normal and visual states.
    var blockCursor = false {
        didSet {
            guard blockCursor != oldValue else { return }
            needsDisplay = true
        }
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard blockCursor else { return super.drawInsertionPoint(in: rect, color: color, turnedOn: flag) }
        var block = rect
        block.size.width = max(rect.width, blockWidth)
        if flag {
            color.withAlphaComponent(0.45).setFill()
            block.fill(using: .sourceOver)
        } else {
            setNeedsDisplay(block, avoidAdditionalLayout: true)
        }
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        var widened = rect
        if blockCursor { widened.size.width += blockWidth }
        super.setNeedsDisplay(widened, avoidAdditionalLayout: flag)
    }

    private var blockWidth: CGFloat {
        let font = self.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        return ("x" as NSString).size(withAttributes: [.font: font]).width
    }

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, !hasMarkedText(), event.modifierFlags.contains(.command), keyHandler?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }
}

enum KeyEvents {
    /// Device-dependent bits for the left and right Option keys (`NX_DEVICELALTKEYMASK`,
    /// `NX_DEVICERALTKEYMASK`).
    static let leftOption: UInt = 0x20
    static let rightOption: UInt = 0x40

    static let named: [UInt16: String] = [
        48: "TAB", 36: "RET", 76: "RET", 49: "SPC", 53: "ESC", 51: "DEL", 117: "<delete>",
        123: "<left>", 124: "<right>", 125: "<down>", 126: "<up>",
        115: "<home>", 119: "<end>", 116: "<prior>", 121: "<next>",
        122: "<f1>", 120: "<f2>", 99: "<f3>", 118: "<f4>", 96: "<f5>", 97: "<f6>",
        98: "<f7>", 100: "<f8>", 101: "<f9>", 109: "<f10>", 103: "<f11>", 111: "<f12>",
    ]

    /// The chord for a key press, or nil when it types a character with Option.
    static func chord(for event: NSEvent, optionAsMeta: OptionAsMeta) -> KeyChord? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags
        var modifiers: KeyChord.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) {
            let raw = flags.rawValue
            let meta = (raw & leftOption != 0 && optionAsMeta.contains(.left)) || (raw & rightOption != 0 && optionAsMeta.contains(.right))
            if meta || !modifiers.isEmpty {
                modifiers.insert(.meta)
            } else {
                return nil
            }
        }
        if let name = named[event.keyCode] {
            if flags.contains(.shift) { modifiers.insert(.shift) }
            return KeyChord(name, modifiers)
        }
        guard let characters = event.charactersIgnoringModifiers, characters.count == 1 else { return nil }
        return KeyChord(characters, modifiers)
    }
}
#endif
