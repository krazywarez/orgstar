#if os(macOS)
import Foundation
import OrgApp
import OrgCore

extension PlotOutput {
    /// gnuplot on the `PATH` Babel uses, when installed.
    public static var gnuplot: URL? {
        let path = BabelRunner.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        return path.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("gnuplot") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// `org-plot/gnuplot` through gnuplot: the data file and script org-plot writes, run with
    /// the output at `file:`, or a PNG for showing when there's none. Returns the image.
    public static func runGnuplot(_ plot: TablePlot.Plot, directory: URL?, gnuplot: URL) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-plot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dataFile = folder.appendingPathComponent("data.tsv")
        var plot = plot
        let output = file(plot, directory: directory) ?? folder.appendingPathComponent("plot.png")
        if plot.options.file == nil { plot.options.values["file"] = .string(output.path) }
        let (data, labels): (String, [(Int, String)]) = plot.options.type == "grid" ? TablePlot.gridData(plot) : (TablePlot.data(plot), [])
        try data.write(to: dataFile, atomically: true, encoding: .utf8)
        let setupFile = folder.appendingPathComponent("setup.gp")
        if plot.options.type == "radar", plot.options["script"] == nil { try TablePlot.radarSetup(plot).write(to: setupFile, atomically: true, encoding: .utf8) }
        var script = TablePlot.script(plot, dataFile: dataFile.path, output: output.path, yLabels: labels, setupFile: setupFile.path)
        if let custom = plot.options["script"]?.description {
            let path = OrgPaths.expandingTilde(custom)
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : (directory ?? folder).appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw Failure(description: "Can't read \(custom)") }
            script = TablePlot.script(plot, dataFile: dataFile.path, output: output.path, yLabels: labels, preface: true)
                + "\n" + text.replacingOccurrences(of: "$datafile", with: dataFile.path)
        }
        let scriptFile = folder.appendingPathComponent("plot.gp")
        try script.write(to: scriptFile, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = gnuplot
        process.arguments = [scriptFile.path]
        process.currentDirectoryURL = directory
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        while process.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        guard process.terminationStatus == 0 else {
            throw Failure(description: "gnuplot: " + String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}
#endif
