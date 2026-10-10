import Foundation

extension StringProtocol {
    /// Whether the text contains `needle` ignoring ASCII case, by bytes: much faster than a
    /// case-insensitive `range(of:)` over a whole file. `needle` is ASCII.
    public func containsIgnoringASCIICase(_ needle: String) -> Bool {
        let target = Array(needle.lowercased().utf8)
        guard let first = target.first else { return true }
        let firstUpper = first >= 97 && first <= 122 ? first - 32 : first
        func search(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
            guard bytes.count >= target.count else { return false }
            var i = 0
            let last = bytes.count - target.count
            while i <= last {
                let b = bytes[i]
                if b == first || b == firstUpper {
                    var k = 1
                    while k < target.count {
                        var c = bytes[i + k]
                        if c >= 65 && c <= 90 { c += 32 }
                        if c != target[k] { break }
                        k += 1
                    }
                    if k == target.count { return true }
                }
                i += 1
            }
            return false
        }
        if let found = utf8.withContiguousStorageIfAvailable(search) { return found }
        return Array(utf8).withUnsafeBufferPointer(search)
    }
}
