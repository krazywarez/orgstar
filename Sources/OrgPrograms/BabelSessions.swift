#if os(macOS)
import Foundation
import OrgCore

/// Interpreters kept running for `:session`, one per file folder, interpreter and session name.
/// Each run sends the code, then a line that prints a marker; the output is what came before it.
public final class BabelSessions: @unchecked Sendable {
    public static let shared = BabelSessions()

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]

    final class Session: @unchecked Sendable {
        let process = Process()
        private let input: FileHandle
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()
        private var waiting: (marker: String, continuation: CheckedContinuation<(String, String, Int32), Error>)?

        init(executable: String, arguments: [String], directory: URL) throws {
            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
            process.environment = BabelRunner.environment
            process.currentDirectoryURL = directory
            process.standardInput = inPipe
            process.standardOutput = outPipe
            process.standardError = errPipe
            input = inPipe.fileHandleForWriting
            outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.received(handle.availableData, error: false) }
            errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.received(handle.availableData, error: true) }
            process.terminationHandler = { [weak self] _ in self?.ended() }
            try process.run()
        }

        /// Sends `code` and waits for `marker`, printed with the last status after it.
        func run(_ code: String, marker: String) async throws -> (stdout: String, stderr: String, status: Int32) {
            let result: (String, String, Int32) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(String, String, Int32), Error>) in
                lock.withLock {
                    stdout = Data()
                    stderr = Data()
                    waiting = (marker, continuation)
                }
                do {
                    try input.write(contentsOf: Data(code.utf8))
                } catch {
                    finish(.failure(error))
                }
            }
            return (result.0, result.1, result.2)
        }

        private func received(_ data: Data, error: Bool) {
            guard !data.isEmpty else { return }
            var result: (String, String, Int32)?
            lock.withLock {
                if error { stderr.append(data) } else { stdout.append(data) }
                guard let marker = waiting?.marker, !error else { return }
                let text = String(decoding: stdout, as: UTF8.self)
                guard let found = text.range(of: marker + " ", options: .backwards),
                      let lineEnd = text[found.upperBound...].firstIndex(of: "\n") else { return }
                let status = Int32(text[found.upperBound..<lineEnd].trimmingCharacters(in: .whitespaces)) ?? 0
                result = (String(text[..<found.lowerBound]), String(decoding: stderr, as: UTF8.self), status)
            }
            if let result { finish(.success(result)) }
        }

        private func ended() {
            finish(.failure(BabelRunner.Failure(description: "The session ended.")))
        }

        private func finish(_ result: Result<(String, String, Int32), Error>) {
            let continuation = lock.withLock { () -> CheckedContinuation<(String, String, Int32), Error>? in
                defer { waiting = nil }
                return waiting?.continuation
            }
            continuation?.resume(with: result)
        }

        func stop() { if process.isRunning { process.terminate() } }
    }

    /// The Ruby and Node sessions' loops: each line names a program file, the marker and the
    /// file the value goes to (empty for output), and the program runs where earlier ones left
    /// their variables. The value is written as the non-session wrappers write it.
    static let rubyDriver = #"""
        $stdout.sync = true
        $stderr.sync = true
        __orgstar_binding = binding
        while (__orgstar_line = $stdin.gets)
          __orgstar_file, __orgstar_marker, __orgstar_result = __orgstar_line.chomp.split("\t", 3)
          begin
            __orgstar_value = eval(File.read(__orgstar_file), __orgstar_binding, "org-babel")
            if __orgstar_result && !__orgstar_result.empty?
              File.open(__orgstar_result, "w") { |f| f.write(__orgstar_value.class == String ? __orgstar_value : __orgstar_value.inspect) }
            end
          rescue Exception => __orgstar_error
            $stderr.puts __orgstar_error.full_message(highlight: false)
          end
          $stdout.print "\n#{__orgstar_marker} 0\n"
        end
        """#
    static let nodeDriver = #"""
        const vm = require('vm'), fs = require('fs'), util = require('util');
        globalThis.require = require;
        require('readline').createInterface({ input: process.stdin }).on('line', line => {
          const [file, marker, result] = line.split('\t');
          try {
            const value = vm.runInThisContext(fs.readFileSync(file, 'utf8'), { filename: 'org-babel' });
            if (result) fs.writeFileSync(result, util.inspect(value));
          } catch (e) {
            process.stderr.write(String(e && e.stack || e) + '\n');
          }
          process.stdout.write('\n' + marker + ' 0\n');
        });
        """#

    /// Runs a session job: the session starts in `directory` the first time.
    func run(_ job: BabelJob, name: String, executable: String, kind: BabelJob.SessionKind, directory: URL, resultFile: URL) async throws -> BabelOutput {
        let key = [directory.path, executable, name].joined(separator: "\u{1}")
        let session: Session = try lock.withLock {
            if let existing = sessions[key], existing.process.isRunning { return existing }
            let arguments: [String] = switch kind {
            case .shell: []
            case .python: ["-u", "-i", "-q"]
            case .ruby: ["-e", Self.rubyDriver]
            case .node: ["-e", Self.nodeDriver]
            case .r: ["--slave", "--no-save", "--no-restore"]
            }
            let created = try Session(executable: executable, arguments: arguments, directory: directory)
            sessions[key] = created
            return created
        }
        let marker = "__orgstar_done_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        let program = job.input.replacingOccurrences(of: Babel.resultFileToken, with: resultFile.path)
        let file = resultFile.deletingLastPathComponent().appendingPathComponent("program")
        let code: String
        switch kind {
        case .python:
            try program.write(to: file, atomically: true, encoding: .utf8)
            let path = file.path.replacingOccurrences(of: "'", with: "\\'")
            code = "try:\n    exec(compile(open('\(path)').read(), '<org-babel>', 'exec'), globals())\nfinally:\n    print('\\n\(marker) 0', flush=True)\n\n"
        case .ruby, .node:
            try program.write(to: file, atomically: true, encoding: .utf8)
            code = [file.path, marker, job.finish.output ? "" : resultFile.path].joined(separator: "\t") + "\n"
        case .r:
            try program.write(to: file, atomically: true, encoding: .utf8)
            let path = file.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            code = "tryCatch(source(\"\(path)\", echo = FALSE, print.eval = TRUE), error = function(e) message(\"Error: \", conditionMessage(e)))\ncat(\"\\n\(marker) 0\\n\")\n"
        case .shell:
            code = program + (program.hasSuffix("\n") ? "" : "\n") + "printf '\\n%s %d\\n' \(marker) $?\n"
        }
        let (stdout, stderr, status) = try await withTaskCancellationHandler {
            try await session.run(code, marker: marker)
        } onCancel: {
            session.stop()
        }
        // The marker starts on a line of its own; the newline before it isn't output.
        var output = stdout
        if output.hasSuffix("\n") { output.removeLast() }
        // Interactive Python prompts go to standard error.
        let problems = stderr.split(separator: "\n").filter { $0.range(of: "^(>>> |\\.\\.\\. )*$", options: .regularExpression) == nil }
        return BabelOutput(stdout: output, resultFile: try? String(contentsOf: resultFile, encoding: .utf8),
                           stderr: problems.joined(separator: "\n"), status: status)
    }

    /// Stops every session, as when the app quits.
    public func stopAll() {
        lock.withLock {
            sessions.values.forEach { $0.stop() }
            sessions = [:]
        }
    }
}
#endif
