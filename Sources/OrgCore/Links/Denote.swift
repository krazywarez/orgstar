import Foundation

/// Denote's file naming, as `denote-retrieve-filename-identifier` reads it: the identifier
/// starts the name (`20261119T120000--title__keywords.org`), or follows `@@` when
/// `denote-file-name-components-order` puts it elsewhere.
public enum Denote {
    /// The identifier in the file name at `path`, or nil when it has none.
    public static func identifier(ofFile path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        if let match = name.firstMatch(of: /^(\d{8}T\d{6})(?:--|__|==|@@|\.|$)/) { return String(match.1) }
        if let match = name.firstMatch(of: /@@([^.]+?)(?=--|__|==|@@|\.|$)/) { return String(match.1) }
        return nil
    }

    /// A `denote:` link's path split at `::` into the identifier and the search.
    public static func split(_ path: String) -> (identifier: String, search: String?) {
        guard let range = path.range(of: "::") else { return (path, nil) }
        return (String(path[..<range.lowerBound]), String(path[range.upperBound...]))
    }

    /// The file `denote-get-path-by-id` finds: the one whose name has `identifier`, an Org
    /// file before any other.
    public static func file(withIdentifier identifier: String, in paths: [String]) -> String? {
        let matches = paths.filter { Self.identifier(ofFile: $0) == identifier }
        return matches.first { ($0 as NSString).pathExtension == "org" } ?? matches.first
    }
}
