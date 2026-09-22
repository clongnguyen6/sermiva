import Foundation
import Security

/// Reads and writes the Soniox API key to Keychain only - per AGENTS.md,
/// the key never appears in chat, a log, a URL, or the repo, and this is
/// the one place production code touches it. `kSecAttrAccessibleAfterFirst
/// UnlockThisDeviceOnly` keeps the key device-local and unavailable before
/// the user's first unlock, without iCloud Keychain sync.
enum SonioxKeychainStore {
    private static let service = "com.clongnguyen6.sermiva.soniox-api-key"
    private static let account = "soniox"

    static func loadKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveKey(_ key: String) {
        let data = Data(key.utf8)
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }

    static func deleteKey() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
