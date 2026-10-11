import Foundation
import LocalAuthentication
import Security

/// Passphrases for encrypted entries, kept in the Keychain by file when asked, and given back
/// only after Touch ID, Face ID or the device's password.
public enum CryptPassphrases {
    static let service = "sh.krz.orgstar.crypt"

    static func query(_ path: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: path]
    }

    public static func store(_ passphrase: String, for path: String) {
        forget(path)
        var item = query(path)
        item[kSecValueData as String] = Data(passphrase.utf8)
        item[kSecAttrLabel as String] = "orgstar: encrypted entries in " + (path as NSString).lastPathComponent
        SecItemAdd(item as CFDictionary, nil)
    }

    public static func forget(_ path: String) {
        SecItemDelete(query(path) as CFDictionary)
    }

    public static func hasStored(_ path: String) -> Bool {
        var q = query(path)
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    /// The stored passphrase, once the person has proved who they are; nil otherwise.
    public static func stored(for path: String) async -> String? {
        guard hasStored(path) else { return nil }
        let context = LAContext()
        let reason = "unlock the passphrase for encrypted entries in " + (path as NSString).lastPathComponent
        guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true else { return nil }
        var q = query(path)
        q[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
