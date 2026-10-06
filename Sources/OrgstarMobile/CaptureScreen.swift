#if os(iOS)
import OrgApp
import OrgCore
import SwiftUI

/// Capture with a template: its text to edit, filed where the template says.
struct CaptureScreen: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    let request: CaptureRequest
    @Environment(\.dismiss) private var dismiss
    @State private var templates: [CaptureTemplate] = []
    @State private var key: String?
    @State private var text = ""
    @State private var selection: TextSelection?
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var template: CaptureTemplate? { templates.first { $0.key == key } }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Template", selection: $key) {
                    ForEach(templates) { Text($0.name).tag(Optional($0.key)) }
                }
                Section {
                    TextEditor(text: $text, selection: $selection)
                        .font(.body.monospaced())
                        .frame(minHeight: 200)
                        .focused($focused)
                } footer: {
                    if let problem { Text(problem).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("File", action: file).disabled(template == nil) }
            }
        }
        .onAppear {
            let loaded = CaptureTemplates.load()
            templates = loaded.templates
            problem = loaded.problems.first
            key = request.template.flatMap { wanted in templates.first { $0.key == wanted }?.key } ?? templates.first?.key
            focused = true
        }
        .onChange(of: key, initial: true) { fill() }
    }

    /// The template expanded, its prompts taking their defaults.
    private func fill() {
        guard let template else { return }
        var context = CaptureContext(
            initial: request.properties["initial"] ?? "", annotation: request.properties["annotation"] ?? "",
            allTags: (try? workspace.index.tags()) ?? []
        )
        context.linkProperties = request.properties
        let answers = Capture.questions(template.template, context: context).map { _ in "" }
        switch Capture.fill(template.template, context: context, answers: answers) {
        case .success(let filled):
            text = filled.text
            // Where the template's `%?` was.
            selection = TextSelection(insertionPoint: String.Index(utf16Offset: filled.cursor, in: filled.text))
        case .failure(.message(let message)): problem = message
        }
    }

    private func file() {
        guard let template else { return }
        var file: String?
        switch template.target {
        case .id(let id):
            guard let location = try? workspace.index.headings(withID: id).first else {
                problem = "Cannot find target ID \"\(id)\""
                return
            }
            file = location.path
        case .clock:
            problem = "There's no running clock on iOS"
            return
        default:
            break
        }
        switch session.capture(text, template: template, root: workspace.rootPaths.first, file: file) {
        case .failure(let error): problem = error.message
        case .success: dismiss()
        }
    }
}
#endif
