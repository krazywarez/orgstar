#if os(iOS)
import OrgApp
import OrgCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The share sheet's Orgstar: the shared page or text with a template and a note, left for the
/// app, which opens its capture sheet with them the next time it's active; or shared files,
/// which the app asks to attach to an entry.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let context = extensionContext
        Task { @MainActor in
            let shared = await Shared.load(items)
            let inbox = CaptureInbox()
            let form = ShareForm(shared: shared, templates: inbox?.templates() ?? [], available: inbox != nil) { link in
                if let link { try? inbox?.add(link) }
                context?.completeRequest(returningItems: nil)
            } attach: { files in
                try? AttachmentInbox()?.add(files)
                context?.completeRequest(returningItems: nil)
            }
            let host = UIHostingController(rootView: form)
            addChild(host)
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(host.view)
            host.didMove(toParent: self)
        }
    }
}

/// What the other app shared: a page's address and title, text, or files.
struct Shared {
    var url: URL?
    var title = ""
    var text = ""
    /// Copies of shared files, photos and videos.
    var files: [URL] = []

    /// Whether the item is a file to attach rather than a page or text.
    static func isFile(_ provider: NSItemProvider) -> Bool {
        provider.registeredContentTypes.contains { type in
            type.conforms(to: .fileURL) || ([.image, .movie, .audio, .pdf, .archive] as [UTType]).contains { type.conforms(to: $0) }
        }
    }

    /// A copy of the provider's file, under its own name.
    @MainActor
    static func copy(_ provider: NSItemProvider) async -> URL? {
        guard let type = provider.registeredContentTypes.first(where: { !$0.conforms(to: .fileURL) }) ?? provider.registeredContentTypes.first else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let copy = folder.appendingPathComponent(url.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    @MainActor
    static func load(_ items: [NSExtensionItem]) async -> Shared {
        var shared = Shared()
        for item in items {
            if shared.title.isEmpty, let title = item.attributedTitle?.string ?? item.attributedContentText?.string { shared.title = title }
            for provider in item.attachments ?? [] {
                if isFile(provider) {
                    if let file = await copy(provider) { shared.files.append(file) }
                } else if shared.url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    shared.url = url
                } else if shared.text.isEmpty, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    shared.text = text
                }
            }
        }
        // Text shared on its own arrives as the item's content too.
        if shared.url == nil, shared.text == shared.title { shared.title = "" }
        return shared
    }
}

struct ShareForm: View {
    let shared: Shared
    let templates: [CaptureInbox.Template]
    let available: Bool
    let finish: (String?) -> Void
    /// Leaves the files for the app to attach.
    let attach: ([URL]) -> Void
    @State private var title = ""
    @State private var note = ""
    @State private var template: String?

    var body: some View {
        NavigationStack {
            Form {
                if !available {
                    Text("orgstar's shared folder isn't available.").foregroundStyle(.red)
                }
                if !shared.files.isEmpty {
                    Section {
                        ForEach(shared.files, id: \.self) { Text($0.lastPathComponent) }
                    } header: {
                        Text("Attach")
                    } footer: {
                        Text("orgstar asks which entry to attach them to when you next open it.")
                    }
                } else {
                    captureSections
                }
            }
            .navigationTitle("orgstar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { finish(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    if shared.files.isEmpty {
                        Button("Capture") {
                            finish(OrgProtocol.captureURL(template: template, url: shared.url?.absoluteString, title: title, body: note))
                        }
                        .disabled(!available)
                    } else {
                        Button("Attach") { attach(shared.files) }.disabled(!available)
                    }
                }
            }
        }
        .onAppear {
            title = shared.title
            note = shared.text
            template = templates.first?.key
        }
    }

    @ViewBuilder
    private var captureSections: some View {
        if !templates.isEmpty {
            Picker("Template", selection: $template) {
                ForEach(templates, id: \.key) { Text($0.name).tag(Optional($0.key)) }
            }
        }
        if let url = shared.url {
            Section("Link") {
                TextField("Title", text: $title)
                Text(url.absoluteString).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        Section("Text") {
            TextEditor(text: $note).frame(minHeight: 120)
        }
        Section {
        } footer: {
            Text("orgstar files it with the template when you next open it.")
        }
    }
}
#endif
