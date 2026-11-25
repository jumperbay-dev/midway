import Foundation
import Security

/// App passwords live only in the Keychain, never in SQLite or a CLI's environment.
public enum Keychain {
    static let service = "dev.midway.account"

    // ponytail: login keychain. The design's data-protection keychain (kSecUseDataProtectionKeychain) needs a
    // keychain-access-groups entitlement and a Developer ID provisioning profile embedded in the app; switch when
    // the profile exists (developer.apple.com), and move existing items over on first launch.
    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public static func set(_ secret: String, for account: String) throws {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = Data(secret.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public struct KeychainError: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }
}
