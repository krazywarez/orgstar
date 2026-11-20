import Foundation

/// A zip archive with stored (uncompressed) entries in the order added, as `.docx` and `.odt`
/// files are read.
package struct ZipWriter {
    private var entries: [(name: Data, data: Data, crc: UInt32, offset: UInt32)] = []
    private var archive = Data()

    package init() {}

    package mutating func add(_ name: String, _ text: String) {
        add(name, data: Data(text.utf8))
    }

    package mutating func add(_ name: String, data: Data) {
        let nameData = Data(name.utf8)
        let crc = Self.crc32(data)
        let offset = UInt32(archive.count)
        archive += Self.le32(0x04034b50) + Self.le16(20) + Self.le16(0) + Self.le16(0) + Self.le16(0) + Self.le16(0x21)
        archive += Self.le32(crc) + Self.le32(UInt32(data.count)) + Self.le32(UInt32(data.count))
        archive += Self.le16(UInt16(nameData.count)) + Self.le16(0) + nameData + data
        entries.append((nameData, data, crc, offset))
    }

    package func data() -> Data {
        var central = Data()
        for entry in entries {
            central += Self.le32(0x02014b50) + Self.le16(20) + Self.le16(20) + Self.le16(0) + Self.le16(0) + Self.le16(0) + Self.le16(0x21)
            central += Self.le32(entry.crc) + Self.le32(UInt32(entry.data.count)) + Self.le32(UInt32(entry.data.count))
            central += Self.le16(UInt16(entry.name.count)) + Self.le16(0) + Self.le16(0) + Self.le16(0) + Self.le16(0) + Self.le32(0)
            central += Self.le32(entry.offset) + entry.name
        }
        var end = Self.le32(0x06054b50) + Self.le16(0) + Self.le16(0) + Self.le16(UInt16(entries.count)) + Self.le16(UInt16(entries.count))
        end += Self.le32(UInt32(central.count)) + Self.le32(UInt32(archive.count)) + Self.le16(0)
        return archive + central + end
    }

    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}
