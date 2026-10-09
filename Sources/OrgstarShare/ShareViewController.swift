#if os(iOS)
import OrgApp
import OrgCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The share sheet's Orgstar: the shared page or text with a template and a note, left for the
/// app, which opens its capture sheet with them the next time it's active.
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

/// What the other app shared: a page's address and title, or text.
struct Shared {
    var url: URL?
    var title = ""
    var text = ""

    @MainActor
    static func load(_ items: [NSExtensionItem]) async -> Shared {
        var shared = Shared()
        for item in items {
            if shared.title.isEmpty, let title = item.attributedTitle?.string ?? item.attributedContentText?.string { shared.title = title }
            for provider in item.attachments ?? [] {
                if shared.url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
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
    @State private var title = ""
    @State private var note = ""
    @State private var template: String?

    var body: some View {
        NavigationStack {
            Form {
                if !available {
                    Text("Orgstar's shared folder isn't available.").foregroundStyle(.red)
                }
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
                    Text("Orgstar files it with the template when you next open it.")
                }
            }
            .navigationTitle("Orgstar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { finish(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Capture") {
                        finish(OrgProtocol.captureURL(template: template, url: shared.url?.absoluteString, title: title, body: note))
                    }
                    .disabled(!available)
                }
            }
        }
        .onAppear {
            title = shared.title
            note = shared.text
            template = templates.first?.key
        }
    }
}
#endif
