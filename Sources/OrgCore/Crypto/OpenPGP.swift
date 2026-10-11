import CommonCrypto
import CryptoKit
import Foundation

/// Passphrase-encrypted OpenPGP messages (RFC 4880), as `gpg --symmetric --armor` writes and
/// reads them: a symmetric-key session packet with a string-to-key specifier, an integrity
/// protected data packet (MDC), and inside it literal data, compressed or not. AES ciphers
/// only; no public keys, no AEAD packets.
public enum OpenPGP {
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - Armor

    /// `-----BEGIN PGP MESSAGE-----`, base64 in lines of 64, the CRC-24 checksum, the end
    /// line, and a final newline.
    public static func armor(_ data: Data) -> String {
        let base64 = data.base64EncodedString()
        var lines: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        var crc = crc24(data).bigEndian
        let checksum = withUnsafeBytes(of: &crc) { Data($0.dropFirst()) }.base64EncodedString()
        return "-----BEGIN PGP MESSAGE-----\n\n" + lines.joined(separator: "\n") + "\n=" + checksum + "\n-----END PGP MESSAGE-----\n"
    }

    /// The bytes of an armored message, its checksum checked when it has one.
    public static func dearmor(_ text: String) throws -> Data {
        var lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let begin = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN PGP MESSAGE") }) else { throw Failure("Not a PGP message") }
        lines = Array(lines[(begin + 1)...])
        // Header lines such as `Version:`, up to a blank line.
        if let blank = lines.firstIndex(of: ""), lines[..<blank].allSatisfy({ $0.contains(":") }) { lines = Array(lines[(blank + 1)...]) }
        var body = ""
        var checksum: String?
        for line in lines {
            if line.hasPrefix("-----END") { break }
            if line.hasPrefix("=") { checksum = String(line.dropFirst()); continue }
            body += line
        }
        guard let data = Data(base64Encoded: body) else { throw Failure("The PGP message is damaged") }
        if let checksum, let sum = Data(base64Encoded: checksum), sum.count == 3 {
            let crc = crc24(data)
            guard [UInt8((crc >> 16) & 0xff), UInt8((crc >> 8) & 0xff), UInt8(crc & 0xff)] == Array(sum) else { throw Failure("The PGP message's checksum is wrong") }
        }
        return data
    }

    static func crc24(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xB704CE
        for byte in data {
            crc ^= UInt32(byte) << 16
            for _ in 0..<8 {
                crc <<= 1
                if crc & 0x1000000 != 0 { crc ^= 0x1864CFB }
            }
        }
        return crc & 0xFFFFFF
    }

    // MARK: - Packets

    struct Packet {
        let tag: Int
        let body: Data
    }

    /// The packets in `data`, partial lengths joined.
    static func packets(_ data: Data) throws -> [Packet] {
        let bytes = [UInt8](data)
        var i = 0
        var out: [Packet] = []
        func need(_ n: Int) throws { guard i + n <= bytes.count else { throw Failure("The PGP message is cut short") } }
        while i < bytes.count {
            let ctb = bytes[i]
            guard ctb & 0x80 != 0 else { throw Failure("The PGP message is damaged") }
            i += 1
            var body = Data()
            let tag: Int
            if ctb & 0x40 != 0 {
                tag = Int(ctb & 0x3f)
                while true {
                    try need(1)
                    let first = Int(bytes[i])
                    i += 1
                    var length: Int
                    var partial = false
                    switch first {
                    case 0..<192: length = first
                    case 192..<224:
                        try need(1)
                        length = ((first - 192) << 8) + Int(bytes[i]) + 192
                        i += 1
                    case 255:
                        try need(4)
                        length = bytes[i..<(i + 4)].reduce(0) { $0 << 8 | Int($1) }
                        i += 4
                    default:
                        length = 1 << (first & 0x1f)
                        partial = true
                    }
                    try need(length)
                    body.append(contentsOf: bytes[i..<(i + length)])
                    i += length
                    if !partial { break }
                }
            } else {
                tag = Int((ctb >> 2) & 0x0f)
                let length: Int
                switch ctb & 3 {
                case 0:
                    try need(1)
                    length = Int(bytes[i]); i += 1
                case 1:
                    try need(2)
                    length = Int(bytes[i]) << 8 | Int(bytes[i + 1]); i += 2
                case 2:
                    try need(4)
                    length = bytes[i..<(i + 4)].reduce(0) { $0 << 8 | Int($1) }; i += 4
                default:
                    length = bytes.count - i
                }
                try need(length)
                body.append(contentsOf: bytes[i..<(i + length)])
                i += length
            }
            out.append(Packet(tag: tag, body: body))
        }
        return out
    }

