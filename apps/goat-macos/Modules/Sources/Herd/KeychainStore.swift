import Foundation
import Security

/// Minimal Keychain wrapper - currently unused. `CredentialStore` (a 0600 file in the GOAT
/// home) holds the engine key instead, because ad-hoc dev signing makes Keychain ACLs
/// re-prompt on every rebuild. Kept for a stable-signed future (ADR-0012).
public enum KeychainStore {
    private static let service = "dev.leet.goat"

    public static func set(_ value: String, for key: String) {
        delete(key)
        guard let data = value.data(using: .utf8), !value.isEmpty else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecValueData: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    public static func get(_ key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(_ key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
