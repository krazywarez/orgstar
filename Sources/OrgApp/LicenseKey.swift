import CryptoKit
import Foundation

/// A Mac license key: `ORGSTAR1-<payload>.<signature>`, both base64url. The payload is JSON the
/// license issuer signs with Ed25519; the app checks the signature offline against `publicKey`.
public struct LicenseKey: Codable, Sendable, Equatable {
    /// The email the license was sold to.
    public let email: String
    /// The payment provider's transaction ID.
    public let transaction: String
    /// When the key was issued, as Unix seconds.
    public let issued: Int

    enum CodingKeys: String, CodingKey {
        case email = "e", transaction = "t", issued = "i"
    }

    public enum Failure: Error, Equatable {
        case malformed, badSignature
    }

    static let prefix = "ORGSTAR1-"

    /// The issuer's Ed25519 public key (raw, 32 bytes), base64. `packaging/license-issuer/keygen.sh`
    /// writes it here; until then it is a placeholder whose private half was discarded, and
    /// `scripts/release-mac.sh` refuses to build.
    public static let publicKey = "bsxWsmNYsFJiN6e/UaBgRzAmHBry9+sjI8BFFbf21aM="

    public init(email: String, transaction: String, issued: Int) {
        self.email = email
        self.transaction = transaction
        self.issued = issued
    }

    /// Checks `text` (whitespace and line breaks from pasting are ignored) and returns the license.
    public static func verify(_ text: String, publicKey: String = publicKey) throws(Failure) -> LicenseKey {
        let key = text.filter { !$0.isWhitespace }
        guard key.hasPrefix(prefix) else { throw .malformed }
        let parts = key.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payload = Data(base64URL: String(parts[0])),
              let signature = Data(base64URL: String(parts[1])),
              let raw = Data(base64Encoded: publicKey),
              let signer = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else { throw .malformed }
        guard signer.isValidSignature(signature, for: payload) else { throw .badSignature }
        guard let license = try? JSONDecoder().decode(LicenseKey.self, from: payload) else { throw .malformed }
        return license
    }
}

/// The Mac app's stored license.
public enum LicenseStore {
    static let key = "pro.licenseKey"

    /// The stored key's license, if it still verifies.
    public static func current(defaults: UserDefaults = .standard) -> LicenseKey? {
        defaults.string(forKey: key).flatMap { try? LicenseKey.verify($0) }
    }

    /// Verifies and stores `text`.
    public static func activate(_ text: String, defaults: UserDefaults = .standard) throws(LicenseKey.Failure) -> LicenseKey {
        let license = try LicenseKey.verify(text)
        defaults.set(text.filter { !$0.isWhitespace }, forKey: key)
        return license
    }

    public static func remove(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

extension Data {
    init?(base64URL: String) {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }
}
