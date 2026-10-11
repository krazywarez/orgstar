import Foundation
import Testing
@testable import OrgCore

struct OrgCryptTests {
    static let file = """
        #+TITLE: Secrets
        * Plain
        Open text.
        * TODO Bank :crypt:
        SCHEDULED: <2026-10-20 Tue>
        :PROPERTIES:
        :ID: bank
        :END:
        :LOGBOOK:
        CLOCK: [2026-10-01 Thu 09:00]--[2026-10-01 Thu 10:00] =>  1:00
        :END:
        Account 12345, ünïcödé.
        ** Child
        Child text.

        * Diary :crypt:
        Dear diary.
        * Empty :crypt:
        * Last
        """ + "\n"

    static func lisp(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `form` run in Emacs on `text` in an Org buffer, with symmetric org-crypt and the
    /// passphrase given in loopback; the buffer's text afterwards.
    static func emacs(_ text: String, _ form: String) throws -> String {
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
        let out = home + "/out.org"
        let elisp = """
        (progn
          (require 'org) (require 'org-crypt) (require 'epg)
          (setq org-crypt-key nil epg-pinentry-mode 'loopback org-crypt-disable-auto-save nil
                epg-gpg-program "/opt/homebrew/bin/gpg")
          (require 'epa)
          (cl-letf (((symbol-function 'epa-passphrase-callback-function) (lambda (&rest _) (copy-sequence "pw one")))
                    ((symbol-function 'epg-passphrase-callback-function) (lambda (&rest _) (copy-sequence "pw one"))))
            (with-temp-buffer
              (insert \(lisp(text)))
              (org-mode)
              \(form)
              (write-region (point-min) (point-max) \(lisp(out))))))
        """
        let log = try EmacsOracle.run(["-Q", "--batch", "--eval", elisp], environment: ["GNUPGHOME": home, "TZ": "UTC"])
        guard let result = try? String(contentsOfFile: out, encoding: .utf8) else { throw EmacsOracle.EvaluateError(log: log) }
        return result
    }

    /// The text with each message's lines as one placeholder line.
    static func masked(_ s: String) -> String {
        s.replacing(#/(?s)-----BEGIN PGP MESSAGE-----.*?-----END PGP MESSAGE-----\n/#, with: "<MESSAGE>\n")
    }

    static var gpg: Bool { FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/gpg") }

    @Test(.enabled(if: gpg && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func encryptsAndDecryptsAsOrg() throws {
        // Emacs encrypts every tagged entry; ours does the same around the same text.
        let theirs = try Self.emacs(Self.file, "(org-encrypt-entries)")
        let (ours, count) = try OrgCrypt.encryptAll(Self.file, passphrase: "pw one")
        #expect(count == 3)
        #expect(Self.masked(ours) == Self.masked(theirs), "ours:\n\(Self.masked(ours))\nemacs:\n\(Self.masked(theirs))")
        // Each side reads the other's.
        var back = theirs
        for heading in OrgCrypt.taggedHeadings(back).reversed() { back = try OrgCrypt.decryptInPlace(back, at: heading, passphrase: "pw one") }
        #expect(back == Self.file, "\(back.debugDescription)\n\(Self.file.debugDescription)")
        let decrypted = try Self.emacs(ours, "(org-decrypt-entries)")
        #expect(decrypted == Self.file, "\(decrypted)")
        let bank = (ours as NSString).range(of: "* TODO Bank").location
        #expect(try OrgCrypt.decrypt(ours, at: bank, passphrase: "pw one").plaintext == "Account 12345, ünïcödé.\n** Child\nChild text.\n")
        #expect(throws: OrgCrypt.Failure("Wrong passphrase")) { try OrgCrypt.decrypt(ours, at: bank, passphrase: "nope") }
        // Edited and encrypted again, Emacs reads it.
        let edited = try OrgCrypt.replacing(ours, at: bank, with: "New text.\n", passphrase: "pw one")
        let read = try Self.emacs(edited, "(goto-char (point-min)) (re-search-forward \"Bank\") (org-decrypt-entry)")
        #expect(read.contains("* TODO Bank :crypt:\nSCHEDULED: <2026-10-20 Tue>\n:PROPERTIES:\n:ID: bank\n:END:\n:LOGBOOK:\nCLOCK: [2026-10-01 Thu 09:00]--[2026-10-01 Thu 10:00] =>  1:00\n:END:\nNew text.\n\n* Diary"), "\(read)")
    }

    @Test func regions() throws {
        let file = Self.file
        let bank = (file as NSString).range(of: "* TODO Bank").location
        let body = try #require(OrgCrypt.bodyRange(file, at: bank + 3))
        #expect((file as NSString).substring(with: NSRange(body)) == "Account 12345, ünïcödé.\n** Child\nChild text.\n")
        #expect(OrgCrypt.encryptedRange(file, at: bank) == nil)
        // The child inherits the tag.
        #expect(OrgCrypt.taggedHeadings(file).count == 4)
        let encrypted = try #require(try OrgCrypt.encrypt(file, at: bank, passphrase: "x"))
        #expect(try OrgCrypt.encrypt(encrypted, at: bank, passphrase: "x") == nil)
        #expect(throws: OrgCrypt.Failure.self) { try OrgCrypt.encrypt("text\n", at: 0, passphrase: "x") }
        // A decrypted heading above the entry's level goes below it.
        let shallow = try OrgCrypt.replacing(encrypted, at: bank, with: "* Top\ntext\n", passphrase: "x")
        let placed = try OrgCrypt.decryptInPlace(shallow, at: bank, passphrase: "x")
        #expect(placed.contains(":END:\n** Top\ntext\n\n* Diary"), "\(placed)")
    }
}
