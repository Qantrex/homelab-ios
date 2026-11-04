import Foundation
import Security

/// Test S6/S7: a value written once must survive app kills and SideStore refreshes (re-signing).
/// The stored value is only a creation timestamp, never a real secret.
enum Keychain {
    static let service = "com.qantrex.homelab.spike"
    static let account = "spike-test"

    static func read() -> (value: String?, status: OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return (nil, status) }
        return (String(decoding: data, as: UTF8.self), status)
    }

    /// Writes the current time if nothing is stored yet. Returns the OSStatus of the add.
    static func writeIfMissing() -> OSStatus {
        if read().value != nil { return errSecSuccess }
        let value = ISO8601DateFormatter().string(from: Date())
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            // Same class the real app will use: readable in background refreshes after the first unlock.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    static func delete() -> OSStatus {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