    /// A new-format packet with a definite length.
    static func packet(_ tag: Int, _ body: Data) -> Data {
        var out = Data([0xC0 | UInt8(tag)])
        switch body.count {
        case 0..<192: out.append(UInt8(body.count))
        case 192..<8384:
            let n = body.count - 192
            out.append(contentsOf: [UInt8(n >> 8 + 192), UInt8(n & 0xff)])
        default:
            out.append(255)
            out.append(contentsOf: (0..<4).reversed().map { UInt8((body.count >> ($0 * 8)) & 0xff) })
        }
        return out + body
    }

    // MARK: - Keys from passphrases

    /// AES's key sizes by OpenPGP's cipher numbers.
    static let keySizes = [7: 16, 8: 24, 9: 32]

    static func hash(_ algorithm: Int, _ data: Data) throws -> Data {
        switch algorithm {
        case 1: return Data(Insecure.MD5.hash(data: data))
        case 2: return Data(Insecure.SHA1.hash(data: data))
        case 8: return Data(SHA256.hash(data: data))
        case 9: return Data(SHA384.hash(data: data))
        case 10: return Data(SHA512.hash(data: data))
        case 11:
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA224_DIGEST_LENGTH))
            data.withUnsafeBytes { _ = CC_SHA224($0.baseAddress, CC_LONG(data.count), &digest) }
            return Data(digest)
        default: throw Failure("Hash algorithm \(algorithm) isn't supported")
        }
    }

    /// The string-to-key specifier: its type, hash, salt and count, and how long it is.
    struct S2K {
        let type: Int
        let hash: Int
        let salt: Data
        let count: Int

        static func parse(_ bytes: [UInt8], at i: Int) throws -> (S2K, Int) {
            guard i + 2 <= bytes.count else { throw Failure("The PGP message is damaged") }
            let type = Int(bytes[i]), hash = Int(bytes[i + 1])
            switch type {
            case 0: return (S2K(type: 0, hash: hash, salt: Data(), count: 0), 2)
            case 1:
                guard i + 10 <= bytes.count else { throw Failure("The PGP message is damaged") }
                return (S2K(type: 1, hash: hash, salt: Data(bytes[(i + 2)..<(i + 10)]), count: 0), 10)
            case 3:
                guard i + 11 <= bytes.count else { throw Failure("The PGP message is damaged") }
                let c = Int(bytes[i + 10])
                return (S2K(type: 3, hash: hash, salt: Data(bytes[(i + 2)..<(i + 10)]), count: (16 + (c & 15)) << ((c >> 4) + 6)), 11)
            default: throw Failure("String-to-key type \(type) isn't supported")
            }
        }

        /// RFC 4880 3.7.1: as many hashes as the key needs, each preloaded with one more zero.
        func key(_ passphrase: String, size: Int) throws -> Data {
            let material = salt + Data(passphrase.utf8)
            var key = Data()
            var round = 0
            while key.count < size {
                var input = Data(repeating: 0, count: round)
                if type == 3 {
                    let total = max(count, material.count)
                    var stream = Data(capacity: total)
                    while stream.count < total { stream.append(material.prefix(total - stream.count)) }
                    input.append(stream)
                } else {
                    input.append(material)
                }
                key.append(try OpenPGP.hash(hash, input))
                round += 1
            }
            return key.prefix(size)
        }
    }

    // MARK: - AES in CFB

    static func cfb(_ data: Data, key: Data, iv: Data = Data(repeating: 0, count: 16), encrypt: Bool) throws -> Data {
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { k in
            iv.withUnsafeBytes { v in
                CCCryptorCreateWithMode(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCMode(kCCModeCFB), CCAlgorithm(kCCAlgorithmAES),
                                        CCPadding(ccNoPadding), v.baseAddress, k.baseAddress, key.count, nil, 0, 0, CCModeOptions(0), &cryptor)
            }
        }
        guard status == kCCSuccess, let cryptor else { throw Failure("The cipher couldn't start") }
        defer { CCCryptorRelease(cryptor) }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let result = data.withUnsafeBytes { d in CCCryptorUpdate(cryptor, d.baseAddress, data.count, &out, out.count, &moved) }
        guard result == kCCSuccess else { throw Failure("The cipher failed") }
        return Data(out.prefix(moved))
    }

    static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    // MARK: - Messages

    public static let wrongPassphrase = Failure("Bad session key")

    /// The literal data of a passphrase-encrypted message.
    public static func decrypt(_ message: Data, passphrase: String) throws -> Data {
        var sessionKey: (cipher: Int, key: Data)?
        for packet in try packets(message) {
            switch packet.tag {
            case 3:
                let b = [UInt8](packet.body)
                guard b.count >= 2, b[0] == 4 else { throw Failure("Only version 4 passphrase packets are supported") }
                let cipher = Int(b[1])
                guard let size = keySizes[cipher] else { throw Failure("Cipher \(cipher) isn't supported; orgstar reads AES") }
                let (s2k, length) = try S2K.parse(b, at: 2)
                let key = try s2k.key(passphrase, size: size)
                if b.count > 2 + length {
                    // An encrypted session key.
                    let esk = try cfb(Data(b[(2 + length)...]), key: key, encrypt: false)
                    guard let algorithm = esk.first, let eskSize = keySizes[Int(algorithm)], esk.count == eskSize + 1 else { throw wrongPassphrase }
                    sessionKey = (Int(algorithm), esk.dropFirst())
                } else {
                    sessionKey = (cipher, key)
                }
            case 18:
                guard let sessionKey else { throw Failure("The PGP message has no passphrase packet") }
                guard packet.body.first == 1 else { throw Failure("Only version 1 integrity protected packets are supported") }
                let plain = try cfb(packet.body.dropFirst(), key: sessionKey.key, encrypt: false)
                let block = 16
                guard plain.count >= block + 2 + 22 else { throw Failure("The PGP message is cut short") }
                let p = [UInt8](plain)
                guard p[block - 2] == p[block], p[block - 1] == p[block + 1] else { throw wrongPassphrase }
                let mdc = plain.suffix(20)
                guard p[p.count - 22] == 0xD3, p[p.count - 21] == 0x14,
                      Data(Insecure.SHA1.hash(data: plain.prefix(plain.count - 20))) == mdc else {
                    throw Failure("The PGP message was modified")
                }
                return try literal(Data(p[(block + 2)..<(p.count - 22)]))
            case 9:
                throw Failure("The message has no integrity protection, which orgstar doesn't read")
            case 20:
                throw Failure("AEAD encrypted messages aren't supported")
            case 10:
                continue
            default:
                throw Failure("PGP packet \(packet.tag) isn't supported")
            }
        }
        throw Failure("The PGP message has no encrypted data")
    }

    /// The data of the literal packet in `data`, decompressing on the way.
    static func literal(_ data: Data) throws -> Data {
        for packet in try packets(data) {
            switch packet.tag {
            case 11:
                let b = [UInt8](packet.body)
                guard b.count >= 6 else { throw Failure("The PGP message is damaged") }
                let nameLength = Int(b[1])
                guard b.count >= 2 + nameLength + 4 else { throw Failure("The PGP message is damaged") }
                return Data(b[(2 + nameLength + 4)...])
            case 8:
                guard let algorithm = packet.body.first else { throw Failure("The PGP message is damaged") }
                let compressed = packet.body.dropFirst()
                switch algorithm {
                case 0: return try literal(Data(compressed))
                case 1: return try literal(try inflate(Data(compressed)))
                case 2: return try literal(try inflate(Data(compressed.dropFirst(2))))
                default: throw Failure("BZip2 compressed messages aren't supported")
                }
            default:
                continue
            }
        }
        throw Failure("The PGP message has no literal data")
    }

    /// Raw deflate, as ZIP and ZLIB packets hold it.
    static func inflate(_ data: Data) throws -> Data {
        do {
            return try (data as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw Failure("The PGP message's compressed data is damaged")
        }
    }

    /// `gpg --symmetric --armor`: AES-256, an iterated and salted SHA-256 key, integrity
    /// protection, binary literal data without a name.
    public static func encrypt(_ data: Data, passphrase: String, now: Date = Date()) throws -> String {
        let salt = random(8)
        let s2k = S2K(type: 3, hash: 8, salt: salt, count: (16 + (96 & 15)) << ((96 >> 4) + 6))
        let key = try s2k.key(passphrase, size: 32)
        let skesk = packet(3, Data([4, 9, 3, 8]) + salt + Data([96]))
        let date = UInt32(max(0, now.timeIntervalSince1970))
        let literal = packet(11, Data([0x62, 0]) + Data((0..<4).reversed().map { UInt8((date >> ($0 * 8)) & 0xff) }) + data)
        var prefix = random(16)
        prefix.append(prefix.suffix(2))
        var plain = prefix + literal + Data([0xD3, 0x14])
        plain.append(Data(Insecure.SHA1.hash(data: plain)))
        let seipd = packet(18, Data([1]) + (try cfb(plain, key: key, encrypt: true)))
        return armor(skesk + seipd)
    }
}
