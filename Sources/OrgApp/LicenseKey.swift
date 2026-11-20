import CryptoKit
import Foundation

/// A Mac license key: `ORGSTAR1-<payload>.<signature>`, both base64url. The payload is JSON the
/// license issuer (`packaging/license-issuer`) signs with Ed25519; the app checks the signature
/// offline against `publicKey`.
public struct LicenseKey: Codable, Sendable, Equatable {
    /// Who the license is for: the sponsor's GitHub login.
    public let holder: String
    /// The sponsoring account, `github:<node ID>`.
    public let transaction: String
    /// When the key was issued, as Unix seconds.
    public let issued: Int
    /// When a monthly sponsor's key stops working, as Unix seconds; nil for a lifetime key.
    public let expires: Int?

    enum CodingKeys: String, CodingKey {
        case holder = "e", transaction = "t", issued = "i", expires = "x"
    }

    public enum Failure: Error, Equatable {
        case malformed, badSignature, expired
    }

    static let prefix = "ORGSTAR1-"

    /// The issuer's Ed25519 public key (raw, 32 bytes), base64. `packaging/license-issuer/keygen.sh`
    /// writes it here; until then it is a placeholder whose private half was discarded, and
    /// `scripts/release-mac.sh` refuses to build.
    public static let publicKey = "bsxWsmNYsFJiN6e/UaBgRzAmHBry9+sjI8BFFbf21aM="

    public init(holder: String, transaction: String, issued: Int, expires: Int? = nil) {
        self.holder = holder
        self.transaction = transaction
        self.issued = issued
        self.expires = expires
    }

    public func isExpired(at now: Date = .now) -> Bool {
        expires.map { now.timeIntervalSince1970 >= Double($0) } ?? false
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
    /// Where a monthly key is exchanged for a fresh one while the sponsorship lasts.
    static let renewURL = URL(string: "https://krz.sh/apps/orgstar/renew")!
    /// A monthly key is renewed once fewer days than this are left (the issuer gives 40).
    static let renewWithin: TimeInterval = 30 * 86400

    /// The stored key's license, if it verifies and hasn't expired.
    public static func current(defaults: UserDefaults = .standard, now: Date = .now, publicKey: String = LicenseKey.publicKey) -> LicenseKey? {
        stored(defaults: defaults, publicKey: publicKey).flatMap { $0.isExpired(at: now) ? nil : $0 }
    }

    /// The stored key's license, expired or not.
    static func stored(defaults: UserDefaults, publicKey: String) -> LicenseKey? {
        defaults.string(forKey: key).flatMap { try? LicenseKey.verify($0, publicKey: publicKey) }
    }

    /// Exchanges a monthly key that is due for a fresh one. Returns whether the stored key
    /// changed. A refusal (the sponsorship ended) or no network leaves the key to expire.
    public static func renewIfDue(
        defaults: UserDefaults = .standard, now: Date = .now, publicKey: String = LicenseKey.publicKey,
        post: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    ) async -> Bool {
        guard let text = defaults.string(forKey: key), let license = try? LicenseKey.verify(text, publicKey: publicKey),
              let expires = license.expires, Double(expires) - now.timeIntervalSince1970 < renewWithin
        else { return false }
        var request = URLRequest(url: renewURL)
        request.httpMethod = "POST"
        request.httpBody = Data(text.utf8)
        guard let (data, response) = try? await post(request), (response as? HTTPURLResponse)?.statusCode == 200,
              let fresh = String(data: data, encoding: .utf8)?.filter({ !$0.isWhitespace }),
              let renewed = try? LicenseKey.verify(fresh, publicKey: publicKey), renewed.transaction == license.transaction,
              (renewed.expires ?? .max) > expires
        else { return false }
        defaults.set(fresh, forKey: key)
        return true
    }

    /// Verifies and stores `text`.
    public static func activate(
        _ text: String, defaults: UserDefaults = .standard, now: Date = .now, publicKey: String = LicenseKey.publicKey
    ) throws(LicenseKey.Failure) -> LicenseKey {
        let license = try LicenseKey.verify(text, publicKey: publicKey)
        guard !license.isExpired(at: now) else { throw .expired }
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
