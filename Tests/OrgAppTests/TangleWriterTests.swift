import Foundation
import Testing
@testable import OrgApp
@testable import OrgCore

struct TangleWriterTests {
    @Test func writesMakesFoldersAndSetsModes() throws {
        let folder = try Folder()
        let source = try folder.write("notes.org", """
            #+begin_src sh :tangle bin/run.sh :mkdirp yes :shebang "#!/bin/sh"
            echo run
            #+end_src
            #+begin_src text :tangle missing/x.txt
            x
            #+end_src
            """)
        let text = try String(contentsOf: source, encoding: .utf8)
        let output = try Tangle.run(text: text, path: source.path).get()
        // The second file's folder is missing and it has no :mkdirp.
        #expect(throws: TangleWriter.Failure.self) { try TangleWriter.write(output, source: source.path) }
        let script = folder.url.appendingPathComponent("bin/run.sh")
        #expect(try String(contentsOf: script, encoding: .utf8) == "#!/bin/sh\necho run\n")
        let mode = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
    }

    @Test func leavesUnchangedFilesAndRefusesItsOwnSource() throws {
        let folder = try Folder()
        let source = try folder.write("notes.org", "#+begin_src sh :tangle yes\necho a\n#+end_src\n")
        let text = try String(contentsOf: source, encoding: .utf8)
        let output = try Tangle.run(text: text, path: source.path).get()
        let paths = try TangleWriter.write(output, source: source.path)
        #expect(paths == [folder.url.appendingPathComponent("notes.sh").path])
        let written = try FileManager.default.attributesOfItem(atPath: paths[0])[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 1.1)
        try TangleWriter.write(output, source: source.path)
        #expect(try FileManager.default.attributesOfItem(atPath: paths[0])[.modificationDate] as? Date == written)
        #expect(TangleWriter.message(output, source: source.path) == "Tangled 1 code block from notes.org")

        let own = try Tangle.run(text: "#+begin_src org :tangle notes.org\nx\n#+end_src\n", path: source.path).get()
        #expect(throws: TangleWriter.Failure(message: "Not allowed to tangle into the same file as self")) {
            try TangleWriter.write(own, source: source.path)
        }
    }

    @Test func aModeThatCantBeSetIsReportedAfterWriting() throws {
        let folder = try Folder()
        let script = folder.url.appendingPathComponent("run.sh").path
        // Anyone can write /dev/null, but only its owner can change its mode.
        let output = Tangle.Output(files: [
            Tangle.File(path: "/dev/null", contents: "x\n", mode: 0o755, makeDirectories: false),
            Tangle.File(path: script, contents: "#!/bin/sh\n", mode: 0o755, makeDirectories: false),
        ], blocks: 2)
        let source = folder.url.appendingPathComponent("notes.org").path
        do {
            try TangleWriter.write(output, source: source)
            Issue.record("The mode of /dev/null was set")
        } catch {
            #expect(error.message.hasPrefix("Tangled 2 code blocks from notes.org, but can't set the mode of /dev/null"))
        }
        #expect(try String(contentsOfFile: script, encoding: .utf8) == "#!/bin/sh\n")
        #expect(try FileManager.default.attributesOfItem(atPath: script)[.posixPermissions] as? Int == 0o755)
    }
}
