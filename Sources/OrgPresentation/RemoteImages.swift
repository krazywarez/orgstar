import CryptoKit
import Foundation
import Observation

/// `org-display-remote-inline-images`: images at http and https links, fetched in the
/// background. `download` keeps them while the app runs; `cache` keeps them on disk too.
@MainActor
@Observable
public final class RemoteImages {
    public static let shared = RemoteImages()

    public enum Mode: String, Sendable {
        case skip, download, cache
    }

    /// Changes when an image arrives, for views that show them.
    public private(set) var version = 0
    @ObservationIgnored private var memory: [URL: Data] = [:]
    @ObservationIgnored private var loading: Set<URL> = []
    @ObservationIgnored private var failed: Set<URL> = []
    @ObservationIgnored private var waiting: [URL: [@MainActor () -> Void]] = [:]
    @ObservationIgnored let directory: URL
    @ObservationIgnored let fetch: @Sendable (URL) async throws -> Data

    public init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("RemoteImages"),
                fetch: @escaping @Sendable (URL) async throws -> Data = RemoteImages.download) {
        self.directory = directory
        self.fetch = fetch
    }

    /// An http(s) GET; other statuses than 2xx fail.
    public nonisolated static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return data
    }

    /// The image's data when it's here; otherwise nil, and `loaded` runs when it has come.
    /// A link that failed isn't fetched again while the app runs.
    public func data(for url: URL, mode: Mode, loaded: @escaping @MainActor () -> Void) -> Data? {
        guard mode != .skip, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        if let data = memory[url] { return data }
        if mode == .cache, let data = try? Data(contentsOf: file(url)) {
            memory[url] = data
            return data
        }
        guard !failed.contains(url) else { return nil }
        waiting[url, default: []].append(loaded)
        guard loading.insert(url).inserted else { return nil }
        let fetch = self.fetch
        Task {
            let data = try? await fetch(url)
            loading.remove(url)
            if let data {
                memory[url] = data
                if mode == .cache {
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try? data.write(to: file(url), options: .atomic)
                }
            } else {
                failed.insert(url)
            }
            version += 1
            for callback in waiting.removeValue(forKey: url) ?? [] { callback() }
        }
        return nil
    }

    /// The cached copy's file, named by a hash of the link.
    func file(_ url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension))
    }
}
