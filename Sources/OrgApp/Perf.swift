import Foundation
import os

/// Responsiveness messages for the debug console (subsystem `sh.krz.orgstar`, category
/// `perf`): work that took longer than `threshold`, and stalls of the main thread. Times are
/// wall-clock, so async work includes its waits. Measured work is also an interval in
/// Instruments' os_signpost track.
public enum Perf {
    public static let log = Logger(subsystem: "sh.krz.orgstar", category: "perf")
    static let signposter = OSSignposter(logger: log)
    /// Work faster than this, about one frame, isn't logged.
    public static let threshold = Duration.milliseconds(16)

    @discardableResult
    public static func measure<T>(_ name: StaticString, _ detail: @autoclosure () -> String = "", _ work: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        let start = ContinuousClock.now
        defer {
            signposter.endInterval(name, state)
            report(name, ContinuousClock.now - start, detail())
        }
        return try work()
    }

    @discardableResult
    public static func measure<T>(
        _ name: StaticString, _ detail: @autoclosure () -> String = "", _ work: () async throws -> T
    ) async rethrows -> T {
        let state = signposter.beginInterval(name)
        let start = ContinuousClock.now
        defer {
            signposter.endInterval(name, state)
            report(name, ContinuousClock.now - start, detail())
        }
        return try await work()
    }

    /// Work timed from `Perf.begin` to `end`, for a function's whole body: `defer { interval.end() }`.
    public struct Interval {
        let name: StaticString
        let state: OSSignpostIntervalState
        let start = ContinuousClock.now

        public func end(_ detail: @autoclosure () -> String = "") {
            Perf.signposter.endInterval(name, state)
            Perf.report(name, ContinuousClock.now - start, detail())
        }
    }

    public static func begin(_ name: StaticString) -> Interval {
        Interval(name: name, state: signposter.beginInterval(name))
    }

    static func report(_ name: StaticString, _ elapsed: Duration, _ detail: String) {
        guard elapsed >= threshold else { return }
        log.notice("\(String(describing: name), privacy: .public) took \(milliseconds(elapsed)) ms \(detail, privacy: .public)")
    }

    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    nonisolated(unsafe) private static var watching = false

    /// Logs each time the main thread takes `limit` or longer to run a block sent to it: a
    /// tap or a frame waited that long. The messages before it say what ran.
    public static func watchMainThread(limit: Duration = .milliseconds(100)) {
        guard !watching else { return }
        watching = true
        let thread = Thread {
            while true {
                let sent = ContinuousClock.now
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { done.signal() }
                done.wait()
                let waited = ContinuousClock.now - sent
                if waited >= limit { log.error("main thread blocked for \(milliseconds(waited)) ms") }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        thread.name = "Perf.watchMainThread"
        thread.qualityOfService = .utility
        thread.start()
    }
}
