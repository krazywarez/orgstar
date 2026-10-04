import Foundation

/// A file's bytes and their decoded text. Only UTF-8 (with or without a BOM) is editable;
/// anything else decodes with replacement characters for display and is never written back.
public struct SourceText: Sendable {
    public let originalBytes: [UInt8]
    public let hasBOM: Bool
    public let isValidUTF8: Bool
    /// Decoded text without the BOM.
    public let text: String

    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    public init(bytes: [UInt8]) {
        originalBytes = bytes
        hasBOM = bytes.starts(with: Self.bom)
        let body = hasBOM ? Array(bytes.dropFirst(3)) : bytes
        if let decoded = String(validating: body, as: UTF8.self) {
            text = decoded
            isValidUTF8 = true
        } else {
            text = String(decoding: body, as: UTF8.self)
            isValidUTF8 = false
        }
    }

    public init(_ text: String) {
        self.init(bytes: Array(text.utf8))
    }

    public var isEditable: Bool { isValidUTF8 }

    /// Bytes to write for `newText`. Unchanged text returns the original bytes. Valid UTF-8
    /// round-trips through `String` unchanged, so untouched spans keep their exact bytes.
    public func encode(_ newText: String) -> [UInt8] {
        if newText == text { return originalBytes }
        precondition(isEditable, "a read-only document cannot be re-encoded")
        return (hasBOM ? Self.bom : []) + Array(newText.utf8)
    }
}
