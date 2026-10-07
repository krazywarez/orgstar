import Foundation

// `org-protocol://` URLs (Org 9.8.7's org-protocol.el): `capture` and `store-link`, in the
// new `?key=value` form and the old `:/a/b/c` form.

public enum OrgProtocol {
    public enum Request: Sendable, Equatable {
        /// `org-protocol-capture`: the template key (nil for the template list) and the link
        /// properties `org-link-store-props` sets (`type`, `link`, `description`,
        /// `annotation`, `initial`), absent when nil.
        case capture(template: String?, properties: [String: String])
        /// `org-protocol-store-link`: the link and its title.
        case storeLink(url: String, title: String?)
    }

    public static func parse(_ url: String) -> Request? {
        guard let protocolMatch = url.firstMatch(of: /^org-protocol:\/+/) else { return nil }
        let rest = url[protocolMatch.range.upperBound...]
        for name in ["store-link", "capture"] {
            guard rest.hasPrefix(name), let separator = rest.dropFirst(name.count).firstMatch(of: /^(:\/+|\/*\?)/) else { continue }
            let info = String(rest.dropFirst(name.count)[separator.range.upperBound...])
            let newStyle = !separator.output.1.hasPrefix(":")
            let parts: [(String, String?)] = newStyle ? query(info) : []
            let old = newStyle ? [] : split(info)
            func value(_ key: String) -> String? { parts.first { $0.0 == key }?.1 ?? nil }
            if name == "store-link" {
                let order = assign(old, ["url", "title"])
                let link = newStyle ? value("url") : order["url"] ?? nil
                return .storeLink(url: sanitize(link ?? ""), title: newStyle ? value("title") : order["title"] ?? nil)
            }
            var fields: [String: String?] = [:]
            if newStyle {
                for key in ["template", "url", "title", "body"] { fields[key] = value(key) }
            } else {
                fields = assign(old, old.first?.count == 1 ? ["template", "url", "title", "body"] : ["url", "title", "body"])
            }
            let link = (fields["url"] ?? nil).map(sanitize)
            let title = (fields["title"] ?? nil) ?? ""
            var properties: [String: String] = ["description": title, "initial": (fields["body"] ?? nil) ?? ""]
            if let link {
                properties["link"] = link
                properties["annotation"] = Links.makeString(link, title.contains { !$0.isWhitespace } ? title : link)
                if let type = link.firstMatch(of: /^([a-z]+):/) { properties["type"] = String(type.1) }
            } else {
                properties["annotation"] = title
            }
            return .capture(template: (fields["template"] ?? nil).flatMap { $0.isEmpty ? nil : $0 }, properties: properties)
        }
        return nil
    }

    /// An `org-protocol://capture?…` link, as bookmarklets build them, with every value
    /// percent-encoded so `+`, `&` and `=` survive `parse`.
    public static func captureURL(template: String?, url: String?, title: String, body: String) -> String {
        let fields: [(String, String?)] = [("template", template), ("url", url), ("title", title), ("body", body)]
        return "org-protocol://capture?" + fields.compactMap { key, value in
            value.map { key + "=" + ($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0) }
        }.joined(separator: "&")
    }

    /// `org-protocol-convert-query-to-plist` and `org-link-decode`: `+` is a space; a value
    /// ends at its second `=`.
    static func query(_ info: String) -> [(String, String?)] {
        info.replacingOccurrences(of: "+", with: " ").components(separatedBy: "&").map { pair in
            let c = pair.components(separatedBy: "=")
            return (c[0], c.count > 1 ? decode(c[1]) : nil)
        }
    }

    /// `org-protocol-split-data` with `org-protocol-data-separator`, each part decoded.
    static func split(_ info: String) -> [String] {
        info.split(separator: /\/+|\?/, omittingEmptySubsequences: false).map { decode(String($0)) }
    }

    /// `org-protocol-assign-parameters`: values in order, then the rest as key, value.
    static func assign(_ data: [String], _ order: [String]) -> [String: String?] {
        var result: [String: String?] = [:]
        var data = data[...]
        for key in order { result[key] = data.popFirst() }
        while let key = data.popFirst() { result[key] = data.popFirst() }
        return result
    }

    /// `org-link-decode`: `%XX` sequences as UTF-8.
    static func decode(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }

    /// `org-protocol-sanitize-uri`: `scheme:/a/b` back to `scheme://a/b`.
    static func sanitize(_ uri: String) -> String {
        guard uri.firstMatch(of: /^[a-z]+:\//) != nil else { return uri }
        let parts = uri.split(separator: /\/+/, omittingEmptySubsequences: false)
        return parts[0] + "//" + parts.dropFirst().joined(separator: "/")
    }
}
