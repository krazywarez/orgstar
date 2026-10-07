import Foundation
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp

struct CaptureInboxTests {
    @Test func takesLinksOldestFirstOnce() throws {
        let folder = try Folder()
        let inbox = CaptureInbox(folder: folder.url.appendingPathComponent("Captures"))
        #expect(inbox.take() == [])
        try inbox.add("org-protocol://capture?body=one")
        try inbox.add("org-protocol://capture?body=two")
        #expect(inbox.take() == ["org-protocol://capture?body=one", "org-protocol://capture?body=two"])
        #expect(inbox.take() == [])
    }

    @Test func keepsTheTemplateList() throws {
        let folder = try Folder()
        let inbox = CaptureInbox(folder: folder.url.appendingPathComponent("Captures"))
        #expect(inbox.templates() == [])
        let templates = [CaptureInbox.Template(key: "t", name: "Task"), CaptureInbox.Template(key: "w", name: "Web page")]
        try inbox.setTemplates(templates)
        #expect(inbox.templates() == templates)
    }
}

@MainActor
struct CaptureWithoutWindowTests {
    @Test func filesWithTheKeyedTemplateAndDefaultAnswers() async throws {
        let notes = try Folder()
        let todo = try notes.write("todo.org", "* Inbox\n")
        let workspace = try WorkspaceModel(directory: nil)
        try await workspace.addRoot(notes.url)
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        let clock = ClockModel(file: notes.url.appendingPathComponent("clock.json"))
        let templates = [
            CaptureTemplates.defaults[0],
            CaptureTemplate(key: "x", name: "Errand", target: .headline(file: "todo.org", headline: "Inbox"), template: "* TODO %^{What|Buy milk}\n%i"),
        ]
        let chosen = session.capture("from the share sheet", templateKey: "x", templates: templates, workspace: workspace, clock: clock, clipboard: "", userName: "")
        #expect((try? chosen.get())?.key == "x")
        #expect(try String(contentsOf: todo, encoding: .utf8) == "* Inbox\n** TODO Buy milk\nfrom the share sheet\n")

        let missing = session.capture("x", templateKey: "nope", templates: templates, workspace: workspace, clock: clock, clipboard: "", userName: "")
        guard case .failure(let error) = missing else { Issue.record("filed with a missing template"); return }
        #expect(error.message == "No capture template \"nope\"")
    }
}
