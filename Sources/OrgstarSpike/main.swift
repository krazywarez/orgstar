#if os(macOS)
import AppKit
import OrgDocument
import OrgEditorAppKit

/// A throwaway app for trying the editor by hand: `swift run OrgstarSpike path/to/file.org`.
/// TAB on a heading folds it, Shift-TAB folds everything, ⌘S saves. Edit timings are printed
/// every 50 edits.
@MainActor
final class SpikeDelegate: NSObject, NSApplicationDelegate {
    let url: URL
    var editor: OrgEditor?
    var window: NSWindow?
    var timings: [Duration] = []

    init(url: URL) {
        self.url = url
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bytes = (try? [UInt8](Data(contentsOf: url))) ?? []
        let editor = OrgEditor(document: DocumentState(bytes: bytes), frame: NSRect(x: 0, y: 0, width: 900, height: 1000))
        editor.onEditTiming = { [weak self] in self?.record($0) }
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 1000),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
        )
        window.title = url.lastPathComponent
        window.contentView = editor.makeScrollView()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor.textView)
        self.editor = editor
        self.window = window
        buildMenu()
        NSApp.activate()
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem()
        fileItem.submenu = NSMenu(title: "File")
        fileItem.submenu?.addItem(withTitle: "Save", action: #selector(save), keyEquivalent: "s").target = self
        let editItem = NSMenuItem()
        editItem.submenu = NSMenu(title: "Edit")
        editItem.submenu?.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editItem.submenu?.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editItem.submenu?.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editItem.submenu?.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editItem.submenu?.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu?.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        [appItem, fileItem, editItem].forEach(main.addItem)
        NSApp.mainMenu = main
    }

    @objc func save() {
        guard let editor else { return }
        let recovery = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orgstar/Recovery")
        let saver = Saver(fileSystem: CoordinatedFileSystem(), recovery: FileRecoveryStore(directory: recovery))
        do {
            print("save:", try editor.save(using: saver, to: url))
        } catch {
            print("save failed:", error)
        }
    }

    func record(_ duration: Duration) {
        timings.append(duration)
        guard timings.count % 50 == 0 else { return }
        let sorted = timings.sorted()
        print("edits: \(timings.count)  p50 \(sorted[sorted.count / 2])  p95 \(sorted[sorted.count * 95 / 100])")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

guard CommandLine.arguments.count > 1 else {
    print("usage: OrgstarSpike path/to/file.org")
    exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = SpikeDelegate(url: URL(fileURLWithPath: CommandLine.arguments[1]))
app.delegate = delegate
app.run()
#endif
