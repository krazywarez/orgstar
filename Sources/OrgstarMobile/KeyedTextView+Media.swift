#if os(iOS)
import UIKit
import UniformTypeIdentifiers

/// Images pasted and files dropped on the text view, for `yank-media` and Org's drag-and-drop
/// handlers. Text goes to the text system as before.
extension KeyedTextView: UITextDropDelegate {
    /// The image on `pasteboard` and the extension for it, when there is no text: PNG, JPEG
    /// and GIF as they are, anything else UIKit reads as PNG.
    static func image(on pasteboard: UIPasteboard) -> (data: Data, ext: String)? {
        guard !pasteboard.hasStrings, pasteboard.hasImages else { return nil }
        for (type, ext) in [(UTType.png, "png"), (.jpeg, "jpeg"), (.gif, "gif")] {
            if let data = pasteboard.data(forPasteboardType: type.identifier) { return (data, ext) }
        }
        return pasteboard.image?.pngData().map { ($0, "png") }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), isEditable, onImage != nil, MobileEditor.pasteboard.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if isEditable, let image = Self.image(on: MobileEditor.pasteboard), onImage?(image.data, image.ext) == true { return }
        super.paste(sender)
    }

    /// A drop of files without text, which the editor attaches.
    func takesDrop(_ session: any UIDropSession) -> Bool {
        isEditable && onFiles != nil && !session.hasItemsConforming(toTypeIdentifiers: [UTType.plainText.identifier])
            && session.items.allSatisfy { $0.itemProvider.registeredContentTypes.contains { $0.conforms(to: .data) } }
    }

    func textDroppableView(_ textDroppableView: UIView & UITextDroppable, proposalForDrop drop: any UITextDropRequest) -> UITextDropProposal {
        guard takesDrop(drop.dropSession) else { return drop.suggestedProposal }
        let proposal = UITextDropProposal(operation: .copy)
        proposal.dropPerformer = .delegate
        return proposal
    }

    func textDroppableView(_ textDroppableView: UIView & UITextDroppable, willPerformDrop drop: any UITextDropRequest) {
        guard takesDrop(drop.dropSession) else { return }
        selectedRange = NSRange(location: offset(from: beginningOfDocument, to: drop.dropPosition), length: 0)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Dropped-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let providers = drop.dropSession.items.map(\.itemProvider)
        let files = DroppedFiles()
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            guard let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .data) }) else { continue }
            group.enter()
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                defer { group.leave() }
                guard let url else { return }
                // Each in a folder of its own, so two drops of the same name stay apart.
                let target = folder.appendingPathComponent("\(index)").appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? FileManager.default.copyItem(at: url, to: target)) != nil { files.add(target, at: index) }
            }
        }
        group.notify(queue: .main) { [weak self] in
            let dropped = files.inOrder
            if !dropped.isEmpty { _ = self?.onFiles?(dropped) }
        }
    }
}

/// Files copied out of a drop's item providers, which call back on their own queues.
private final class DroppedFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [Int: URL] = [:]
    func add(_ file: URL, at index: Int) { lock.withLock { files[index] = file } }
    var inOrder: [URL] { lock.withLock { files.sorted { $0.key < $1.key }.map(\.value) } }
}
#endif
