import Foundation
import Testing
@testable import OrgCore

struct OpenPGPTests {
    static var gpg: String? {
        ["/opt/homebrew/bin/gpg", "/usr/local/bin/gpg", "/usr/bin/gpg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// gpg with its own short home (the agent's socket path has a length limit), the
    /// passphrase given in loopback.
    static func gpg(_ arguments: [String], input: Data) throws -> Data {
        let home = "/tmp/ogpg-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            kill.arguments = ["gpgconf", "--homedir", home, "--kill", "gpg-agent"]
            try? kill.run()
            kill.waitUntilExit()
            try? FileManager.default.removeItem(atPath: home)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gpg!)
        process.arguments = ["--homedir", home, "--batch", "--yes", "--pinentry-mode", "loopback", "--quiet"] + arguments
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw OpenPGP.Failure(String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        return out
    }

    static let text = Data("Secret notes: ünïcödé, and\n** a sub-heading\n".utf8) + Data(repeating: 65, count: 3000)

    static let variants: [[String]] = [
        [],
        ["--compress-algo", "none"],
        ["--compress-algo", "zlib", "--cipher-algo", "AES128"],
        ["--cipher-algo", "AES192", "--s2k-digest-algo", "SHA1"],
        ["--s2k-mode", "1", "--s2k-digest-algo", "SHA512"],
        ["--s2k-mode", "0", "--s2k-digest-algo", "SHA224"],
        ["--s2k-count", "65011712"],
        ["--force-mdc", "--compress-algo", "zip"],
    ]

    @Test(.enabled(if: gpg != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil), arguments: variants.indices)
    func readsWhatGPGWrites(variant: Int) throws {
        let armored = try Self.gpg(["--passphrase", "correct horse", "--symmetric", "--armor"] + Self.variants[variant], input: Self.text)
        let message = try OpenPGP.dearmor(String(decoding: armored, as: UTF8.self))
        #expect(try OpenPGP.decrypt(message, passphrase: "correct horse") == Self.text)
        #expect(throws: OpenPGP.Failure.self) { try OpenPGP.decrypt(message, passphrase: "wrong") }
    }

    @Test(.enabled(if: gpg != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func gpgReadsWhatWeWrite() throws {
        for plain in [Self.text, Data(), Data("short\n".utf8), Data(repeating: 7, count: 70_000)] {
            let armored = try OpenPGP.encrypt(plain, passphrase: "pass phrase")
            #expect(armored.hasPrefix("-----BEGIN PGP MESSAGE-----\n\n") && armored.hasSuffix("-----END PGP MESSAGE-----\n"))
            let back = try Self.gpg(["--passphrase", "pass phrase", "--decrypt"], input: Data(armored.utf8))
            #expect(back == plain)
            #expect(try OpenPGP.decrypt(OpenPGP.dearmor(armored), passphrase: "pass phrase") == plain)
        }
    }

    @Test func armorChecksum() throws {
        let armored = OpenPGP.armor(Data([1, 2, 3]))
        #expect(try OpenPGP.dearmor(armored) == Data([1, 2, 3]))
        let damaged = armored.replacingOccurrences(of: "AQID", with: "AQIE")
        #expect(throws: OpenPGP.Failure.self) { try OpenPGP.dearmor(damaged) }
        #expect(OpenPGP.crc24(Data()) == 0xB704CE)
    }
}
