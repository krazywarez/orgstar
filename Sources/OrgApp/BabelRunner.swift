import Foundation
import OrgCore

/// Runs Babel jobs as processes: the interpreter reads the program on standard input, in the
/// file's folder or `:dir`.
public enum BabelRunner {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// PATH with the usual install locations, which an app launched from the Dock lacks.
    static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        environment["PATH"] = (path + extra.filter { !path.contains($0) }).joined(separator: ":")
        return environment
    }

    public static func run(_ job: BabelJob, fileDirectory: URL, timeout: Duration = .seconds(300)) async throws -> BabelOutput {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-babel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let resultFile = folder.appendingPathComponent("result")
        let input = job.input.replacingOccurrences(of: Babel.resultFileToken, with: resultFile.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.environment = environment
        let stdin = Pipe()
        switch job.runner {
        case .process(let executable, let arguments):
            process.arguments = [executable] + arguments
        case .emacs:
            guard let emacs = EmacsRunner.executable() else { throw Failure(description: "Emacs isn't installed, so Emacs Lisp blocks can't run.") }
            let script = folder.appendingPathComponent("babel.el")
            try input.write(to: script, atomically: true, encoding: .utf8)
            process.arguments = [emacs.path, "-Q", "--batch", "-l", script.path]
        }
        let directory = job.directory.map { URL(fileURLWithPath: $0, relativeTo: fileDirectory).standardizedFileURL } ?? fileDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else { throw Failure(description: "No folder \(directory.path) for :dir.") }
        process.currentDirectoryURL = directory
        let stdout = folder.appendingPathComponent("stdout")
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        let out = try FileHandle(forWritingTo: stdout)
        let stderr = folder.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let err = try FileHandle(forWritingTo: stderr)
        process.standardInput = stdin
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw Failure(description: "Can't start \(process.arguments?.first ?? "the interpreter"): \(error.localizedDescription)")
        }
        if case .process = job.runner {
            let handle = stdin.fileHandleForWriting
            let data = Data(input.utf8)
            // Large programs would fill the pipe; write off the main thread.
            Task.detached {
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try stdin.fileHandleForWriting.close()
        }
        let deadline = ContinuousClock.now + timeout
        while process.isRunning {
            if ContinuousClock.now > deadline {
                process.terminate()
                throw Failure(description: "The block took longer than \(timeout) and was stopped.")
            }
            do {
                try await Task.sleep(for: .milliseconds(30))
            } catch {
                process.terminate()
                throw CancellationError()
            }
        }
        try out.close()
        try err.close()
        let output = (try? String(contentsOf: stdout, encoding: .utf8)) ?? ""
        let errors = (try? String(contentsOf: stderr, encoding: .utf8)) ?? ""
        let result = try? String(contentsOf: resultFile, encoding: .utf8)
        if case .process(let executable, _) = job.runner, process.terminationStatus == 127, output.isEmpty {
            throw Failure(description: "\(executable) isn't installed.")
        }
        return BabelOutput(stdout: output, resultFile: result, stderr: errors, status: process.terminationStatus)
    }
}
